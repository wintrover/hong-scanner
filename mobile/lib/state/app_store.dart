import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_models.dart';
import '../services/push_permission.dart';
import '../services/push_service.dart';

/// Per-section load state. Phases are exhaustive and honest: `loading` is
/// a real fetch in flight, `error` keeps the failure reason (including
/// whether it looks like offline), and `loaded` with null data means the
/// API answered "no record" — never rendered as success-with-content.
enum LoadPhase { idle, loading, loaded, error }

class Section<T> {
  const Section({
    this.phase = LoadPhase.idle,
    this.value,
    this.errorMessage,
    this.offline = false,
  });

  const Section.loading() : this(phase: LoadPhase.loading);

  const Section.loaded(T value) : this(phase: LoadPhase.loaded, value: value);

  const Section.error(String message, {bool offline = false})
      : this(phase: LoadPhase.error, errorMessage: message, offline: offline);

  final LoadPhase phase;
  final T? value;
  final String? errorMessage;
  final bool offline;

  bool get hasProblem => phase == LoadPhase.error;
}

/// UI-visible push state, derived from the service readiness plus the
/// persisted permission ledger — never from assumptions.
class PushUiState {
  const PushUiState({
    required this.phase,
    this.askedCount = 0,
    this.lastAskedAt,
    this.lastResponse,
    this.token,
    this.tokenError,
    this.notice,
  });

  final PushPhase phase;
  final int askedCount;
  final DateTime? lastAskedAt;
  final PushPermissionDecision? lastResponse;
  final String? token;
  final String? tokenError;

  /// A push-flow problem that is neither a decision nor a token issue —
  /// e.g. the platform raised an error during the permission ask.
  final String? notice;

  PushUiState copyWith({
    PushPhase? phase,
    int? askedCount,
    DateTime? lastAskedAt,
    PushPermissionDecision? lastResponse,
    String? token,
    String? tokenError,
    String? notice,
    bool clearToken = false,
    bool clearTokenError = false,
    bool clearLastAskedAt = false,
    bool clearLastResponse = false,
    bool clearNotice = false,
  }) {
    return PushUiState(
      phase: phase ?? this.phase,
      askedCount: askedCount ?? this.askedCount,
      lastAskedAt: clearLastAskedAt ? null : (lastAskedAt ?? this.lastAskedAt),
      lastResponse:
          clearLastResponse ? null : (lastResponse ?? this.lastResponse),
      token: clearToken ? null : (token ?? this.token),
      tokenError: clearTokenError ? null : (tokenError ?? this.tokenError),
      notice: clearNotice ? null : (notice ?? this.notice),
    );
  }
}

/// Central app state: API sections, event selection/routing, push
/// permission flow and resync scheduling.
///
/// Honest by contract: this store never synthesizes content. Sections show
/// what the API recorded; missing records stay "기록 없음", offline stays
/// "오프라인", and retries are bounded with a restrained backoff so a dead
/// server ends in a visible error state, not an eternal spinner.
class AppStore extends ChangeNotifier {
  AppStore({
    required ApiClient apiClient,
    required PushService pushService,
    KeyValueStore? keyValueStore,
    Future<void> Function(Duration delay)? delay,
    DateTime Function()? now,
    this._maxSyncAttempts = 3,
    this._backoffBase = const Duration(seconds: 1),
  })  : _api = apiClient,
        _push = pushService,
        _ledger = PushPermissionLedger(store: keyValueStore),
        _delay = delay ?? _defaultDelay,
        _now = now ?? DateTime.now;

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

  final ApiClient _api;
  final PushService _push;
  final PushPermissionLedger _ledger;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  final int _maxSyncAttempts;
  final Duration _backoffBase;

  bool _bootstrapped = false;
  bool _syncing = false;
  bool _disposed = false;

  Section<StatusResponse> status = const Section();
  Section<EventsResponse> events = const Section();
  Section<CandidatesResponse> candidates = const Section();
  Section<SessionsResponse> sessions = const Section();
  Section<VerificationResponse> verification = const Section();

  String? selectedEventId;
  Section<EventDetailResponse> eventDetail = const Section();
  String? selectedSession;
  int tabIndex = 0;

  PushUiState pushState = const PushUiState(phase: PushPhase.unwired);

  /// True while a sync pass (including its bounded retries) is running.
  bool get syncing => _syncing;

  /// Sync passes started since construction — a small observable counter
  /// tests use to prove resync triggers fired.
  int syncCount = 0;

  /// Backoff durations the current/last sync requested — observable
  /// proof that retries back off instead of hammering.
  final List<Duration> recordedBackoffs = <Duration>[];

  StreamSubscription<PushMessage>? _tapSub;
  StreamSubscription<PushMessage>? _foregroundSub;
  StreamSubscription<String>? _fidSub;
  void Function(PushMessage message)? onForegroundMessage;

  static const int detailTabIndex = 2;

  // ---- bootstrap --------------------------------------------------------

  /// One-time startup: permission flow, push wiring, first sync.
  ///
  /// Auto-ask policy: the app asks exactly once, on the first run
  /// (ledger says never asked). Denied stays denied until the operator
  /// re-asks from the Overview card — Android 13+ makes silent re-asks
  /// both nagging and unverifiable.
  Future<void> bootstrap({
    void Function(PushMessage message)? onForegroundMessage,
  }) async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    this.onForegroundMessage = onForegroundMessage;
    await _initPushState();
    await resync();
  }

  Future<void> _initPushState() async {
    if (!_push.isReady) {
      pushState = const PushUiState(phase: PushPhase.unwired);
      notifyListeners();
      return;
    }
    final record = await _ledger.load();
    final phase = switch (record.lastResponse) {
      PushPermissionDecision.granted => PushPhase.granted,
      PushPermissionDecision.denied => PushPhase.denied,
      PushPermissionDecision.provisional => PushPhase.provisional,
      null =>
        record.neverAsked ? PushPhase.notAsked : PushPhase.unknown,
    };
    pushState = PushUiState(
      phase: phase,
      askedCount: record.askedCount,
      lastAskedAt: record.lastAskedAt,
      lastResponse: record.lastResponse,
    );
    notifyListeners();
    if (record.neverAsked) {
      await requestPushPermission();
    }
    await _wireTokenSource();
    _wirePushRouting();
  }

  Future<void> requestPushPermission() async {
    if (!_push.isReady) return;
    pushState = pushState.copyWith(phase: PushPhase.asking);
    notifyListeners();
    final PushPermissionDecision? decision;
    try {
      decision = await _push.requestPermission();
    } on Object catch (e) {
      // The ask failed before any recorded answer exists: honest unknown,
      // with the error surfaced. Not recorded as a decision it never got.
      // StateError/PlatformException 모두 여기서 잡는다 — 부트스트랩이
      // 죽는 대신 UI가 "권한 상태 미확정"을 보여준다.
      await _ledger.recordAsk(at: _now());
      final record = await _ledger.load();
      pushState = PushUiState(
        phase: PushPhase.unknown,
        askedCount: record.askedCount,
        lastAskedAt: record.lastAskedAt,
        lastResponse: record.lastResponse,
        token: pushState.token,
        notice: '권한 요청 실패: $e',
      );
      notifyListeners();
      return;
    }
    if (decision == null) {
      // "Nothing was asked" from a service that reported ready — do not
      // invent a decision; surface it as unknown.
      pushState = pushState.copyWith(phase: PushPhase.unknown);
      notifyListeners();
      return;
    }
    await _ledger.recordAsk(at: _now(), response: decision);
    final record = await _ledger.load();
    pushState = PushUiState(
      phase: switch (decision) {
        PushPermissionDecision.granted => PushPhase.granted,
        PushPermissionDecision.denied => PushPhase.denied,
        PushPermissionDecision.provisional => PushPhase.provisional,
      },
      askedCount: record.askedCount,
      lastAskedAt: record.lastAskedAt,
      lastResponse: record.lastResponse,
      token: pushState.token,
    );
    notifyListeners();
  }

  /// Wires the token-registration flow (firebase_messaging 17.x FID
  /// APIs). Subscribes [PushTokenSource.onRegistered] *before* calling
  /// [PushTokenSource.register] so the delivered FID cannot race the
  /// listener, and shows exactly what the source delivered: no FID means
  /// no token on the card, never a fabricated one. The identifier is
  /// display-only — the operator registers it with the server CLI.
  Future<void> _wireTokenSource() async {
    if (!_push.isReady) {
      pushState = pushState.copyWith(
          tokenError: '푸시 미연결 — Firebase 미설정 (mobile/README.md 참조)');
      notifyListeners();
      return;
    }
    final tokenSource =
        _push is PushTokenSource ? _push as PushTokenSource : null;
    if (tokenSource == null) return;
    _fidSub = tokenSource.onRegistered.listen(
      (fid) {
        pushState = pushState.copyWith(token: fid, clearTokenError: true);
        notifyListeners();
      },
      onError: (Object e) {
        // Keep any previously delivered FID; the error is surfaced, not
        // swallowed and not mistaken for a token.
        pushState = pushState.copyWith(tokenError: '토큰 획득 실패: $e');
        notifyListeners();
      },
    );
    try {
      await tokenSource.register();
    } on Object catch (e) {
      pushState = pushState.copyWith(tokenError: '토큰 획득 실패: $e');
      notifyListeners();
    }
  }

  void _wirePushRouting() {
    final source = _push is PushMessageSource ? _push as PushMessageSource : null;
    if (source == null) return;
    // Cold start: the notification that launched the app routes to its
    // event detail. Messages without a usable event_id are not routed —
    // inventing a target would be worse than ignoring one bad payload.
    source.initialMessage().then((message) {
      final eventId = message?.eventId;
      if (eventId != null) openEvent(eventId);
    });
    _tapSub = source.tapMessages.listen((message) {
      final eventId = message.eventId;
      if (eventId != null) openEvent(eventId);
    });
    _foregroundSub = source.foregroundMessages.listen((message) {
      onForegroundMessage?.call(message);
    });
  }

  // ---- routing ----------------------------------------------------------

  void selectTab(int index) {
    tabIndex = index;
    notifyListeners();
  }

  /// Routing target for notification taps and list selections: selects the
  /// event, switches to the detail tab, and fetches the recorded fact.
  Future<void> openEvent(String eventId) async {
    selectedEventId = eventId;
    tabIndex = detailTabIndex;
    eventDetail = const Section.loading();
    notifyListeners();
    try {
      final detail = await _api.fetchEvent(eventId);
      if (selectedEventId != eventId) return; // superseded by a newer selection
      eventDetail = Section.loaded(detail);
    } on ApiClientException catch (e) {
      if (selectedEventId != eventId) return;
      eventDetail = Section.error(_describe(e), offline: e.isConnectivityProblem);
    }
    notifyListeners();
  }

  Future<void> openSessionVerification(String session) async {
    selectedSession = session;
    verification = const Section.loading();
    notifyListeners();
    try {
      final response = await _api.fetchVerification(session);
      if (selectedSession != session) return;
      verification = Section.loaded(response);
    } on ApiClientException catch (e) {
      if (selectedSession != session) return;
      verification = Section.error(_describe(e), offline: e.isConnectivityProblem);
    }
    notifyListeners();
  }

  // ---- sync -------------------------------------------------------------

  /// Startup, foreground resume, and FCM message-discard recovery all land
  /// here: one full refresh of every recorded-fact section, with bounded
  /// backoff on failure.
  Future<void> resync() async {
    if (_syncing) return;
    _syncing = true;
    notifyListeners();
    try {
      syncCount += 1;
      for (var attempt = 1; attempt <= _maxSyncAttempts; attempt++) {
        final ok = await _fetchOnce();
        if (ok) break;
        if (attempt == _maxSyncAttempts) break;
        final backoff = _backoffBase * (1 << (attempt - 1));
        recordedBackoffs.add(backoff);
        await _delay(backoff);
      }
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// One pass over all sections. Returns true when nothing failed.
  Future<bool> _fetchOnce() async {
    var ok = true;

    Future<void> guard<T>(
      Future<T> Function() fetch,
      void Function(Section<T>) assign,
    ) async {
      assign(Section<T>.loading());
      try {
        assign(Section<T>.loaded(await fetch()));
      } on ApiClientException catch (e) {
        assign(Section<T>.error(_describe(e), offline: e.isConnectivityProblem));
        ok = false;
      }
    }

    await guard(_api.fetchStatus, (s) => status = s);
    await guard(_api.fetchEvents, (s) => events = s);
    await guard(_api.fetchCandidates, (s) => candidates = s);
    await guard(_api.fetchSessions, (s) => sessions = s);
    final target =
        status.value?.sessionsLatest.session ?? _latestSessionName();
    if (target != null) {
      selectedSession = target;
      await guard(
        () => _api.fetchVerification(target),
        (s) => verification = s,
      );
    } else {
      verification = const Section.error(
          '최근 세션을 확인할 수 없어 검증 기록을 조회하지 않음',
          offline: true);
    }
    notifyListeners();
    return ok;
  }

  String? _latestSessionName() {
    final list = sessions.value?.sessions;
    if (list == null || list.isEmpty) return null;
    return list.last.session;
  }

  String _describe(ApiClientException e) {
    if (e.isConnectivityProblem) return '서버에 연결할 수 없음 (${e.message})';
    if (e.code == ApiErrorCode.http) {
      return switch (e.serverCode) {
        'not_found' => '기록에 없음 (404 not_found)',
        'data_fault' => '기록 파일 불량 (500 data_fault)',
        _ => '서버 오류 (${e.statusCode ?? '?'} ${e.serverCode ?? ''})',
      };
    }
    return '응답 해석 실패 (${e.message})';
  }

  @override
  void dispose() {
    _disposed = true;
    _tapSub?.cancel();
    _foregroundSub?.cancel();
    _fidSub?.cancel();
    _api.close();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}

/// Typed projections of the VS-3 read-only API responses.
///
/// Contract: tools/api/README.md. Every model mirrors exactly what the
/// contract serves — recorded facts plus the cheap rederivations the
/// contract names. `null` is never coerced: the contract defines null as
/// "no record" (absence), which is different from 0 or false, and the
/// models keep that distinction so the UI can stay honest about it.
library;

String? _asString(Object? v) => v is String ? v : null;

int? _asInt(Object? v) => v is int ? v : null;

bool? _asBool(Object? v) => v is bool ? v : null;

bool _asBoolOr(Object? v, bool fallback) => v is bool ? v : fallback;

Map<String, Object?> _asMap(Object? v) =>
    v is Map<String, Object?> ? v : const <String, Object?>{};

List<Map<String, Object?>> _asMapList(Object? v) => v is List
    ? v.whereType<Map<String, Object?>>().toList()
    : const <Map<String, Object?>>[];

/// One immutable event fact (contracts/events/event.schema.json,
/// "hong-scanner-event-fact/1"). [raw] keeps the fact bytes' fields so the
/// UI can show the recorded fact verbatim without merging anything into it.
class ApiEvent {
  const ApiEvent(this.raw);

  factory ApiEvent.fromMap(Map<String, Object?> raw) => ApiEvent(raw);

  final Map<String, Object?> raw;

  String? get eventId => _asString(raw['event_id']);
  String? get eventType => _asString(raw['event_type']);
  String? get observedAt => _asString(raw['observed_at']);
  String? get sessionId => _asString(raw['session_id']);
  String? get severity => _asString(raw['severity']);
  String? get dataQuality => _asString(raw['data_quality']);
  String? get ruleId => _asString(raw['rule_id']);
  int? get ruleVersion => _asInt(raw['rule_version']);
  String? get evidenceRef => _asString(raw['evidence_ref']);

  /// Judged direction; absent when the fact judged no direction.
  String? get direction => _asString(raw['direction']);

  /// Candidate rank; absent for rank-free facts.
  int? get rank => _asInt(raw['rank']);

  /// 6-digit KRX code; absent for non-symbol-scoped facts.
  String? get symbol => _asString(raw['symbol']);

  /// Recorded fact keys in codepoint-ascending order (the API serves
  /// canonical JSON, so this is already the wire order; sorting is a
  /// display-stability guarantee, not a re-derivation).
  List<MapEntry<String, Object?>> get sortedFields {
    final entries = raw.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }
}

/// One delivery-ledger record (contracts/events/delivery.schema.json).
/// Delivery state is operational state — it never lives inside a fact.
class DeliveryRecord {
  const DeliveryRecord(this.raw);

  factory DeliveryRecord.fromMap(Map<String, Object?> raw) =>
      DeliveryRecord(raw);

  final Map<String, Object?> raw;

  String? get eventId => _asString(raw['event_id']);
  String? get deviceId => _asString(raw['device_id']);
  String? get state => _asString(raw['state']);
  int? get attempts => _asInt(raw['attempts']);
  String? get providerMessageId => _asString(raw['provider_message_id']);
  String? get updatedAt => _asString(raw['updated_at']);
}

/// run.json whitelist projection (serve.py RUN_JSON_FIELDS). Fields the
/// API deliberately does not project (host, pid, egress_ip, ...) never
/// appear here because they are never served.
class SessionSummary {
  const SessionSummary({
    required this.session,
    required this.runJsonPresent,
    this.sessionDate,
    this.runId,
    this.startedAt,
    this.codeCommit,
  });

  factory SessionSummary.fromMap(Map<String, Object?> raw) => SessionSummary(
        session: _asString(raw['session']),
        runJsonPresent: _asBoolOr(raw['run_json_present'], false),
        sessionDate: _asString(raw['session_date']),
        runId: _asString(raw['run_id']),
        startedAt: _asString(raw['started_at']),
        codeCommit: _asString(raw['code_commit']),
      );

  /// Run directory name (the recorded session identifier on disk).
  final String? session;
  final bool runJsonPresent;
  final String? sessionDate;
  final String? runId;
  final String? startedAt;
  final String? codeCommit;
}

/// `GET /status` response. Each sub-block preserves the contract's null
/// semantics: e.g. `count == null` with `ledgerPresent == false` means the
/// ledger file does not exist yet — no recorded events, not zero events.
class StatusResponse {
  const StatusResponse({
    required this.sessionsCount,
    required this.sessionsLatest,
    required this.ledgerPresent,
    required this.eventsCount,
    required this.byType,
    required this.bySeverity,
    required this.latestSessionId,
    required this.latestEvent,
    required this.deliveryConfigured,
    required this.deliveryPresent,
    required this.byState,
    required this.deliveryPairs,
    required this.deliveryDevices,
  });

  factory StatusResponse.fromMap(Map<String, Object?> raw) {
    final sessions = _asMap(raw['sessions']);
    final events = _asMap(raw['events']);
    final delivery = _asMap(raw['delivery']);
    final latestEvent = _asMap(events['latest_event']);
    final latest = _asMap(sessions['latest']);
    return StatusResponse(
      sessionsCount: _asInt(sessions['count']),
      sessionsLatest: SessionSummary.fromMap(latest),
      ledgerPresent: _asBoolOr(events['ledger_present'], false),
      eventsCount: _asInt(events['count']),
      byType: _asIntMap(events['by_type']),
      bySeverity: _asIntMap(events['by_severity']),
      latestSessionId: _asString(events['latest_session_id']),
      latestEvent: latestEvent.isEmpty
          ? null
          : LatestEvent(
              eventId: _asString(latestEvent['event_id']),
              eventType: _asString(latestEvent['event_type']),
              observedAt: _asString(latestEvent['observed_at']),
            ),
      deliveryConfigured: _asBoolOr(delivery['configured'], false),
      deliveryPresent: _asBool(delivery['present']),
      byState: _asIntMap(delivery['by_state']),
      deliveryPairs: _asInt(delivery['pairs']),
      deliveryDevices: _asInt(delivery['devices']),
    );
  }

  final int? sessionsCount;
  final SessionSummary sessionsLatest;
  final bool ledgerPresent;
  final int? eventsCount;
  final Map<String, int>? byType;
  final Map<String, int>? bySeverity;
  final String? latestSessionId;
  final LatestEvent? latestEvent;
  final bool deliveryConfigured;
  final bool? deliveryPresent;
  final Map<String, int>? byState;
  final int? deliveryPairs;
  final int? deliveryDevices;
}

Map<String, int>? _asIntMap(Object? v) => v is Map<String, Object?>
    ? v.map((k, value) => MapEntry(k, _asInt(value) ?? 0))
    : null;

class LatestEvent {
  const LatestEvent({
    this.eventId,
    this.eventType,
    this.observedAt,
  });

  final String? eventId;
  final String? eventType;
  final String? observedAt;
}

/// `GET /candidates` response: the CANDIDATE_* facts of the ledger's
/// latest session. `events == null` means the ledger itself is absent.
class CandidatesResponse {
  const CandidatesResponse({
    required this.ledgerPresent,
    required this.sessionId,
    required this.count,
    required this.events,
  });

  factory CandidatesResponse.fromMap(Map<String, Object?> raw) =>
      CandidatesResponse(
        ledgerPresent: _asBoolOr(raw['ledger_present'], false),
        sessionId: _asString(raw['session_id']),
        count: _asInt(raw['count']),
        events: _asMapList(raw['events']).map(ApiEvent.fromMap).toList(),
      );

  final bool ledgerPresent;

  /// null when the ledger is absent (no recorded facts at all).
  final String? sessionId;
  final int? count;
  final List<ApiEvent>? events;

  /// Candidate facts grouped by judged direction. Facts without a
  /// recorded direction are not candidates-by-direction and are skipped —
  /// the grouping shows only what the facts themselves recorded.
  Map<String, List<ApiEvent>> get byDirection {
    final events = this.events ?? const <ApiEvent>[];
    final grouped = <String, List<ApiEvent>>{};
    for (final event in events) {
      final direction = event.direction;
      if (direction == null) continue;
      grouped.putIfAbsent(direction, () => <ApiEvent>[]).add(event);
    }
    return grouped;
  }
}

/// `GET /events` response. Facts and delivery records stay in two separate
/// keys (the three-states-three-homes discipline) — the client must not
/// merge them either. Delivery keys exist only for events that have
/// delivery records; absence of a key is "no delivery recorded".
class EventsResponse {
  const EventsResponse({
    required this.ledgerPresent,
    required this.count,
    required this.events,
    required this.delivery,
  });

  factory EventsResponse.fromMap(Map<String, Object?> raw) {
    final deliveryRaw = raw['delivery'];
    final delivery = <String, List<DeliveryRecord>>{};
    if (deliveryRaw is Map<String, Object?>) {
      deliveryRaw.forEach((eventId, records) {
        delivery[eventId] =
            _asMapList(records).map(DeliveryRecord.fromMap).toList();
      });
    }
    final hasDelivery = deliveryRaw is Map<String, Object?>;
    return EventsResponse(
      ledgerPresent: _asBoolOr(raw['ledger_present'], false),
      count: _asInt(raw['count']),
      events: _asMapList(raw['events']).map(ApiEvent.fromMap).toList(),
      delivery: hasDelivery ? delivery : null,
    );
  }

  final bool ledgerPresent;
  final int? count;
  final List<ApiEvent>? events;

  /// null: delivery is not configured (or the ledger is absent) — the API
  /// answered `delivery: null`. Empty map: configured, but no event has a
  /// delivery record. The distinction is the contract's, so it is kept.
  final Map<String, List<DeliveryRecord>>? delivery;

  /// Last-recorded delivery states for one event, or an empty list when
  /// the events response carried no key for it ("전달 기록 없음").
  List<DeliveryRecord> deliveryFor(String eventId) =>
      delivery?[eventId] ?? const <DeliveryRecord>[];
}

/// `GET /events/{event_id}` response.
class EventDetailResponse {
  const EventDetailResponse({required this.event, required this.delivery});

  factory EventDetailResponse.fromMap(Map<String, Object?> raw) =>
      EventDetailResponse(
        event: ApiEvent.fromMap(_asMap(raw['event'])),
        delivery: _asMapList(raw['delivery']).map(DeliveryRecord.fromMap).toList(),
      );

  final ApiEvent event;

  /// Empty list when no delivery has been recorded — the honest absence
  /// the contract documents.
  final List<DeliveryRecord> delivery;
}

/// `GET /sessions` response: run directory names in ascending order.
class SessionsResponse {
  const SessionsResponse({
    required this.count,
    required this.sessions,
  });

  factory SessionsResponse.fromMap(Map<String, Object?> raw) =>
      SessionsResponse(
        count: _asInt(raw['count']),
        sessions:
            _asMapList(raw['sessions']).map(SessionSummary.fromMap).toList(),
      );

  final int? count;
  final List<SessionSummary> sessions;
}

/// One CHECKSUMS.sha256 artifact row: the recorded hash vs the sha256 the
/// API recomputed (the contract's only allowed rederivation). A refused
/// unsafe artifact name never carries a computed hash — [note] says so.
class ChecksumArtifact {
  const ChecksumArtifact({
    required this.file,
    required this.recordedSha256,
    required this.computedSha256,
    required this.match,
    this.note,
  });

  factory ChecksumArtifact.fromMap(Map<String, Object?> raw) =>
      ChecksumArtifact(
        file: _asString(raw['file']),
        recordedSha256: _asString(raw['recorded_sha256']),
        computedSha256: _asString(raw['computed_sha256']),
        match: raw['match'] == true,
        note: _asString(raw['note']),
      );

  final String? file;
  final String? recordedSha256;
  final String? computedSha256;
  final bool match;
  final String? note;
}

/// `GET /sessions/{session}/verification` response: the session's recorded
/// verification facts. This is a list of facts, not an approval — approval
/// authority stays GATES P12 on the server side.
class VerificationResponse {
  const VerificationResponse({
    required this.session,
    required this.runJsonPresent,
    required this.sessionDate,
    required this.codeCommit,
    required this.committedMarkerFile,
    required this.committedMarkerPresent,
    required this.sessionEndRecorded,
    required this.eventsFilePresent,
    required this.eventsFileSha256,
    required this.checksumsPresent,
    required this.artifacts,
    required this.verdictRecorded,
    required this.verdictSource,
    required this.verdictLine,
    required this.verdictNote,
  });

  factory VerificationResponse.fromMap(Map<String, Object?> raw) {
    final marker = _asMap(raw['committed_marker']);
    final eventsFile = _asMap(raw['events_file']);
    final checksums = _asMap(raw['checksums']);
    final verdict = _asMap(raw['replay_verdict']);
    return VerificationResponse(
      session: _asString(raw['session']),
      runJsonPresent: _asBoolOr(raw['run_json_present'], false),
      sessionDate: _asString(raw['session_date']),
      codeCommit: _asString(raw['code_commit']),
      committedMarkerFile: _asString(marker['file']),
      committedMarkerPresent: marker['present'] == true,
      sessionEndRecorded: raw['session_end_recorded'] == true,
      eventsFilePresent: eventsFile['present'] == true,
      eventsFileSha256: _asString(eventsFile['sha256']),
      checksumsPresent: checksums['present'] == true,
      artifacts:
          _asMapList(checksums['artifacts']).map(ChecksumArtifact.fromMap).toList(),
      verdictRecorded: verdict['recorded'] == true,
      verdictSource: _asString(verdict['source']),
      verdictLine: _asString(verdict['line']),
      verdictNote: _asString(verdict['note']),
    );
  }

  final String? session;
  final bool runJsonPresent;
  final String? sessionDate;
  final String? codeCommit;
  final String? committedMarkerFile;
  final bool committedMarkerPresent;
  final bool sessionEndRecorded;
  final bool eventsFilePresent;
  final String? eventsFileSha256;
  final bool checksumsPresent;
  final List<ChecksumArtifact> artifacts;

  /// The API quotes the operator-recorded VERDICT line verbatim when one
  /// was recorded; `verdictRecorded == false` is honest "no recorded
  /// verdict" — the client never upgrades it to success (fail-closed).
  final bool verdictRecorded;
  final String? verdictSource;
  final String? verdictLine;
  final String? verdictNote;

  int get artifactsMatchCount =>
      artifacts.where((a) => a.match).length;
}

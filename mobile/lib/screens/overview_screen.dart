import 'package:flutter/material.dart';

import '../api/api_models.dart';
import '../state/app_store.dart';
import '../services/push_permission.dart';
import 'app_scope.dart';
import 'widgets.dart';

/// Overview tab: recorded session/collection/data/verification status and
/// the latest session's up/down candidates — exactly what the API records,
/// nothing synthesized. Market prices are not served by the read-only API
/// and are not shown; the app is a projection of recorded facts.
class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: store.resync,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text('Overview', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            _PushCard(store: store),
            const SectionTitle('세션 · 수집',
                subtitle: '/status sessions — 기록된 런 디렉터리 사실'),
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: sectionBody<StatusResponse>(
                  context,
                  store.status,
                  loaded: (_, status) {
                    final latest = status.sessionsLatest;
                    return FactRows(rows: [
                      ('런 디렉터리 수', '${status.sessionsCount ?? '?'}'),
                      ('최근 세션', latest.session ?? '기록 없음'),
                      ('session_date', latest.sessionDate ?? '기록 없음'),
                      ('started_at', latest.startedAt ?? '기록 없음'),
                      ('run.json', latest.runJsonPresent ? '기록 있음' : '기록 없음'),
                    ]);
                  },
                  emptyMessage: '기록된 세션 없음',
                  onRetry: store.resync,
                ),
              ),
            ),
            const SectionTitle('데이터 · 이벤트', subtitle: '/status events — ledger 사실'),
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: sectionBody<StatusResponse>(
                  context,
                  store.status,
                  loaded: (_, status) {
                    if (!status.ledgerPresent) {
                      return const SectionEmpty(message: '기록 없음 — ledger 파일 없음');
                    }
                    final latestEvent = status.latestEvent;
                    final byType = status.byType ?? const <String, int>{};
                    final byTypeText = byType.isEmpty
                        ? '기록 없음'
                        : byType.entries.map((e) => '${e.key}×${e.value}').join(', ');
                    return FactRows(rows: [
                      ('이벤트 수', '${status.eventsCount ?? '?'}'),
                      ('유형별', byTypeText),
                      ('최근 이벤트',
                          latestEvent == null ? '기록 없음' : (latestEvent.eventType ?? '?')),
                      ('관측 시각',
                          latestEvent?.observedAt ?? '기록 없음'),
                    ]);
                  },
                  onRetry: store.resync,
                ),
              ),
            ),
            const SectionTitle('전달 · FCM', subtitle: '/status delivery — 운영 전달 기록'),
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: sectionBody<StatusResponse>(
                  context,
                  store.status,
                  loaded: (_, status) {
                    if (!status.deliveryConfigured) {
                      return const SectionEmpty(
                          message: '전달 미구성 — 서버에 --delivery 미지정');
                    }
                    if (status.deliveryPresent == false) {
                      return const SectionEmpty(message: '전달 기록 파일 없음');
                    }
                    final byState = status.byState ?? const <String, int>{};
                    final byStateText = byState.isEmpty
                        ? '기록 없음'
                        : byState.entries
                            .map((e) => '${e.key}×${e.value}')
                            .join(', ');
                    return FactRows(rows: [
                      ('상태별 (event,device 쌍)', byStateText),
                      ('쌍 수', '${status.deliveryPairs ?? '?'}'),
                      ('기기 수', '${status.deliveryDevices ?? '?'}'),
                    ]);
                  },
                  onRetry: store.resync,
                ),
              ),
            ),
            const SectionTitle('검증', subtitle: '/sessions/{session}/verification — 기록된 검증 사실'),
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: sectionBody<VerificationResponse>(
                  context,
                  store.verification,
                  loaded: (_, verification) {
                    return FactRows(rows: [
                      ('세션', verification.session ?? '기록 없음'),
                      ('커밋 마커',
                          verification.committedMarkerPresent ? '커밋됨' : '미커밋'),
                      ('session_end',
                          verification.sessionEndRecorded ? '기록됨' : '기록 없음'),
                      ('CHECKSUMS',
                          !verification.checksumsPresent
                              ? '기록 없음'
                              : '${verification.artifactsMatchCount}/${verification.artifacts.length} 일치'),
                      ('VERDICT',
                          verification.verdictRecorded
                              ? (verification.verdictLine ?? '기록됨')
                              : '기록 안 됨'),
                    ]);
                  },
                  emptyMessage: '검증 기록 없음',
                  onRetry: store.resync,
                ),
              ),
            ),
            const SectionTitle('상승 후보 (UP)', subtitle: '/candidates — 최근 세션의 기록된 판단'),
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _CandidateList(
                  section: store.candidates,
                  direction: 'UP',
                  emptyMessage: '상승 방향 기록 없음',
                  onRetry: store.resync,
                ),
              ),
            ),
            const SectionTitle('하락 후보 (DOWN)', subtitle: '/candidates — 최근 세션의 기록된 판단'),
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _CandidateList(
                  section: store.candidates,
                  direction: 'DOWN',
                  emptyMessage: '하락 방향 기록 없음',
                  onRetry: store.resync,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CandidateList extends StatelessWidget {
  const _CandidateList({
    required this.section,
    required this.direction,
    required this.emptyMessage,
    this.onRetry,
  });

  final Section<CandidatesResponse> section;
  final String direction;
  final String emptyMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return sectionBody<CandidatesResponse>(
      context,
      section,
      loaded: (context, candidates) {
        if (!candidates.ledgerPresent) {
          return const SectionEmpty(message: '기록 없음 — ledger 파일 없음');
        }
        final list = candidates.byDirection[direction] ??
            const <ApiEvent>[];
        if (list.isEmpty) return SectionEmpty(message: emptyMessage);
        return Column(
          children: [
            for (final event in list)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  direction == 'UP' ? Icons.trending_up : Icons.trending_down,
                  color: direction == 'UP' ? Colors.red : Colors.blue,
                ),
                title: Text(
                  event.symbol != null
                      ? '${event.symbol} (rank ${event.rank ?? '—'})'
                      : (event.eventId ?? '?').substring(0, 12),
                ),
                subtitle: Text(
                    '${event.observedAt ?? '?'} · ${event.severity ?? '?'} · '
                    '${event.dataQuality ?? '?'}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: event.eventId == null
                    ? null
                    : () => AppScope.of(context).openEvent(event.eventId!),
              ),
          ],
        );
      },
      onRetry: onRetry,
    );
  }
}

class _PushCard extends StatelessWidget {
  const _PushCard({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final push = store.pushState;
    final (icon, label) = switch (push.phase) {
      PushPhase.unwired => (
          Icons.notifications_off_outlined,
          '푸시 미연결 — Firebase 미설정 (mobile/README.md handoff 참조)'
        ),
      PushPhase.notAsked => (Icons.notifications_active_outlined, '권한 요청 준비'),
      PushPhase.asking => (Icons.hourglass_top, '권한 요청 중…'),
      PushPhase.granted => (Icons.notifications_active, '푸시 허용됨'),
      PushPhase.denied => (Icons.notifications_off, '푸시 비활성 — 권한 거부됨'),
      PushPhase.provisional => (Icons.notifications_paused, '프로비저널 허용'),
      PushPhase.unknown => (Icons.help_outline, '권한 상태 미확정 — 마지막 요청의 응답이 기록되지 않음'),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(label)),
                if (push.phase == PushPhase.denied ||
                    push.phase == PushPhase.unknown)
                  TextButton(
                    onPressed: store.requestPushPermission,
                    child: const Text('다시 요청'),
                  ),
              ],
            ),
            if (push.askedCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '요청 이력: ${push.askedCount}회'
                  '${push.lastAskedAt == null ? '' : ' · 마지막 ${push.lastAskedAt!.toIso8601String()}'}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).hintColor),
                ),
              ),
            _TokenArea(push: push),
          ],
        ),
      ),
    );
  }
}

class _TokenArea extends StatelessWidget {
  const _TokenArea({required this.push});

  final PushUiState push;

  @override
  Widget build(BuildContext context) {
    final token = push.token;
    final problem = push.tokenError ?? push.notice;
    if (token == null && problem == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('FCM 토큰 (운영자가 tools/notify/register로 서버에 등록)',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          if (token != null)
            SelectableText(
              // Full value, never truncated: the operator copies exactly
              // this identifier into tools/notify/notify_register.py.
              token,
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Text(problem ?? '',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    );
  }
}

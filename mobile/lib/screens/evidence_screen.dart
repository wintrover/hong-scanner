import 'package:flutter/material.dart';

import '../api/api_models.dart';
import 'app_scope.dart';
import 'widgets.dart';

/// Evidence & Verification tab: the selected session's recorded
/// verification facts — CHECKSUMS artifact rows (recorded vs recomputed
/// hash), the events file hash, the committed marker, and the operator
/// recorded VERDICT line quoted verbatim.
///
/// This screen is a list of facts, not an approval: nothing here upgrades
/// "no recorded verdict" into a pass (fail-closed, REPLAY_CONTRACT §0.2).
class EvidenceScreen extends StatelessWidget {
  const EvidenceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    final sessions = store.sessions.value?.sessions ?? const <SessionSummary>[];
    final selected = store.selectedSession;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Evidence',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('검증 관련 기록 사실 — 승인 판정이 아니다 (권위: GATES P12)',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).hintColor)),
          const SizedBox(height: 12),
          if (sessions.isEmpty)
            sectionBody<SessionsResponse>(
              context,
              store.sessions,
              loaded: (_, _) => const SizedBox.shrink(),
              emptyMessage: '기록된 세션(런 디렉터리) 없음',
            )
          else
            DropdownButtonFormField<String>(
              initialValue: selected,
              decoration: const InputDecoration(
                labelText: '세션 (런 디렉터리)',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final summary in sessions)
                  DropdownMenuItem(
                    value: summary.session,
                    child: Text(summary.session ?? '(이름 없음)'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) store.openSessionVerification(value);
              },
            ),
          const SizedBox(height: 12),
          sectionBody<VerificationResponse>(
            context,
            store.verification,
            loaded: (context, verification) => _VerificationBody(
              verification: verification,
              onRetry: () => store.openSessionVerification(verification.session ?? ''),
            ),
            emptyMessage: '선택한 세션의 검증 기록 없음',
            onRetry: selected == null
                ? null
                : () => store.openSessionVerification(selected),
          ),
        ],
      ),
    );
  }
}

class _VerificationBody extends StatelessWidget {
  const _VerificationBody({required this.verification, this.onRetry});

  final VerificationResponse verification;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FactRows(rows: [
              ('세션', verification.session ?? '기록 없음'),
              ('session_date', verification.sessionDate ?? '기록 없음'),
              ('code_commit', verification.codeCommit ?? '기록 없음'),
              ('run.json', verification.runJsonPresent ? '기록 있음' : '기록 없음'),
            ]),
          ),
        ),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FactRows(rows: [
              ('커밋 마커',
                  '${verification.committedMarkerFile ?? '?'} · ${verification.committedMarkerPresent ? '존재' : '없음'}'),
              ('session_end',
                  verification.sessionEndRecorded ? '기록됨' : '기록 없음'),
              ('events 파일',
                  verification.eventsFilePresent ? '존재' : '없음'),
              ('events sha256',
                  verification.eventsFileSha256 ?? '기록 없음'),
            ]),
          ),
        ),
        const SectionTitle('CHECKSUMS',
            subtitle: '기록 해시 vs 재계산 sha256 (계약이 허용한 유일한 재도출)'),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: !verification.checksumsPresent
                ? const SectionEmpty(message: '기록 없음 — CHECKSUMS.sha256 없음')
                : Column(
                    children: [
                      for (final artifact in verification.artifacts)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            artifact.match
                                ? Icons.check_circle_outline
                                : Icons.cancel_outlined,
                            color: artifact.match
                                ? Colors.green
                                : Theme.of(context).colorScheme.error,
                          ),
                          title: Text(artifact.file ?? '?'),
                          subtitle: Text(
                            'recorded ${_short(artifact.recordedSha256)} · '
                            'computed ${_short(artifact.computedSha256)}'
                            '${artifact.note == null ? '' : '\n${artifact.note}'}',
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const SectionTitle('VERDICT (recorded)',
            subtitle: '운영자가 남긴 verify.stdout의 원문 인용 — API가 만든 판정이 아님'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: verification.verdictRecorded
                ? FactRows(rows: [
                    ('source', verification.verdictSource ?? '?'),
                    ('line', verification.verdictLine ?? '?'),
                  ])
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionEmpty(message: '기록 안 됨 — recorded verdict 없음'),
                      if (verification.verdictNote != null)
                        Text(verification.verdictNote!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: Theme.of(context).hintColor)),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  String _short(String? hash) =>
      hash == null ? 'null' : (hash.length <= 16 ? hash : '${hash.substring(0, 16)}…');
}

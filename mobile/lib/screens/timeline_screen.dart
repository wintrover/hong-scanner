import 'package:flutter/material.dart';

import '../api/api_models.dart';
import '../state/app_store.dart';
import 'app_scope.dart';
import 'widgets.dart';

/// Timeline tab: the ledger's events in ledger order.
///
/// The API serves events in ledger append order (contract §2: the API
/// never reorders) — the recorded order of facts. This screen shows that
/// order as-is and says so; it does not re-sort into a " nicer" order that
/// the API never promised.
class TimelineScreen extends StatelessWidget {
  const TimelineScreen({super.key});

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
            Text('Timeline', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text('ledger 기록 순서 (append 순서 — API가 재정렬하지 않음)',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).hintColor)),
            const SizedBox(height: 12),
            sectionBody<EventsResponse>(
              context,
              store.events,
              loaded: (context, events) =>
                  _EventList(events: events, store: store),
              emptyMessage: '기록 없음 — ledger 파일 없음',
              onRetry: store.resync,
            ),
          ],
        ),
      ),
    );
  }
}

class _EventList extends StatelessWidget {
  const _EventList({required this.events, required this.store});

  final EventsResponse events;
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final list = events.events ?? const <ApiEvent>[];
    if (list.isEmpty) return const SectionEmpty(message: '기록된 이벤트 0건');
    return Column(
      children: [
        for (final event in list)
          _EventRow(
            event: event,
            delivery: events.deliveryFor(event.eventId ?? ''),
            selected: event.eventId == store.selectedEventId,
            onTap: event.eventId == null
                ? null
                : () => store.openEvent(event.eventId!),
          ),
      ],
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.delivery,
    required this.selected,
    this.onTap,
  });

  final ApiEvent event;
  final List<DeliveryRecord> delivery;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final direction = event.direction;
    final deliveryBadge = delivery.isEmpty
        ? '전달 기록 없음'
        : delivery.map((r) => r.state ?? '?').toSet().join('/');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: selected
          ? Theme.of(context).colorScheme.secondaryContainer
          : null,
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          switch (direction) {
            'UP' => Icons.trending_up,
            'DOWN' => Icons.trending_down,
            _ => Icons.circle_outlined,
          },
          color: switch (direction) {
            'UP' => Colors.red,
            'DOWN' => Colors.blue,
            _ => null,
          },
        ),
        title: Text(
          '${event.eventType ?? '?'}'
          '${event.symbol == null ? '' : ' · ${event.symbol}'}'
          '${direction == null ? '' : ' · $direction'}'
          '${event.rank == null ? '' : ' #${event.rank}'}',
        ),
        subtitle: Text(
          '${event.observedAt ?? '?'} · ${event.severity ?? '?'} · 전달: $deliveryBadge\n'
          'session_id: ${event.sessionId ?? '?'} · '
          'data_quality: ${event.dataQuality ?? '?'}',
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

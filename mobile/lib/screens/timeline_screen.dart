import 'package:flutter/material.dart';

/// Timeline tab: chronological event list (placeholder rows).
class TimelineScreen extends StatelessWidget {
  const TimelineScreen({super.key});

  static const _placeholderEvents = <String>[
    'Placeholder event #1 — not observed',
    'Placeholder event #2 — not observed',
    'Placeholder event #3 — not observed',
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Timeline', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          for (final event in _placeholderEvents)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.schedule),
                title: Text(event),
                subtitle: const Text('time: —'),
              ),
            ),
        ],
      ),
    );
  }
}

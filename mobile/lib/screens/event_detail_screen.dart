import 'package:flutter/material.dart';

/// Event detail tab: fields for a single event (all placeholders).
class EventDetailScreen extends StatelessWidget {
  const EventDetailScreen({super.key});

  static const _fields = <(String, String)>[
    ('Title', '—'),
    ('Scheduled at', '—'),
    ('Source', '—'),
    ('Status', '—'),
    ('Evidence link', '—'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Event Detail',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          for (final (label, value) in _fields)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.article_outlined),
                title: Text(label),
                trailing: Text(value),
              ),
            ),
        ],
      ),
    );
  }
}

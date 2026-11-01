import 'package:flutter/material.dart';

/// Overview tab: market / collection / verification status summary.
///
/// Static placeholder content only — no real market data enters the app or
/// the repository.
class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  static const _statusLines = <(String, String)>[
    ('Market', 'placeholder — no live data'),
    ('Collection', 'placeholder — not running'),
    ('Verification', 'placeholder — no verdict'),
    ('Push', 'placeholder — not wired'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Overview', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          for (final (label, value) in _statusLines)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.circle_outlined),
                title: Text(label),
                subtitle: Text(value),
              ),
            ),
        ],
      ),
    );
  }
}

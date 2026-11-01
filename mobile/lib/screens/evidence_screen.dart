import 'package:flutter/material.dart';

/// Evidence tab: evidence artifact viewer placeholder.
class EvidenceScreen extends StatelessWidget {
  const EvidenceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Evidence', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          const Card(
            child: ListTile(
              leading: Icon(Icons.fact_check_outlined),
              title: Text('Evidence viewer placeholder'),
              subtitle: Text('No artifacts loaded — nothing observed yet.'),
            ),
          ),
        ],
      ),
    );
  }
}

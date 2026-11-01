import 'package:flutter/material.dart';

import 'screens/evidence_screen.dart';
import 'screens/event_detail_screen.dart';
import 'screens/overview_screen.dart';
import 'screens/timeline_screen.dart';
import 'services/noop_push_service.dart';
import 'services/push_service.dart';

void main() {
  runApp(const HongScannerApp());
}

/// Composition point for push wiring. There is no Firebase project yet, so
/// the app runs with the no-op service; swap to FcmPushService during the
/// Firebase handoff (see README.md in this directory).
PushService defaultPushService() => const NoopPushService();

class HongScannerApp extends StatelessWidget {
  const HongScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hong Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _screens = <Widget>[
    OverviewScreen(),
    TimelineScreen(),
    EventDetailScreen(),
    EvidenceScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Overview',
          ),
          NavigationDestination(
            icon: Icon(Icons.timeline_outlined),
            selectedIcon: Icon(Icons.timeline),
            label: 'Timeline',
          ),
          NavigationDestination(
            icon: Icon(Icons.article_outlined),
            selectedIcon: Icon(Icons.article),
            label: 'Event Detail',
          ),
          NavigationDestination(
            icon: Icon(Icons.fact_check_outlined),
            selectedIcon: Icon(Icons.fact_check),
            label: 'Evidence',
          ),
        ],
      ),
    );
  }
}

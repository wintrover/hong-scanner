import 'package:flutter/material.dart';

import 'api/api_client.dart';
import 'screens/app_scope.dart';
import 'screens/evidence_screen.dart';
import 'screens/event_detail_screen.dart';
import 'screens/overview_screen.dart';
import 'screens/timeline_screen.dart';
import 'services/noop_push_service.dart';
import 'services/push_service.dart';
import 'state/app_store.dart';

void main() {
  runApp(const HongScannerApp());
}

/// Composition point for push wiring. There is no Firebase project yet, so
/// the app runs with the no-op service; swap to FcmPushService during the
/// Firebase handoff (see README.md in this directory). The API base URL is
/// configurable with `--dart-define=HS_API_BASE=…` (default: the Android
/// emulator's host loopback alias).
PushService defaultPushService() => const NoopPushService();

AppStore defaultAppStore() => AppStore(
      apiClient: ApiClient.fromEnvironment(),
      pushService: defaultPushService(),
    );

class HongScannerApp extends StatefulWidget {
  const HongScannerApp({super.key, this.store});

  /// Injectable so tests can drive the app with fakes and fixtures; the
  /// default composition builds the production store once per app run.
  final AppStore? store;

  @override
  State<HongScannerApp> createState() => _HongScannerAppState();
}

class _HongScannerAppState extends State<HongScannerApp> {
  late final AppStore _store;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? defaultAppStore();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      store: _store,
      child: MaterialApp(
        title: 'Hong Scanner',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        home: const RootShell(),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  AppStore? _store;

  static const _screens = <Widget>[
    OverviewScreen(),
    TimelineScreen(),
    EventDetailScreen(),
    EvidenceScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = _store;
      if (store == null) return;
      store.bootstrap(
        onForegroundMessage: _showForegroundBanner,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store ??= AppScope.of(context);
  }

  /// Foreground resume resync: the offline / force-killed / dropped-queue
  /// recovery path. Notification taps route through the store's push
  /// wiring (bootstrap), not the lifecycle observer.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store?.resync();
    }
  }

  /// Foreground delivery policy: with notification+data messages the OS
  /// does not display the notification while the app is in the foreground,
  /// so the app shows an in-app banner. Data-only payloads plus local
  /// notification re-synthesis are forbidden by design — terminated-state
  /// display stays with the OS notification (the official path).
  void _showForegroundBanner(PushMessage message) {
    if (!mounted) return;
    final label = message.eventType ?? message.eventId ?? '페이로드 없음';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('포그라운드 알림 수신: $label'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    return Scaffold(
      body: IndexedStack(index: store.tabIndex, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: store.tabIndex,
        onDestinationSelected: store.selectTab,
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

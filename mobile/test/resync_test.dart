import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/services/push_permission.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Phone-like viewport for gesture tests.
///
/// RefreshIndicator arms at a drag of (viewport × 0.25) ÷ 1.5, so the
/// arming threshold scales with viewport height: a tall 1200×4000 surface
/// needs a ~650 px pull before the indicator fires, and a human-scale
/// 300 px drag is silently cancelled. 800×1000 keeps the Timeline content
/// visible and pull-to-refresh reachable (verified: the same 300 px drag
/// does not resync at 4000 px but does at 1000 px).
Future<void> pumpApp(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HongScannerApp(store: store));
}

/// Resync tests: startup, foreground resume, message-discard recovery,
/// and the bounded backoff on failures.
void main() {
  test('startup performs exactly one sync pass', () async {
    final transport = fixtureTransport();
    final store = makeStore(transport: transport);
    await store.bootstrap();
    expect(store.syncCount, 1);
    final statusCalls = transport.requests
        .where((uri) => uri.path.endsWith('/status'))
        .length;
    expect(statusCalls, 1);
  });

  test('all-sections failure retries with restrained backoff, stays honest',
      () async {
    final backoffs = <Duration>[];
    final store = makeStore(
      transport: FakeTransport((_) async => throw Exception('down')),
      backoffs: backoffs,
    );
    await store.bootstrap();

    expect(store.syncCount, 1);
    expect(backoffs, [const Duration(seconds: 1), const Duration(seconds: 2)],
        reason: 'restrained exponential backoff, capped by max attempts');
    expect(store.status.phase, LoadPhase.error);
    expect(store.status.offline, isTrue);
    expect(store.events.offline, isTrue);
    expect(store.verification.offline, isTrue);
    expect(store.pushState.phase, PushPhase.unwired);
  });

  test('a second sync pass after recovery reloads every section', () async {
    var down = true;
    final healthy = fixtureTransport();
    final transport = FakeTransport((uri) async {
      if (down) throw Exception('down');
      return healthy.get(uri);
    });
    final store = makeStore(transport: transport);
    await store.bootstrap();
    expect(store.status.phase, LoadPhase.error);

    down = false;
    await store.resync();

    expect(store.syncCount, 2);
    expect(store.status.phase, LoadPhase.loaded);
    expect(store.status.value?.eventsCount, 4);
    expect(store.verification.phase, LoadPhase.loaded);
    expect(store.selectedSession, fixtureSession);
  });

  test('partial failure keeps the failed section, loads the rest', () async {
    final transport = fixtureTransport(extra: {
      '/candidates': errorJson(500, 'data_fault', 'ledger line 2 is bad JSON'),
    });
    final store = makeStore(transport: transport);
    await store.bootstrap();

    expect(store.candidates.phase, LoadPhase.error);
    expect(store.candidates.offline, isFalse);
    expect(store.candidates.errorMessage, contains('data_fault'));
    expect(store.status.phase, LoadPhase.loaded);
    expect(store.events.phase, LoadPhase.loaded);
    expect(store.verification.phase, LoadPhase.loaded);
  });

  testWidgets('foreground resume (lifecycle) triggers a resync',
      (WidgetTester tester) async {
    final transport = fixtureTransport();
    final store = makeStore(transport: transport);
    await store.bootstrap();
    await tester.pumpWidget(HongScannerApp(store: store));
    final requestsAfterBootstrap = transport.requests.length;

    // Simulate the app going to background and coming back.
    tester.binding
        .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(store.syncCount, 2);
    expect(transport.requests.length, greaterThan(requestsAfterBootstrap));
  });

  testWidgets('pull-to-refresh on the timeline resyncs',
      (WidgetTester tester) async {
    final transport = fixtureTransport();
    final store = makeStore(transport: transport);
    await store.bootstrap();
    await pumpApp(tester, store);

    // Switch to the Timeline tab, then pull down on its list content.
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    // A slow drag past the refresh threshold triggers the indicator;
    // a fling is too fast and cancels it.
    await tester.drag(find.byType(RefreshIndicator), const Offset(0, 300));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(store.syncCount, greaterThanOrEqualTo(2),
        reason: 'RefreshIndicator.onRefresh is store.resync');
  });
}

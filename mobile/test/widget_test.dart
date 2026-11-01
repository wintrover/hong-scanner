import 'package:flutter_test/flutter_test.dart';

import 'package:hongscanner/main.dart';

void main() {
  testWidgets('all four screens render via bottom navigation', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const HongScannerApp());

    // Overview is the initial tab.
    expect(find.text('Market'), findsOneWidget);
    expect(find.text('placeholder — no live data'), findsOneWidget);
    expect(find.text('placeholder — not running'), findsOneWidget);
    expect(find.text('placeholder — no verdict'), findsOneWidget);
    expect(find.text('placeholder — not wired'), findsOneWidget);

    // Timeline tab.
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    expect(find.text('Placeholder event #1 — not observed'), findsOneWidget);
    expect(find.text('Placeholder event #3 — not observed'), findsOneWidget);

    // Event Detail tab.
    await tester.tap(find.text('Event Detail'));
    await tester.pumpAndSettle();
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Scheduled at'), findsOneWidget);
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Evidence link'), findsOneWidget);

    // Evidence tab.
    await tester.tap(find.text('Evidence'));
    await tester.pumpAndSettle();
    expect(find.text('Evidence viewer placeholder'), findsOneWidget);
    expect(find.text('No artifacts loaded — nothing observed yet.'),
        findsOneWidget);

    // Back to Overview: IndexedStack keeps state across tab switches.
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.text('placeholder — no live data'), findsOneWidget);
  });
}

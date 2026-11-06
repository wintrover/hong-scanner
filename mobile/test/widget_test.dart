import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hongscanner/main.dart';
import 'package:hongscanner/state/app_store.dart';

import 'test_kit.dart';

/// Pump with a tall test viewport: ListViews build children lazily, so a
/// default 800x600 surface never builds the below-the-fold cards these
/// assertions target. A 1200x4000 surface builds the whole list.
Future<void> pumpTallApp(WidgetTester tester, AppStore store) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(HongScannerApp(store: store));
}

void main() {
  testWidgets(
      'all four screens render recorded fixture facts via bottom navigation',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport());
    await store.bootstrap();
    await pumpTallApp(tester, store);

    // Overview is the initial tab: recorded session/data/verification
    // facts from the fixture API.
    expect(find.text('세션 · 수집'), findsOneWidget);
    expect(find.text('상승 후보 (UP)'), findsOneWidget);
    expect(find.text('하락 후보 (DOWN)'), findsOneWidget);
    expect(find.text('005930 (rank 1)'), findsOneWidget);
    expect(find.text('000660 (rank 1)'), findsOneWidget);
    expect(find.text('VERDICT MATCH'), findsOneWidget);
    // Push unwired state is honest about Firebase being absent.
    expect(find.textContaining('푸시 미연결 — Firebase 미설정'), findsOneWidget);

    // Timeline tab: ledger order with recorded fields.
    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    expect(find.text('CANDIDATE_ENTERED · 005930 · UP #1'), findsOneWidget);
    expect(find.text('CANDIDATE_ENTERED · 000660 · DOWN #1'), findsOneWidget);
    expect(find.text('SESSION_ENDED'), findsOneWidget);
    expect(find.textContaining('전달: ACCEPTED'), findsOneWidget);
    expect(find.textContaining('전달 기록 없음'), findsNWidgets(3));

    // Event Detail tab (no selection yet).
    await tester.tap(find.text('Event Detail'));
    await tester.pumpAndSettle();
    expect(find.text('이벤트 미선택'), findsOneWidget);

    // Evidence tab: verification facts with honest session selector.
    await tester.tap(find.text('Evidence'));
    await tester.pumpAndSettle();
    expect(find.text('VERDICT MATCH'), findsOneWidget);
    expect(find.textContaining('원문 인용'), findsOneWidget);
    // The session id renders twice by design: once on the Overview session
    // card (최근 세션) and once as the Evidence tab's selected-session text.
    expect(find.text(fixtureSession), findsNWidgets(2));

    // Back to Overview: IndexedStack keeps state across tab switches.
    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.text('세션 · 수집'), findsOneWidget);
  });

  testWidgets('timeline tap routes into the event detail tab',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport());
    await store.bootstrap();
    await pumpTallApp(tester, store);

    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CANDIDATE_ENTERED · 000660 · DOWN #1'));
    await tester.pumpAndSettle();

    expect(store.tabIndex, AppStore.detailTabIndex);
    expect(store.selectedEventId, evDownEnterId);
    // The detail tab now shows the recorded fact, verbatim fields and
    // delivery section.
    expect(find.text('근거 (evidence_ref)'), findsOneWidget);
    // 근거 card + recorded fact table both show the evidence reference.
    expect(find.text('ka10027:stex_tp=1:sort_tp=1'), findsNWidgets(2));
    expect(find.text('전달 기록 없음'), findsOneWidget);
    expect(find.text('event_id'), findsOneWidget);
    expect(find.text('direction'), findsOneWidget);
    expect(find.text('DOWN'), findsOneWidget);
  });

  testWidgets('empty ledger renders honest absence, not fake content',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport(extra: {
      '/status': okJson({
        'delivery': {
          'by_state': null,
          'configured': false,
          'devices': null,
          'pairs': null,
          'present': null,
        },
        'events': {
          'by_severity': null,
          'by_type': null,
          'count': null,
          'latest_event': null,
          'latest_session_id': null,
          'ledger_present': false,
        },
        'sessions': {'count': 0, 'latest': null},
      }),
      '/candidates': okJson({
        'count': null,
        'events': null,
        'ledger_present': false,
        'session_id': null,
      }),
      '/events': okJson({
        'count': null,
        'delivery': null,
        'events': null,
        'ledger_present': false,
      }),
      '/sessions': okJson({'count': 0, 'sessions': []}),
    }));
    await store.bootstrap();
    await pumpTallApp(tester, store);

    // 데이터 card + 상승 후보 + 하락 후보 all say the ledger file is absent.
    expect(find.text('기록 없음 — ledger 파일 없음'), findsNWidgets(3));
    expect(find.text('전달 미구성 — 서버에 --delivery 미지정'), findsOneWidget);
    // With no recorded session the verification section says why it did
    // not fetch, instead of inventing an empty success.
    expect(find.textContaining('최근 세션을 확인할 수 없어'), findsOneWidget);
    // Nothing loaded, so no candidate rows anywhere.
    expect(find.textContaining('(rank'), findsNothing);
  });

  testWidgets('timeline rows show recorded session_id and data_quality',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport());
    await store.bootstrap();
    await pumpTallApp(tester, store);

    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();

    // Each row shows the fact's recorded provenance fields verbatim:
    // session_id on all four rows, OBSERVING on the three candidate
    // facts, INCOMPLETE on the session-end fact.
    expect(find.textContaining('session_id: 2026-11-02'), findsNWidgets(4));
    expect(find.textContaining('data_quality: OBSERVING'), findsNWidgets(3));
    expect(find.textContaining('data_quality: INCOMPLETE'), findsOneWidget);
  });

  testWidgets('timeline rows keep honest ? for absent provenance fields',
      (WidgetTester tester) async {
    final store = makeStore(transport: fixtureTransport(extra: {
      '/events': okJson({
        'count': 1,
        'delivery': null,
        'events': [
          <String, Object?>{
            ...evUpEnter,
            'data_quality': null,
            'session_id': null,
          }
        ],
        'ledger_present': true,
      }),
    }));
    await store.bootstrap();
    await pumpTallApp(tester, store);

    await tester.tap(find.text('Timeline'));
    await tester.pumpAndSettle();

    // Absence renders as '?' like the row's other optional fields —
    // never as an invented value.
    expect(find.textContaining('session_id: ?'), findsOneWidget);
    expect(find.textContaining('data_quality: ?'), findsOneWidget);
  });

  testWidgets('offline server surfaces an honest offline state with retry',
      (WidgetTester tester) async {
    final store = makeStore(
      transport: FakeTransport(
          (_) async => throw Exception('connection refused')),
      backoffs: [],
    );
    await store.bootstrap();
    await pumpTallApp(tester, store);

    expect(find.text('오프라인'), findsWidgets);
    expect(find.text('다시 시도'), findsWidgets);
    expect(find.textContaining('기록을 읽는 중'), findsNothing,
        reason: 'offline is an error state, not an eternal spinner');
  });
}

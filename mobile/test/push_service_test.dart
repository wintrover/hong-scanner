import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/services/fcm_push_service.dart';
import 'package:hongscanner/services/noop_push_service.dart';
import 'package:hongscanner/services/push_permission.dart';
import 'package:hongscanner/services/push_service.dart';

void main() {
  group('NoopPushService', () {
    test(
        'is a no-op: not ready, no token, permission answers nothing-was-asked',
        () async {
      final PushService service = const NoopPushService();

      expect(service.isReady, isFalse);
      expect(await service.getToken(), isNull);
      expect(await service.requestPermission(), isNull);
    });

    test('does not implement PushMessageSource (no fake streams)', () {
      expect(const NoopPushService(), isNot(isA<PushMessageSource>()));
    });
  });

  group('FcmPushService', () {
    test('instantiates without any Firebase initialization', () {
      const PushService service = FcmPushService();

      expect(service, isA<FcmPushService>());
      expect(service.isReady, isFalse, reason: 'Firebase.apps is empty');
    });

    test('fails closed when used before Firebase.initializeApp', () {
      const FcmPushService service = FcmPushService();

      expect(() => service.getToken(), throwsStateError);
      expect(() => service.requestPermission(), throwsStateError);
    });

    test('message source fails closed before initialization too', () {
      const FcmPushService service = FcmPushService();

      expect(() => service.foregroundMessages, throwsStateError);
      expect(() => service.tapMessages, throwsStateError);
      expect(() => service.initialMessage(), throwsStateError);
    });
  });

  test('default push service is the no-op until Firebase is wired', () {
    final PushService service = defaultPushService();

    expect(service, isA<NoopPushService>());
    expect(service.isReady, isFalse);
  });

  test('default app store composes the no-op service', () {
    final store = defaultAppStore();
    expect(store.pushState.phase, PushPhase.unwired);
    store.dispose();
  });

  group('PushPermissionLedger', () {
    test('round-trips ask history through any KeyValueStore', () async {
      final kv = MemoryKeyValueStore();
      final ledger = PushPermissionLedger(store: kv);

      final before = await ledger.load();
      expect(before.neverAsked, isTrue);
      expect(before.askedCount, 0);

      await ledger.recordAsk(
        at: DateTime(2026, 11, 2, 9),
        response: PushPermissionDecision.denied,
      );
      await ledger.recordAsk(at: DateTime(2026, 11, 3, 9));

      final after = await ledger.load();
      expect(after.askedCount, 2);
      expect(after.lastResponse, PushPermissionDecision.denied,
          reason: 'an ask without a recorded answer keeps the previous one');
      expect(after.lastAskedAt, DateTime(2026, 11, 3, 9));
      expect(after.neverAsked, isFalse);
    });

    test('unknown response names stay null instead of crashing', () async {
      final kv = MemoryKeyValueStore();
      await kv.write('hs.push.last.response', 'maybe');
      final record = await PushPermissionLedger(store: kv).load();
      expect(record.lastResponse, isNull);
    });
  });
}

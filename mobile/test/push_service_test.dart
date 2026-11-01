import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/main.dart';
import 'package:hongscanner/services/fcm_push_service.dart';
import 'package:hongscanner/services/noop_push_service.dart';
import 'package:hongscanner/services/push_service.dart';

void main() {
  group('NoopPushService', () {
    test('is a no-op: not ready, no token, permission completes', () async {
      final PushService service = const NoopPushService();

      expect(service.isReady, isFalse);
      expect(await service.getToken(), isNull);
      await service.requestPermission();
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
  });

  test('default push service is the no-op until Firebase is wired', () {
    final PushService service = defaultPushService();

    expect(service, isA<NoopPushService>());
    expect(service.isReady, isFalse);
  });
}

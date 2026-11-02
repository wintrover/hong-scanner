import 'push_service.dart';

/// Default [PushService]: explicitly does nothing.
///
/// Reports not-ready and answers null ("nothing was asked") instead of
/// silently pretending that push is active. It is deliberately not a
/// [PushTokenSource] or [PushMessageSource]: an unwired service has no
/// registration to fake.
class NoopPushService implements PushService {
  const NoopPushService();

  @override
  bool get isReady => false;

  @override
  Future<PushPermissionDecision?> requestPermission() async => null;
}

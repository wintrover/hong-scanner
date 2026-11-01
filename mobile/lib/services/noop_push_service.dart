import 'push_service.dart';

/// Default [PushService]: explicitly does nothing.
///
/// Reports not-ready, yields no token, and answers null ("nothing was
/// asked") instead of silently pretending that push is active.
class NoopPushService implements PushService {
  const NoopPushService();

  @override
  bool get isReady => false;

  @override
  Future<String?> getToken() async => null;

  @override
  Future<PushPermissionDecision?> requestPermission() async => null;
}

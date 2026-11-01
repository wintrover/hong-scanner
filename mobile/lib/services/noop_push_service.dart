import 'push_service.dart';

/// Default [PushService]: explicitly does nothing.
///
/// Reports not-ready and yields no token instead of silently pretending that
/// push is active.
class NoopPushService implements PushService {
  const NoopPushService();

  @override
  bool get isReady => false;

  @override
  Future<String?> getToken() async => null;

  @override
  Future<void> requestPermission() async {}
}

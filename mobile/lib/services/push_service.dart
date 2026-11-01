/// Abstraction over push notification wiring.
///
/// Implementations must fail closed: a service that is not wired reports
/// [isReady] == false and must not pretend that registration succeeded.
abstract class PushService {
  const PushService();

  /// Whether the underlying push infrastructure is wired and usable.
  bool get isReady;

  /// Returns the push token, or null when no token is available.
  Future<String?> getToken();

  /// Requests permission to show notifications.
  Future<void> requestPermission();
}

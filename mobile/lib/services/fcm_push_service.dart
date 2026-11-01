import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'push_service.dart';

/// FCM-backed [PushService].
///
/// Fail-closed by construction: with no Firebase project there is no
/// google-services.json and no Firebase.initializeApp, so [isReady] is
/// false and every call throws [StateError] instead of reporting success.
/// The app ships with [NoopPushService] until the Firebase handoff
/// (mobile/README.md) swaps the composition point.
class FcmPushService implements PushService, PushMessageSource {
  const FcmPushService();

  bool get _wired => Firebase.apps.isNotEmpty;

  Never _throwUnwired() => throw StateError(
    'FcmPushService is not wired: Firebase.initializeApp / google-services '
    'setup has not been done yet. See mobile/README.md.',
  );

  @override
  bool get isReady => _wired;

  @override
  Future<String?> getToken() {
    if (!_wired) _throwUnwired();
    // Scaffold contract pins getToken(); 17.x deprecates it in favor of
    // register()/onRegistered — migrate during the Firebase handoff.
    // ignore: deprecated_member_use
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Future<PushPermissionDecision?> requestPermission() {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.instance.requestPermission().then(
      (settings) => switch (settings.authorizationStatus) {
        AuthorizationStatus.authorized => PushPermissionDecision.granted,
        AuthorizationStatus.denied => PushPermissionDecision.denied,
        // Permanent denial is still a denial — recorded as such; the
        // Overview card stays honest and the OS will not re-prompt.
        AuthorizationStatus.deniedPermanently => PushPermissionDecision.denied,
        // No recorded decision: the store keeps the ask history but the
        // phase stays "unknown" instead of inventing an answer.
        AuthorizationStatus.notDetermined => null,
        AuthorizationStatus.provisional => PushPermissionDecision.provisional,
      },
    );
  }

  /// Pure mapping from the plugin type to our [PushMessage]. Static and
  /// dependency-free so tests can exercise it with constructed
  /// [RemoteMessage] stubs — no Firebase init needed.
  static PushMessage messageFromRemote(RemoteMessage message) =>
      PushMessage.fromData(message.data);

  FirebaseMessaging get _messaging {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.instance;
  }

  @override
  Stream<PushMessage> get foregroundMessages {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.onMessage.map(messageFromRemote);
  }

  @override
  Stream<PushMessage> get tapMessages {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.onMessageOpenedApp.map(messageFromRemote);
  }

  @override
  Future<PushMessage?> initialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : messageFromRemote(message);
  }
}

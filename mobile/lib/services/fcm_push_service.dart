import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'push_service.dart';

/// FCM-backed [PushService] skeleton.
///
/// Deliberately not wired yet: no Firebase project exists, so there is no
/// google-services.json and no Firebase.initializeApp call. Every call fails
/// closed with a [StateError] instead of reporting success.
class FcmPushService implements PushService {
  const FcmPushService();

  bool get _wired => Firebase.apps.isNotEmpty;

  @override
  bool get isReady => _wired;

  Never _throwUnwired() => throw StateError(
    'FcmPushService is not wired: Firebase.initializeApp / google-services '
    'setup has not been done yet. See mobile/README.md.',
  );

  @override
  Future<String?> getToken() {
    if (!_wired) _throwUnwired();
    // Scaffold contract pins getToken(); 17.x deprecates it in favor of
    // register()/onRegistered — migrate during the Firebase handoff.
    // ignore: deprecated_member_use
    return FirebaseMessaging.instance.getToken();
  }

  @override
  Future<void> requestPermission() {
    if (!_wired) _throwUnwired();
    return FirebaseMessaging.instance.requestPermission();
  }
}

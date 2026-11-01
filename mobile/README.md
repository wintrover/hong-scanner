# hongscanner (mobile)

Flutter scaffold for the Hong Scanner mobile app. This is the base for the
full app; all screens are static placeholders — no real market data is
included (repo rule: 실시장 데이터는 저장소에 들어오지 않는다).

## Layout

- `lib/main.dart` — app root, bottom-navigation shell (4 tabs),
  `defaultPushService()` composition point
- `lib/screens/` — Overview, Timeline, Event Detail, Evidence (placeholders)
- `lib/services/push_service.dart` — `PushService` abstraction
- `lib/services/noop_push_service.dart` — `NoopPushService` (default wiring)
- `lib/services/fcm_push_service.dart` — `FcmPushService` skeleton (fail-closed)

## Requirements

- Dart ^3.6.0 / Flutter ≥ 3.27 (required by firebase_messaging 17.x)
- Android `minSdk 24` — set in `android/app/build.gradle.kts`
- Dependencies: `firebase_core`, `firebase_messaging: ^17.0.1`

## Not wired yet — Firebase handoff checklist

No Firebase project exists yet. When it arrives, do exactly this:

1. **google-services.json** — place it at `android/app/google-services.json`
   (download from the Firebase console, package name
   `com.hongscanner.hongscanner`).
2. **Gradle plugin** — declare `com.google.gms.google-services` in
   `android/settings.gradle.kts` and apply it in `android/app/build.gradle.kts`.
   Until then the build succeeds but the app has no Firebase config.
3. **firebase_options.dart** — run `flutterfire configure` to generate
   `lib/firebase_options.dart`, then call
   `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`
   before any FCM usage.
4. **Swap the push service** — replace `defaultPushService()` in
   `lib/main.dart` with `const FcmPushService()`. It currently fails closed
   (throws `StateError`) until `Firebase.apps` is non-empty, so it must not
   be installed before step 3 succeeds.
5. **Token API migration** — firebase_messaging 17.x deprecates
   `getToken()`/`onTokenRefresh` in favor of `register()`/`onRegistered`;
   `FcmPushService.getToken()` keeps the deprecated call (scaffold contract,
   suppressed lint) and should migrate at handoff.

## Local toolchain used for this scaffold

- Flutter SDK: `~/sdk/flutter` (stable)
- Android SDK: `~/sdk/android-sdk` (platform-tools, build-tools;34.0.0,
  platforms;android-35, platforms;android-36)

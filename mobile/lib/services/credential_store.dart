import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/credentials.dart';

/// Persistence for the API credential pair.
///
/// Credentials belong only in the platform's secure storage (Android:
/// Keystore-backed, via flutter_secure_storage) — never in
/// shared_preferences, logs, or the repository. Implementations keep both
/// halves together: half a pair is not a usable credential and must read
/// back as null.
abstract interface class CredentialStore {
  /// The stored pair, or null when nothing usable was stored.
  Future<Credentials?> load();

  Future<void> save(Credentials credentials);
}

/// In-memory implementation for tests — the same substitution pattern as
/// MemoryKeyValueStore for the permission ledger.
class MemoryCredentialStore implements CredentialStore {
  Credentials? _value;

  @override
  Future<Credentials?> load() async => _value;

  @override
  Future<void> save(Credentials credentials) async {
    _value = credentials;
  }
}

/// Production store over flutter_secure_storage. The plugin's default
/// Android options already do what the contract requires: the encryption
/// key is wrapped with RSA-OAEP inside the Android Keystore and the data
/// is AES-GCM encrypted (API 23+, minSdk 24) — no plaintext, no
/// shared_preferences path.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _usernameKey = 'hs.api.username';
  static const String _passwordKey = 'hs.api.password';

  final FlutterSecureStorage _storage;

  @override
  Future<Credentials?> load() async {
    final username = await _storage.read(key: _usernameKey);
    final password = await _storage.read(key: _passwordKey);
    if (username == null || password == null) return null;
    return Credentials(username: username, password: password);
  }

  @override
  Future<void> save(Credentials credentials) async {
    await _storage.write(key: _usernameKey, value: credentials.username);
    await _storage.write(key: _passwordKey, value: credentials.password);
  }
}

import 'package:shared_preferences/shared_preferences.dart';

import 'push_service.dart';

/// Minimal key-value persistence so tests can use an in-memory fake and
/// production code stays honest about being the only plugin boundary the
/// permission flow needs.
abstract class KeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

class SharedPreferencesKeyValueStore implements KeyValueStore {
  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  @override
  Future<String?> read(String key) async => (await _prefs()).getString(key);

  @override
  Future<void> write(String key, String value) async {
    await (await _prefs()).setString(key, value);
  }
}

/// What the push card tells the operator. `unknown` means we asked and the
/// platform answer was lost or errored — the UI says so instead of
/// guessing; `unwired` means Firebase is not set up yet.
enum PushPhase { unwired, notAsked, asking, granted, denied, provisional, unknown }

/// Persisted record of whether the app already asked for notification
/// permission, and what came back.
///
/// Android 13+ cannot distinguish "user denied" from "asked before and
/// permanently denied" — both surface as denied. The ask history is the
/// app's own recorded fact: it is the only way the first-run auto-ask can
/// stay a one-time event instead of nagging on every launch.
class PushPermissionLedger {
  PushPermissionLedger({KeyValueStore? store})
      : _store = store ?? SharedPreferencesKeyValueStore();

  static const String _askedCountKey = 'hs.push.asked.count';
  static const String _lastAskedAtKey = 'hs.push.last.asked.at';
  static const String _lastResponseKey = 'hs.push.last.response';

  final KeyValueStore _store;

  Future<PushPermissionRecord> load() async {
    final count = int.tryParse(await _store.read(_askedCountKey) ?? '0') ?? 0;
    final lastAskedAt = DateTime.tryParse(
        await _store.read(_lastAskedAtKey) ?? '');
    final responseName = await _store.read(_lastResponseKey);
    final response = PushPermissionDecision.values
        .where((d) => d.name == responseName)
        .firstOrNull;
    return PushPermissionRecord(
      askedCount: count,
      lastAskedAt: lastAskedAt,
      lastResponse: response,
    );
  }

  Future<void> recordAsk({
    required DateTime at,
    PushPermissionDecision? response,
  }) async {
    final current = await load();
    await _store.write(_askedCountKey, '${current.askedCount + 1}');
    await _store.write(_lastAskedAtKey, at.toIso8601String());
    if (response != null) {
      await _store.write(_lastResponseKey, response.name);
    }
  }
}

class PushPermissionRecord {
  const PushPermissionRecord({
    required this.askedCount,
    this.lastAskedAt,
    this.lastResponse,
  });

  final int askedCount;
  final DateTime? lastAskedAt;
  final PushPermissionDecision? lastResponse;

  /// Never asked before — the one case where the app asks automatically
  /// on startup.
  bool get neverAsked => askedCount == 0;
}

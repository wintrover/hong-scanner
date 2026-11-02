import 'dart:convert';

/// The Basic-auth credential pair sent as
/// `Authorization: Basic <base64(username:password)>` on every API request
/// when the serving origin requires it (e.g. the Northflank HTTPS front).
///
/// A pure value type — no storage, no I/O. Persistence lives in
/// services/credential_store.dart over the platform's secure storage.
/// The toString override is fail-closed: an accidental debug print of the
/// value never carries either half of the credential (자격증명 로그 출력
/// 금지).
class Credentials {
  const Credentials({required this.username, required this.password});

  final String username;
  final String password;

  /// `Basic ${base64(utf8('username:password'))}` — the header value the
  /// API client sends verbatim. UTF-8, so non-ASCII credentials encode
  /// correctly (RFC 7617 defaults to ISO-8859-1 only as a fallback).
  String get authorizationHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  @override
  bool operator ==(Object other) =>
      other is Credentials &&
      other.username == username &&
      other.password == password;

  @override
  int get hashCode => Object.hash(username, password);

  @override
  String toString() => 'Credentials(****)';
}

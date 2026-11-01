import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongscanner/api/api_client.dart';

import 'test_kit.dart';

void main() {
  group('ApiClient request building', () {
    test('default base URL targets the emulator host loopback alias', () {
      // Documented default: the API binds 127.0.0.1 only; the emulator
      // reaches the host loopback via 10.0.2.2.
      expect(ApiClient.defaultBaseUrl, 'http://10.0.2.2:8080');
    });

    test('rejects non-origin base URLs', () {
      expect(() => ApiClient(baseUrl: 'not a url'), throwsArgumentError);
      expect(
        () => ApiClient(baseUrl: 'http://10.0.2.2:8080?x=1'),
        throwsArgumentError,
      );
    });

    test('builds GET paths under the base origin', () async {
      final transport = FakeTransport(
          (_) async => okJson(fixtureStatus));
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080', transport: transport);
      await client.fetchStatus();
      expect(transport.requests.single.toString(),
          'http://127.0.0.1:8080/status');
      client.close();
      expect(transport.closed, isFalse,
          reason: 'an injected transport is owned by the caller; close() '
              'only closes transports the client created itself');
    });

    test('session_id filter becomes a query parameter', () async {
      Uri? captured;
      final transport = FakeTransport((uri) async {
        captured = uri;
        return okJson(fixtureEvents);
      });
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080', transport: transport);
      await client.fetchEvents(sessionId: '2026-10-30');
      expect(captured!.queryParameters['session_id'], '2026-10-30');
    });
  });

  group('ApiClient identifier validation (server rules, client-side)', () {
    test('non-hex event id is refused before any request', () async {
      final transport = FakeTransport((_) async => okJson(fixtureStatus));
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080', transport: transport);
      await expectLater(
        client.fetchEvent('../../etc/passwd'),
        throwsA(isA<ApiClientException>()
            .having((e) => e.code, 'code', ApiErrorCode.invalidIdentifier)),
      );
      expect(transport.requests, isEmpty,
          reason: 'invalid identifiers must not reach the wire');
    });

    test('uppercase or short event id is refused', () async {
      final client = ApiClient(
        baseUrl: 'http://127.0.0.1:8080',
        transport: FakeTransport((_) async => okJson(fixtureStatus)),
      );
      for (final bad in ['ABC', 'a' * 63, 'A' * 64]) {
        await expectLater(
          client.fetchEvent(bad),
          throwsA(isA<ApiClientException>()),
          reason: bad,
        );
      }
    });

    test('path-traversal session name is refused before any request', () async {
      final transport = FakeTransport((_) async => okJson(fixtureSessions));
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080', transport: transport);
      await expectLater(
        client.fetchVerification('../other-run'),
        throwsA(isA<ApiClientException>()
            .having((e) => e.code, 'code', ApiErrorCode.invalidIdentifier)),
      );
      expect(transport.requests, isEmpty);
    });
  });

  group('ApiClient response parsing (contract shapes)', () {
    test('fetchStatus parses the recorded blocks', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      final status = await client.fetchStatus();
      expect(status.sessionsCount, 1);
      expect(status.sessionsLatest.session, fixtureSession);
      expect(status.sessionsLatest.sessionDate, '2026-11-02');
      expect(status.ledgerPresent, isTrue);
      expect(status.eventsCount, 4);
      expect(status.byType?['CANDIDATE_ENTERED'], 2);
      expect(status.latestEvent?.eventType, 'SESSION_ENDED');
      expect(status.deliveryConfigured, isTrue);
      expect(status.deliveryPresent, isTrue);
      expect(status.byState, {'ACCEPTED': 1});
    });

    test('fetchStatus keeps null = no record (absent ledger, unconfigured)',
        () async {
      final absentLedger = {
        'delivery': {
          'by_state': null,
          'configured': false,
          'devices': null,
          'pairs': null,
          'present': null,
        },
        'events': {
          'by_severity': null,
          'by_type': null,
          'count': null,
          'latest_event': null,
          'latest_session_id': null,
          'ledger_present': false,
        },
        'sessions': {'count': 0, 'latest': null},
      };
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport(
              (uri) async => uri.path.endsWith('/status')
                  ? okJson(absentLedger)
                  : errorJson(404, 'not_found', 'nothing here')));
      final status = await client.fetchStatus();
      expect(status.ledgerPresent, isFalse);
      expect(status.eventsCount, isNull,
          reason: 'absent ledger is null, never a fake zero');
      expect(status.byType, isNull);
      expect(status.deliveryConfigured, isFalse);
      expect(status.deliveryPresent, isNull);
      expect(status.byState, isNull);
    });

    test('fetchCandidates keeps direction facts for grouping', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      final candidates = await client.fetchCandidates();
      expect(candidates.count, 3);
      expect(candidates.sessionId, '2026-11-02');
      expect(candidates.byDirection['UP']?.length, 2);
      expect(candidates.byDirection['DOWN']?.length, 1);
      expect(candidates.byDirection['DOWN']?.first.symbol, '000660');
    });

    test('fetchEvents joins nothing: facts and delivery stay separate',
        () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      final events = await client.fetchEvents();
      expect(events.count, 4);
      expect(events.events?.length, 4);
      expect(events.delivery?.keys, [evUpEnterId]);
      expect(events.deliveryFor(evUpEnterId).single.state, 'ACCEPTED');
      expect(events.deliveryFor(evSessionEndId), isEmpty,
          reason: 'no key means no delivery record — honest absence');
    });

    test('fetchEvent returns fact plus its delivery records', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      final detail = await client.fetchEvent(evUpEnterId);
      expect(detail.event.eventType, 'CANDIDATE_ENTERED');
      expect(detail.event.direction, 'UP');
      expect(detail.event.evidenceRef, 'ka10027:stex_tp=1:sort_tp=1');
      expect(detail.event.rank, 1);
      expect(detail.delivery.single.deviceId, 'dev-1');
    });

    test('fetchSessions parses the run directory list', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      final sessions = await client.fetchSessions();
      expect(sessions.count, 1);
      expect(sessions.sessions.single.session, fixtureSession);
      expect(sessions.sessions.single.runJsonPresent, isTrue);
    });

    test('fetchVerification parses checksums and recorded verdict', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      final verification =
          await client.fetchVerification(fixtureSession);
      expect(verification.committedMarkerPresent, isTrue);
      expect(verification.sessionEndRecorded, isTrue);
      expect(verification.checksumsPresent, isTrue);
      expect(verification.artifacts, hasLength(2));
      expect(verification.artifacts.first.match, isTrue);
      expect(verification.artifacts[1].match, isFalse);
      expect(verification.artifactsMatchCount, 1);
      expect(verification.verdictRecorded, isTrue);
      expect(verification.verdictLine, 'VERDICT MATCH');
      expect(verification.verdictSource, 'verify.stdout');
    });

    test('unrecorded verdict stays unrecorded (fail-closed)', () {
      final verification = parseVerification({
        'checksums': {'artifacts': [], 'present': false},
        'committed_marker': {'file': 'input.hcj.jsonl.committed', 'present': false},
        'events_file': {'present': false, 'sha256': null},
        'replay_verdict': {
          'note': 'verify.stdout present but no VERDICT line recorded',
          'recorded': false,
        },
        'run_json_present': false,
        'session': fixtureSession,
        'session_date': null,
        'session_end_recorded': false,
        'code_commit': null,
      });
      expect(verification.verdictRecorded, isFalse);
      expect(verification.verdictNote,
          'verify.stdout present but no VERDICT line recorded');
      expect(verification.checksumsPresent, isFalse);
      expect(verification.artifacts, isEmpty);
      expect(verification.sessionDate, isNull);
      expect(verification.codeCommit, isNull);
    });
  });

  group('ApiClient fail-closed errors', () {
    test('404 not_found carries status and server code', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: fixtureTransport());
      try {
        await client.fetchEvent('0' * 64);
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.statusCode, 404);
        expect(e.serverCode, 'not_found');
        expect(e.isConnectivityProblem, isFalse);
      }
    });

    test('500 data_fault is a server fault, not offline', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport(
              (_) async => errorJson(500, 'data_fault', 'ledger line 3 is bad JSON')));
      try {
        await client.fetchEvents();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.statusCode, 500);
        expect(e.serverCode, 'data_fault');
        expect(e.isConnectivityProblem, isFalse);
      }
    });

    test('socket failure classifies as network (offline)', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport(
              (_) async => throw const SocketFailure()));
      try {
        await client.fetchStatus();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.code, ApiErrorCode.network);
        expect(e.isConnectivityProblem, isTrue);
      }
    });

    test('non-JSON body classifies as format error', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport((_) async => TransportResponse(
              statusCode: 200, body: utf8.encode('<html>502</html>'))));
      try {
        await client.fetchStatus();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.code, ApiErrorCode.format);
      }
    });

    test('error body without error object still yields http code', () async {
      final client = ApiClient(
          baseUrl: 'http://127.0.0.1:8080',
          transport: FakeTransport((_) async =>
              TransportResponse(statusCode: 503, body: utf8.encode('{"x":1}\n'))));
      try {
        await client.fetchStatus();
        fail('expected ApiClientException');
      } on ApiClientException catch (e) {
        expect(e.code, ApiErrorCode.http);
        expect(e.statusCode, 503);
        expect(e.serverCode, isNull);
      }
    });
  });
}

class SocketFailure implements Exception {
  const SocketFailure();
}

import 'dart:convert';

import 'package:assistant/services/supersync/payload_crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Just enough of a SuperSync server for tests: it stores uploaded operations, numbers them,
/// and insists on encrypted payloads like the real one.
class FakeSuperSync {
  FakeSuperSync(this.crypto, {this.token = 'tok'});

  final PayloadCrypto crypto;
  final String token;
  final List<Map<String, dynamic>> entries = [];
  final List<Map<String, dynamic>> uploads = [];
  int downloads = 0;
  bool gap = false;
  bool conflictOnce = false;

  Future<void> seedFullState(Map<String, dynamic> state) => addServerOp(
    'SYNC_IMPORT',
    '[Sync] import',
    {'appDataComplete': state},
    entityType: 'ALL',
  );

  /// Adds an operation as another device would have uploaded it.
  Future<void> addServerOp(
    String opType,
    String actionType,
    Map<String, dynamic> payload, {
    String entityType = 'TASK',
    String? entityId,
    Map<String, int>? clock,
  }) async {
    entries.add({
      'serverSeq': entries.length + 1,
      'receivedAt': 0,
      'op': {
        'id': 'seed-${entries.length}',
        'clientId': 'SPdesktop',
        'actionType': actionType,
        'opType': opType,
        'entityType': entityType,
        'entityId': ?entityId,
        'payload': await crypto.encrypt(jsonEncode(payload)),
        'isPayloadEncrypted': true,
        'vectorClock': clock ?? {'SPdesktop': entries.length + 1},
        'timestamp': 0,
        'schemaVersion': 4,
      },
    });
  }

  /// Decrypted payloads of what clients uploaded, with the envelope.
  Future<List<Map<String, dynamic>>> uploadedOps() async => [
    for (final op in uploads)
      {
        ...op,
        'payload': jsonDecode(await crypto.decrypt(op['payload'] as String)),
      },
  ];

  http.Client client() => MockClient((request) async {
    if (request.headers['Authorization'] != 'Bearer $token') {
      return http.Response('{"error":"Unauthorized"}', 401);
    }
    final path = request.url.path;
    if (path.endsWith('/api/sync/status')) {
      return http.Response(
        jsonEncode({'latestSeq': entries.length}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/api/sync/ops') && request.method == 'GET') {
      downloads++;
      final since = int.parse(request.url.queryParameters['sinceSeq']!);
      final limit = int.parse(request.url.queryParameters['limit'] ?? '500');
      final all = entries
          .where((e) => (e['serverSeq'] as int) > since)
          .toList();
      final page = all.take(limit).toList();
      return http.Response(
        jsonEncode({
          'ops': page,
          'hasMore': all.length > page.length,
          'latestSeq': entries.length,
          if (gap) 'gapDetected': true,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/api/sync/ops') && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final results = <Map<String, dynamic>>[];
      for (final op in (body['ops'] as List).cast<Map<String, dynamic>>()) {
        if (op['isPayloadEncrypted'] != true || op['payload'] is! String) {
          return http.Response(
            '{"error":"This server only accepts end-to-end encrypted payloads.","errorCode":"E2EE_REQUIRED"}',
            400,
          );
        }
        if (conflictOnce) {
          conflictOnce = false;
          results.add({
            'opId': op['id'],
            'accepted': false,
            'errorCode': 'CONFLICT_CONCURRENT',
            'error': 'Concurrent modification',
          });
          continue;
        }
        uploads.add(op);
        entries.add({
          'serverSeq': entries.length + 1,
          'receivedAt': 0,
          'op': op,
        });
        results.add({
          'opId': op['id'],
          'accepted': true,
          'serverSeq': entries.length,
        });
      }
      return http.Response(
        jsonEncode({'results': results, 'latestSeq': entries.length}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('not found', 404);
  });
}

Map<String, dynamic> fixtureTask(
  String id,
  String title, {
  String projectId = 'INBOX_PROJECT',
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'title': title,
  'subTaskIds': <String>[],
  'timeSpentOnDay': <String, num>{},
  'timeSpent': 0,
  'timeEstimate': 0,
  'isDone': false,
  'tagIds': <String>[],
  'created': 1000,
  'attachments': <Object>[],
  'projectId': projectId,
  ...extra,
};

Map<String, dynamic> fixtureState() => {
  'task': {
    'ids': ['t1', 't2'],
    'entities': {
      't1': fixtureTask('t1', 'Buy milk'),
      't2': fixtureTask(
        't2',
        'Write report',
        projectId: 'P_WORK',
        extra: {'notes': 'quarterly', 'dueDay': '2026-10-08'},
      ),
    },
  },
  'project': {
    'ids': ['INBOX_PROJECT', 'P_WORK'],
    'entities': {
      'INBOX_PROJECT': {'id': 'INBOX_PROJECT', 'title': 'Inbox'},
      'P_WORK': {'id': 'P_WORK', 'title': 'Work'},
    },
  },
  'tag': {'ids': <String>[], 'entities': <String, dynamic>{}},
};

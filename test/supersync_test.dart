import 'dart:convert';
import 'dart:io';

import 'package:assistant/services/supersync/payload_crypto.dart';
import 'package:assistant/services/supersync/supersync_client.dart';
import 'package:assistant/services/supersync/supersync_tasks.dart';
import 'package:assistant/services/supersync/sync_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_supersync.dart';

Map<String, dynamic> entry(
  int seq,
  String actionType,
  Map<String, dynamic> payload, {
  String opType = 'UPD',
  String entityType = 'TASK',
  String? entityId,
  Map<String, int>? clock,
}) => {
  'serverSeq': seq,
  'op': {
    'id': 'op$seq',
    'clientId': 'SPdesktop',
    'actionType': actionType,
    'opType': opType,
    'entityType': entityType,
    'entityId': ?entityId,
    'payload': {'actionPayload': payload, 'entityChanges': <Object>[]},
    'vectorClock': clock ?? {'SPdesktop': seq},
  },
};

void main() {
  group('SyncState', () {
    SyncState fresh() {
      final s = SyncState();
      s.applyServerOp({
        'serverSeq': 1,
        'op': {
          'opType': 'SYNC_IMPORT',
          'actionType': '[Sync] import',
          'entityType': 'ALL',
          'payload': {'appDataComplete': fixtureState()},
          'vectorClock': {'SPdesktop': 1},
        },
      });
      return s;
    }

    test('starts from the full state', () {
      final s = fresh();
      expect(s.tasks.keys, ['t1', 't2']);
      expect(s.projects['P_WORK']!['title'], 'Work');
      expect(s.lastSeq, 1);
      expect(s.clock, {'SPdesktop': 1});
    });

    test('add, update, schedule and delete follow the app actions', () {
      final s = fresh();
      s.applyServerOp(
        entry(2, '[Task Shared] addTask', {
          'task': fixtureTask('t3', 'Call dentist'),
        }, opType: 'CRT'),
      );
      s.applyServerOp(
        entry(3, '[Task Shared] updateTask', {
          'task': {
            'id': 't1',
            'changes': {'title': 'Buy oat milk', 'isDone': true},
          },
        }),
      );
      s.applyServerOp(
        entry(4, '[Task Shared] planTasksForToday', {
          'taskIds': ['t1'],
          'today': '2026-10-09',
        }),
      );
      s.applyServerOp(
        entry(5, '[Task Shared] scheduleTaskWithTime', {
          'task': {'id': 't3'},
          'dueWithTime': 5000,
        }),
      );
      s.applyServerOp(
        entry(6, '[Task Shared] deleteTasks', {
          'taskIds': ['t2'],
        }, opType: 'DEL'),
      );

      expect(s.tasks.keys.toSet(), {'t1', 't3'});
      expect(s.tasks['t1']!['title'], 'Buy oat milk');
      expect(s.tasks['t1']!['isDone'], true);
      expect(s.tasks['t1']!['dueDay'], '2026-10-09');
      expect(s.tasks['t3']!['dueWithTime'], 5000);
      expect(s.tasks['t3']!['dueDay'], isNull);
      expect(s.lastSeq, 6);
    });

    test('archived tasks and their subtasks leave the list', () {
      final s = fresh();
      s.tasks['t1']!['subTaskIds'] = ['s1'];
      s.tasks['s1'] = fixtureTask('s1', 'Sub', extra: {'parentId': 't1'});
      s.applyServerOp(
        entry(2, '[Task Shared] moveToArchive', {
          'tasks': [
            {'id': 't1'},
          ],
        }),
      );
      expect(s.tasks.keys, ['t2']);
    });

    test('LWW updates replace, patch and clear', () {
      final s = fresh();
      s.applyServerOp(
        entry(2, '[TASK] LWW Update', {
          ...fixtureTask('t9', 'Made by LWW'),
          'id': 't9',
        }, entityId: 't9')..['op']['payload']['lwwUpdateMode'] = 'replace',
      );
      expect(s.tasks['t9']!['title'], 'Made by LWW');

      final patch = entry(3, '[TASK] LWW Update', {
        'id': 't9',
        'title': 'Renamed',
        'notes': null,
      }, entityId: 't9');
      patch['op']['payload']['lwwUpdateMode'] = 'patch';
      patch['op']['payload']['clearedFields'] = ['notes'];
      s.tasks['t9']!['notes'] = 'old';
      s.applyServerOp(patch);
      expect(s.tasks['t9']!['title'], 'Renamed');
      expect(s.tasks['t9']!['notes'], isNull);

      // A patch for a task that is gone does not bring it back
      final late = entry(4, '[TASK] LWW Update', {
        'id': 'gone',
        'title': 'x',
      }, entityId: 'gone');
      late['op']['payload']['lwwUpdateMode'] = 'patch';
      s.applyServerOp(late);
      expect(s.tasks.containsKey('gone'), isFalse);
    });

    test('unknown actions are counted, harmless ones are not', () {
      final s = fresh();
      s.applyServerOp(entry(2, '[Task Shared] somethingNew', {}));
      s.applyServerOp(entry(3, '[TimeTracking] Sync time spent', {}));
      expect(s.ignoredActions, {'[Task Shared] somethingNew': 1});
    });

    test('a later full state replaces everything', () {
      final s = fresh();
      s.applyServerOp(
        entry(2, '[Task Shared] addTask', {
          'task': fixtureTask('t3', 'x'),
        }, opType: 'CRT'),
      );
      s.applyServerOp({
        'serverSeq': 3,
        'op': {
          'opType': 'SYNC_IMPORT',
          'actionType': 'x',
          'entityType': 'ALL',
          'payload': {
            'task': {
              'entities': {'only': fixtureTask('only', 'Only one')},
            },
          },
          'vectorClock': {},
        },
      });
      expect(s.tasks.keys, ['only']);
    });

    test('encrypted data without a key is reported', () {
      expect(
        () => SyncState().applyServerOp({
          'serverSeq': 1,
          'op': {'payload': 'abc', 'isPayloadEncrypted': true},
        }),
        throwsA(isA<EncryptedSyncException>()),
      );
    });

    test('survives a trip through the cache file format', () {
      final s = fresh();
      final copy = SyncState.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(copy.tasks.keys, s.tasks.keys);
      expect(copy.lastSeq, 1);
      expect(copy.clock, s.clock);
    });
  });

  group('SuperSyncTasks', () {
    late FakeSuperSync server;
    late Directory dir;
    late PayloadCrypto crypto;

    SuperSyncTasks service({PayloadCrypto? withCrypto, String token = 'tok'}) =>
        SuperSyncTasks(
          client: SuperSyncClient(
            url: 'https://sync.example/',
            token: token,
            clientId: 'Grace_test',
            clientFactory: server.client,
          ),
          cacheFile: File('${dir.path}/cache.json'),
          crypto: withCrypto ?? crypto,
          now: () => DateTime(2026, 10, 8, 12),
        );

    setUp(() async {
      // Light Argon2 settings keep the tests fast, the format is the same
      crypto = PayloadCrypto('pw', memory: 8, iterations: 1);
      server = FakeSuperSync(crypto);
      await server.seedFullState(fixtureState());
      dir = Directory.systemTemp.createTempSync('supersync_test');
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    test('lists open tasks with project names and due dates', () async {
      final tasks = await service().list();
      expect(tasks.map((t) => t.title), ['Buy milk', 'Write report']);
      final report = tasks.last;
      expect(report.projectTitle, 'Work');
      expect(report.due, DateTime(2026, 10, 8));
      expect(report.dueHasTime, isFalse);
      expect(await service().list(project: 'work'), hasLength(1));
      expect(await service().list(search: 'MILK'), hasLength(1));
      expect(
        () => service().list(project: 'nope'),
        throwsA(isA<SuperSyncException>()),
      );
    });

    test(
      'adding uploads one encrypted LWW operation that dominates the clock',
      () async {
        final task = await service().add(
          'Pay rent',
          project: 'Work',
          dueWithTime: DateTime(2026, 10, 10, 9, 30),
          notes: 'monthly',
        );
        expect(task.projectTitle, 'Work');

        final op = (await server.uploadedOps()).single;
        expect(op['isPayloadEncrypted'], true);
        expect(op['actionType'], '[TASK] LWW Update');
        expect(op['opType'], 'UPD');
        expect(op['entityType'], 'TASK');
        expect(op['entityId'], task.id);
        expect(op['schemaVersion'], 4);
        expect(op['clientId'], 'Grace_test');
        // Seen clock of the other device plus the own counter
        expect(op['vectorClock'], {'SPdesktop': 1, 'Grace_test': 1});

        final payload = op['payload'] as Map<String, dynamic>;
        expect(payload['lwwUpdateMode'], 'replace');
        expect(payload['entityChanges'], isEmpty);
        final fields = payload['actionPayload'] as Map<String, dynamic>;
        expect(fields['id'], task.id);
        expect(fields['title'], 'Pay rent');
        expect(fields['projectId'], 'P_WORK');
        expect(
          fields['dueWithTime'],
          DateTime(2026, 10, 10, 9, 30).millisecondsSinceEpoch,
        );
        expect(fields.containsKey('dueDay'), isFalse);
        expect(fields['subTaskIds'], isEmpty);
        expect(fields['isDone'], false);
        expect(fields['notes'], 'monthly');
        expect(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(task.id),
          isTrue,
        );

        // Another device sees it
        final other = await SuperSyncTasks(
          client: SuperSyncClient(
            url: 'https://sync.example',
            token: 'tok',
            clientId: 'Grace_other',
            clientFactory: server.client,
          ),
          cacheFile: File('${dir.path}/other.json'),
          crypto: crypto,
        ).list();
        expect(other.map((t) => t.title), contains('Pay rent'));
      },
    );

    test('without a project the task goes to the inbox', () async {
      final task = await service().add('Inbox thing', dueDay: '2026-11-01');
      expect(task.projectId, 'INBOX_PROJECT');
      final fields =
          (await server.uploadedOps()).single['payload']['actionPayload']
              as Map;
      expect(fields['dueDay'], '2026-11-01');
      expect(fields.containsKey('dueWithTime'), isFalse);
    });

    test('completing sends a patch with only the changed fields', () async {
      final tasks = service();
      final milk = await tasks.find(title: 'milk');
      await tasks.update(milk, isDone: true);

      final op = (await server.uploadedOps()).single;
      final payload = op['payload'] as Map<String, dynamic>;
      expect(payload['lwwUpdateMode'], 'patch');
      final fields = payload['actionPayload'] as Map<String, dynamic>;
      expect(fields.keys.toSet(), {'id', 'isDone', 'doneOn'});
      expect(
        fields['doneOn'],
        DateTime(2026, 10, 8, 12).millisecondsSinceEpoch,
      );
      expect(op['vectorClock'], {'SPdesktop': 1, 'Grace_test': 1});

      expect(await tasks.list(), hasLength(1));
      expect(await tasks.list(includeDone: true), hasLength(2));
    });

    test('clearing the due date lists the cleared fields', () async {
      final tasks = service();
      await tasks.update(await tasks.find(title: 'report'), clearDue: true);
      final payload = (await server.uploadedOps()).single['payload'] as Map;
      expect(payload['clearedFields'], containsAll(['dueDay', 'dueWithTime']));
      expect((await tasks.find(title: 'report')).due, isNull);
    });

    test('each write raises the own counter', () async {
      final tasks = service();
      await tasks.add('One');
      await tasks.add('Two');
      final ops = await server.uploadedOps();
      expect(ops[0]['vectorClock']['Grace_test'], 1);
      expect(ops[1]['vectorClock']['Grace_test'], 2);
    });

    test('deleting sends a delete operation for the task', () async {
      final tasks = service();
      await tasks.delete(await tasks.find(title: 'milk'));
      final op = (await server.uploadedOps()).single;
      expect(op['opType'], 'DEL');
      expect(op['actionType'], '[Task Shared] deleteTasks');
      expect(op['entityIds'], ['t1']);
      expect((op['payload']['actionPayload'] as Map)['taskIds'], ['t1']);
      expect(await tasks.list(), hasLength(1));
    });

    test('a task is found by id, exact title or part of it', () async {
      final tasks = service();
      expect((await tasks.find(id: 't2')).title, 'Write report');
      expect((await tasks.find(title: 'buy milk')).id, 't1');
      expect((await tasks.find(title: 'rep')).id, 't2');
      expect(
        () => tasks.find(title: 'nothing'),
        throwsA(isA<SuperSyncException>()),
      );
      expect(() => tasks.find(title: 'i'), throwsA(isA<SuperSyncException>()));
    });

    test('only operations after the cached position are fetched', () async {
      final tasks = service();
      await tasks.list();
      final first = server.downloads;
      await server.addServerOp('CRT', '[Task Shared] addTask', {
        'task': fixtureTask('t7', 'Fresh'),
      }, entityId: 't7');
      final again = service();
      expect((await again.list()).map((t) => t.title), contains('Fresh'));
      expect(server.downloads, greaterThan(first));
      // The cache file keeps the position
      final cache =
          jsonDecode(File('${dir.path}/cache.json').readAsStringSync()) as Map;
      expect(cache['lastSeq'], 2);
    });

    test('a conflict is retried once from the newer state', () async {
      server.conflictOnce = true;
      final tasks = service();
      await tasks.add('Retried');
      expect(await server.uploadedOps(), hasLength(1));
    });

    test('a gap in the server log restarts from its snapshot', () async {
      final tasks = service();
      await tasks.list();
      server.gap = true;
      // The server keeps answering with a gap: one restart, then the data is used
      expect(await tasks.list(), isNotEmpty);
    });

    test('errors are explained', () async {
      expect(
        () => service(token: 'wrong').list(),
        throwsA(
          predicate((e) => e.toString().contains('refused the access token')),
        ),
      );
      final noPassword = SuperSyncTasks(
        client: SuperSyncClient(
          url: 'sync.example',
          token: 'tok',
          clientId: 'Grace_test',
          clientFactory: server.client,
        ),
        cacheFile: File('${dir.path}/nopw.json'),
      );
      expect(
        () => noPassword.list(),
        throwsA(predicate((e) => e.toString().contains('encryption password'))),
      );
      expect(
        () => SuperSyncClient(url: '', token: 't', clientId: 'c'),
        throwsA(isA<SuperSyncException>()),
      );
    });

    test('a wrong password is reported', () async {
      final wrong = service(
        withCrypto: PayloadCrypto('other', memory: 8, iterations: 1),
      );
      expect(() => wrong.list(), throwsA(isA<DecryptException>()));
    });
  });

  group('self-signed server certificate', () {
    test('is trusted when the PEM is given and refused otherwise', () async {
      final dir = Directory.systemTemp.createTempSync('selfsigned');
      addTearDown(() => dir.deleteSync(recursive: true));
      final made = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        '${dir.path}/key.pem',
        '-out',
        '${dir.path}/cert.pem',
        '-days',
        '2',
        '-subj',
        '/CN=localhost',
        '-addext',
        'subjectAltName=DNS:localhost,IP:127.0.0.1',
      ]);
      if (made.exitCode != 0) {
        markTestSkipped('openssl is not available');
        return;
      }

      final context = SecurityContext()
        ..useCertificateChain('${dir.path}/cert.pem')
        ..usePrivateKey('${dir.path}/key.pem');
      final server = await HttpServer.bindSecure('127.0.0.1', 0, context);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"latestSeq":7}')
          ..close();
      });
      final url = 'https://127.0.0.1:${server.port}';
      final pem = File('${dir.path}/cert.pem').readAsStringSync();

      final trusting = SuperSyncClient(
        url: url,
        token: 't',
        clientId: 'Grace_x',
        certificate: pem,
      );
      expect((await trusting.status())['latestSeq'], 7);

      final strict = SuperSyncClient(url: url, token: 't', clientId: 'Grace_x');
      await expectLater(
        strict.status(),
        throwsA(predicate((e) => e.toString().contains('Could not reach'))),
      );
    });
  });
}

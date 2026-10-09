import 'dart:io';

import 'package:assistant/models/models.dart';
import 'package:assistant/services/storage.dart';
import 'package:assistant/services/supersync/payload_crypto.dart';
import 'package:assistant/services/supersync/supersync_client.dart';
import 'package:assistant/services/supersync/supersync_tasks.dart';
import 'package:assistant/services/tools.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_supersync.dart';

const _channel = MethodChannel('com.grace.assistant/native');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Storage storage;
  late ToolContext ctx;
  late List<MethodCall> calls;
  late List<Uri> launched;
  Object? Function(MethodCall call) native = (_) => null;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = Storage(await SharedPreferences.getInstance());
    calls = [];
    launched = [];
    native = (_) => null;
    ctx = ToolContext(
      storage: storage,
      chatSettings: ChatSettings(),
      launch: (u) async {
        launched.add(u);
        return true;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return native(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<ToolResult> run(String name, Map<String, dynamic> args) =>
      toolByName(name)!.run(args, ctx);

  group('send_text', () {
    test('sends the text itself to a number', () async {
      final r = await run('send_text', {
        'contact': '+1 (555) 010-2030',
        'message': 'On my way',
      });
      expect(calls.single.method, 'sendSms');
      expect(calls.single.arguments, {
        'number': '+15550102030',
        'message': 'On my way',
      });
      expect(r.text, contains('sent'));
      expect(launched, isEmpty);
    });

    test('looks the contact up first', () async {
      native = (c) => c.method == 'findContact'
          ? {'name': 'Alex Doe', 'number': '555 0100'}
          : null;
      final r = await run('send_text', {'contact': 'alex', 'message': 'Hi'});
      expect(calls.map((c) => c.method), ['findContact', 'sendSms']);
      expect(r.text, contains('Alex Doe'));
    });

    test('falls back to the messaging app when sending is refused', () async {
      native = (c) {
        if (c.method == 'sendSms') {
          throw PlatformException(code: 'permission_denied');
        }
        return null;
      };
      final r = await run('send_text', {'contact': '5550100', 'message': 'Hi'});
      expect(launched.single.scheme, 'sms');
      expect(launched.single.queryParameters['body'], 'Hi');
      expect(r.text, contains('could not be sent directly'));
    });
  });

  group('calendar', () {
    test('lists events', () async {
      final start = DateTime(2026, 10, 8, 15).millisecondsSinceEpoch;
      native = (c) => [
        {
          'id': 7,
          'title': 'Dentist',
          'start': start,
          'end': start + 3600000,
          'allDay': false,
          'location': 'Main St',
          'description': '',
          'calendar': 'Personal',
        },
      ];
      final r = await run('list_calendar_events', {
        'from': '2026-10-08T00:00',
        'to': '2026-10-09T00:00',
      });
      expect(r.text, contains('[7] Dentist'));
      expect(r.text, contains('2026-10-08T15:00'));
      expect(r.text, contains('Main St'));
    });

    test('adds a timed event with a default length of one hour', () async {
      native = (c) => 12;
      final r = await run('add_calendar_event', {
        'title': 'Lunch',
        'start': '2026-10-08T12:00',
        'reminder_minutes': 15,
      });
      final a = calls.single.arguments as Map;
      expect(a['end'] - a['start'], 3600000);
      expect(a['allDay'], false);
      expect(a['reminderMinutes'], 15);
      expect(r.text, contains('12'));
    });

    test('an all day event ends at the midnight after its last day', () async {
      native = (c) => 3;
      await run('add_calendar_event', {
        'title': 'Trip',
        'start': '2026-10-08',
        'end': '2026-10-09',
        'all_day': true,
      });
      final a = calls.single.arguments as Map;
      expect(a['start'], DateTime.utc(2026, 10, 8).millisecondsSinceEpoch);
      expect(a['end'], DateTime.utc(2026, 10, 10).millisecondsSinceEpoch);
    });

    test('a repeating event repeats forever without an end date', () async {
      native = (c) => 5;
      final r = await run('add_calendar_event', {
        'title': 'Standup',
        'start': '2026-10-12T09:00',
        'repeat': 'weekly',
        'repeat_days': ['monday', 'wednesday'],
      });
      expect(
        (calls.single.arguments as Map)['rrule'],
        'FREQ=WEEKLY;BYDAY=MO,WE',
      );
      expect(r.text, contains('forever'));
    });

    test('a repeating event can stop on a date', () async {
      native = (c) => 5;
      await run('add_calendar_event', {
        'title': 'Pay rent',
        'start': '2026-10-01',
        'all_day': true,
        'repeat': 'monthly',
        'repeat_interval': 2,
        'repeat_until': '2027-04-01',
      });
      expect(
        (calls.single.arguments as Map)['rrule'],
        'FREQ=MONTHLY;INTERVAL=2;UNTIL=20270401',
      );
    });

    test('rejects a bad repeat', () async {
      final r = await run('add_calendar_event', {
        'title': 'x',
        'start': '2026-10-12T09:00',
        'repeat': 'daily',
        'repeat_until': '2026-10-01',
      });
      expect(r.text, contains('before the start'));
      expect(calls, isEmpty);
    });

    test('rejects an end before the start and a bad date', () async {
      final r = await run('add_calendar_event', {
        'title': 'x',
        'start': '2026-10-08T12:00',
        'end': '2026-10-08T11:00',
      });
      expect(r.text, contains('after the start'));
      expect(calls, isEmpty);
      expect(
        () => run('add_calendar_event', {'title': 'x', 'start': 'tomorrow'}),
        throwsException,
      );
    });

    test('a refused permission becomes a readable error', () async {
      native = (c) => throw PlatformException(code: 'permission_denied');
      expect(
        () => run('list_calendar_events', {}),
        throwsA(predicate((e) => e.toString().contains('Calendar permission'))),
      );
    });

    test('updates and deletes by id', () async {
      native = (c) => true;
      expect(
        (await run('update_calendar_event', {'id': 4, 'title': 'New'})).text,
        contains('updated'),
      );
      expect((calls.last.arguments as Map)['title'], 'New');
      expect(
        (await run('delete_calendar_event', {'id': 4})).text,
        contains('deleted'),
      );
    });
  });

  group('alarms', () {
    test('sets a repeating alarm', () async {
      native = (c) => true;
      final r = await run('set_alarm', {
        'time': '7:30',
        'label': 'Gym',
        'days': ['Monday', 'friday'],
      });
      expect(calls.single.arguments, {
        'hour': 7,
        'minute': 30,
        'label': 'Gym',
        'days': [2, 6],
      });
      expect(r.text, contains('07:30'));
    });

    test('rejects times that are not 24 hour', () async {
      expect(
        (await run('set_alarm', {'time': '25:00'})).text,
        contains('24 hour'),
      );
      expect(
        (await run('set_alarm', {'time': '7am'})).text,
        contains('24 hour'),
      );
      expect(calls, isEmpty);
    });

    test('timers and deleting', () async {
      native = (c) => true;
      expect((await run('set_timer', {'seconds': 300})).text, contains('300'));
      expect(
        (await run('set_timer', {'seconds': 0})).text,
        contains('between'),
      );
      await run('delete_alarm', {'time': '06:15'});
      expect(calls.last.method, 'dismissAlarm');
      expect(calls.last.arguments, {'hour': 6, 'minute': 15});
    });

    test('reports a missing clock app', () async {
      native = (c) => false;
      expect(
        (await run('set_timer', {'seconds': 60})).text,
        contains('No clock app'),
      );
    });
  });

  group('task tools (SuperSync)', () {
    late FakeSuperSync server;
    late Directory dir;

    setUp(() async {
      final crypto = PayloadCrypto('pw', memory: 8, iterations: 1);
      server = FakeSuperSync(crypto);
      await server.seedFullState(fixtureState());
      dir = Directory.systemTemp.createTempSync('task_tools');
      addTearDown(() => dir.deleteSync(recursive: true));
      final service = SuperSyncTasks(
        client: SuperSyncClient(
          url: 'https://sync.example',
          token: 'tok',
          clientId: 'Grace_tools',
          clientFactory: server.client,
        ),
        cacheFile: File('${dir.path}/c.json'),
        crypto: crypto,
      );
      ctx = ToolContext(
        storage: storage,
        chatSettings: ChatSettings(),
        launch: (u) async => true,
        tasks: () async => service,
      );
    });

    test('list, add, complete and delete', () async {
      final listed = (await run('list_tasks', {})).text;
      expect(listed, contains('Buy milk'));
      expect(listed, contains('(project: Work)'));
      expect(listed, contains('(due 2026-10-08)'));

      final added = await run('add_task', {
        'title': 'Pay rent',
        'due': '2026-10-10T09:30',
        'project': 'work',
        'notes': 'monthly',
      });
      expect(added.text, contains('Pay rent'));
      expect(added.text, contains('(due 2026-10-10T09:30)'));

      await run('update_task', {'title': 'Buy milk', 'done': true});
      expect((await run('list_tasks', {})).text, isNot(contains('Buy milk')));
      expect(
        (await run('list_tasks', {'include_done': true})).text,
        contains('(done) Buy milk'),
      );

      await run('delete_task', {'title': 'Pay rent'});
      expect((await run('list_tasks', {})).text, isNot(contains('Pay rent')));
    });

    test('the due date can be changed and removed', () async {
      await run('update_task', {
        'title': 'Write report',
        'due': '2026-11-01T09:00',
      });
      expect(
        (await run('list_tasks', {'search': 'report'})).text,
        contains('(due 2026-11-01T09:00)'),
      );
      await run('update_task', {'title': 'Write report', 'due': 'none'});
      expect(
        (await run('list_tasks', {'search': 'report'})).text,
        isNot(contains('due')),
      );
    });

    test(
      'completing with a wrong name fails, and completing twice says so',
      () async {
        await expectLater(
          run('update_task', {'title': 'milk', 'done': true}),
          throwsA(predicate((e) => e.toString().contains('[t1] Buy milk'))),
        );
        expect((await run('list_tasks', {})).text, contains('Buy milk'));

        await run('update_task', {'title': 'Buy milk', 'done': true});
        final again = await run('update_task', {'id': 't1', 'done': true});
        expect(again.text, contains('already done'));
      },
    );

    test('bad input is explained', () async {
      expect(
        () => run('add_task', {'title': 'x', 'due': 'tomorrow'}),
        throwsA(predicate((e) => e.toString().contains('2026-10-08'))),
      );
      expect(
        () => run('update_task', {'title': 'nothing here'}),
        throwsA(predicate((e) => e.toString().contains('No task is titled'))),
      );
    });

    test('without settings the tools say what is missing', () async {
      final bare = ToolContext(storage: storage, chatSettings: ChatSettings());
      expect(
        () => toolByName('list_tasks')!.run({}, bare),
        throwsA(predicate((e) => e.toString().contains('not set up'))),
      );
    });
  });
}

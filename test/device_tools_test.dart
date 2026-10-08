import 'package:assistant/models/models.dart';
import 'package:assistant/services/storage.dart';
import 'package:assistant/services/tools.dart';
import 'package:assistant/ui/todos_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('to-do list', () {
    test('add, list, complete and delete', () async {
      await run('add_todo', {'title': 'Buy milk', 'due': '2026-10-09'});
      await run('add_todo', {'title': 'Buy bread'});
      expect(storage.todos, hasLength(2));

      final listed = (await run('list_todos', {})).text;
      expect(listed, contains('Buy milk'));
      expect(listed, contains('due 2026-10-09T00:00'));

      await run('update_todo', {'title': 'milk', 'done': true});
      expect((await run('list_todos', {})).text, isNot(contains('Buy milk')));
      expect(
        (await run('list_todos', {'include_done': true})).text,
        contains('(done) Buy milk'),
      );

      await run('delete_todo', {'title': 'Buy bread'});
      expect(storage.todos.single.title, 'Buy milk');
    });

    test('an ambiguous title is refused with the candidates', () async {
      await run('add_todo', {'title': 'Call mom'});
      await run('add_todo', {'title': 'Call dentist'});
      expect(
        () => run('delete_todo', {'title': 'call'}),
        throwsA(predicate((e) => e.toString().contains('Several tasks'))),
      );
      expect(storage.todos, hasLength(2));
    });

    test('the due date can be changed and removed', () async {
      await run('add_todo', {'title': 'Report'});
      await run('update_todo', {'title': 'Report', 'due': '2026-11-01T09:00'});
      expect(storage.todos.single.due, DateTime(2026, 11, 1, 9));
      await run('update_todo', {'title': 'Report', 'due': 'none'});
      expect(storage.todos.single.due, isNull);
    });

    testWidgets('the screen shows, checks and adds tasks', (tester) async {
      await tester.runAsync(() async {
        await storage.saveTodo(TodoItem(id: 'a', title: 'Water plants'));
      });
      await tester.pumpWidget(
        ChangeNotifierProvider<Storage>.value(
          value: storage,
          child: const MaterialApp(home: TodosScreen()),
        ),
      );
      expect(find.text('Water plants'), findsOneWidget);

      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(storage.todos.single.done, isTrue);

      await tester.tap(find.byTooltip('Add task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Pay rent');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(storage.todos.map((t) => t.title), contains('Pay rent'));
    });
  });
}

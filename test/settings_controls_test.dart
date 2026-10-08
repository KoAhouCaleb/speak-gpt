import 'package:assistant/models/models.dart';
import 'package:assistant/services/storage.dart';
import 'package:assistant/ui/chat_settings_screen.dart';
import 'package:assistant/ui/tools_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// These screens once lost controls without any error, so the controls are checked by their
// labels and by what they save.
void main() {
  late Storage storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storage = Storage(await SharedPreferences.getInstance());
  });

  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<Storage>.value(
        value: storage,
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('chat settings has every control, and they save', (tester) async {
    await storage.saveLogitBiasSet(
      LogitBiasSet(id: 'b1', name: 'No cats', biases: {'1': -100}),
    );
    final chat = await storage.addChat('c');
    // A tall screen so that the whole list is built and nothing needs scrolling
    tester.view.physicalSize = const Size(900, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester, ChatSettingsScreen(chat: chat));

    for (final label in [
      'API endpoint',
      'Model',
      'Assistant name',
      'System message',
      'Message prefix',
      'End separator',
      'Tools',
      'Logit bias set',
      'Silent mode',
      'Always speak',
      '/imagine command',
      'Temperature: 0.70',
      'Top P: 1.00',
      'Max tokens',
      '0 = server default',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }

    // Turn tools on
    await tester.scrollUntilVisible(
      find.text('Tools'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(SwitchListTile, 'Tools'));
    await tester.pumpAndSettle();

    // Pick the logit bias set
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No cats').last);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    final saved = storage.chatSettings(chat.id);
    expect(saved.functionCalling, isTrue);
    expect(saved.logitBiasSetId, 'b1');
  });

  testWidgets('the tools screen switches tools on for new chats', (
    tester,
  ) async {
    expect(storage.defaultChatSettings.functionCalling, isFalse);
    await open(tester, const ToolsScreen());

    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Use tools in new chats'),
    );
    await tester.pumpAndSettle();

    expect(storage.defaultChatSettings.functionCalling, isTrue);
    final created = await storage.addChat('new');
    expect(storage.chatSettings(created.id).functionCalling, isTrue);
  });

  testWidgets('the tools screen saves the task server settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester, const ToolsScreen());

    for (final label in [
      'Task server (Super Productivity)',
      'Server URL',
      'Access token',
      'Encryption password',
      'Server certificate (optional)',
      'Save and test',
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(storage.supersyncConfigured, isFalse);

    Finder field(String label) => find.widgetWithText(TextField, label);
    await tester.enterText(field('Server URL'), 'https://sync.home');
    await tester.enterText(field('Access token'), 'jwt-token');
    await tester.enterText(field('Encryption password'), 'secret');
    await tester.enterText(
      field('Server certificate (optional)'),
      '-----BEGIN CERTIFICATE-----',
    );
    // The connection test runs against a host that does not exist and reports the failure
    await tester.runAsync(() async {
      await tester.tap(find.text('Save and test'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();

    expect(storage.supersyncUrl, 'https://sync.home');
    expect(storage.supersyncToken, 'jwt-token');
    expect(storage.supersyncPassword, 'secret');
    expect(storage.supersyncCertificate, '-----BEGIN CERTIFICATE-----');
    expect(storage.supersyncConfigured, isTrue);
    expect(storage.supersyncClientId, startsWith('Grace_'));
    expect(storage.supersyncClientId, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
  });
}

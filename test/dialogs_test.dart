import 'package:assistant/services/storage.dart';
import 'package:assistant/ui/chat_settings_screen.dart';
import 'package:assistant/ui/endpoints_screen.dart';
import 'package:assistant/ui/logit_bias_screen.dart';
import 'package:assistant/ui/prompts_screen.dart';
import 'package:assistant/models/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Storage> pump(WidgetTester tester, Widget home) async {
  final storage = Storage(await SharedPreferences.getInstance());
  await tester.pumpWidget(
    ChangeNotifierProvider<Storage>.value(
      value: storage,
      child: MaterialApp(home: home),
    ),
  );
  await tester.pumpAndSettle();
  return storage;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('saving an endpoint closes the dialog without errors', (
    tester,
  ) async {
    final storage = await pump(tester, const EndpointsScreen());

    await tester.tap(find.byTooltip('Add endpoint'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Label'), 'Local');
    await tester.enterText(
      find.widgetWithText(TextField, 'Base URL'),
      'https://llm.lan/v1/',
    );
    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-1');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Local'), findsOneWidget);
    expect(
      storage.endpoints.any((e) => e.label == 'Local' && e.apiKey == 'sk-1'),
      isTrue,
    );

    // Editing the same endpoint again
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      storage.endpoints.firstWhere((e) => e.label == 'Local').apiKey,
      'sk-2',
    );
  });

  testWidgets('saving a prompt closes the dialog without errors', (
    tester,
  ) async {
    final storage = await pump(tester, const PromptsScreen());

    await tester.tap(find.byTooltip('Add prompt'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Summary');
    await tester.enterText(
      find.widgetWithText(TextField, 'Prompt'),
      'Summarize this.',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(storage.prompts.single.title, 'Summary');
  });

  testWidgets('adding a logit bias token closes the dialog without errors', (
    tester,
  ) async {
    final storage = await pump(tester, const LogitBiasListScreen());

    await tester.tap(find.byTooltip('Add set'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'No cats');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Add token'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Token id'), '1234');
    await tester.enterText(
      find.widgetWithText(TextField, 'Bias (-100 to 100)'),
      '-100',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(storage.logitBiasSets.single.biases, {'1234': -100});
  });

  testWidgets('chat settings can be opened and left without errors', (
    tester,
  ) async {
    final storage = await pump(tester, const SizedBox());
    final chat = await storage.addChat('c');
    await tester.pumpWidget(
      ChangeNotifierProvider<Storage>.value(
        value: storage,
        child: MaterialApp(
          home: ChatSettingsScreen(chat: ChatInfo(name: 'c', timestamp: 0)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'my-model');
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
    expect(storage.chatSettings(chat.id).model, 'my-model');
  });
}

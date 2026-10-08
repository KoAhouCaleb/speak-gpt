import 'package:assistant/services/storage.dart';
import 'package:assistant/ui/assist_overlay.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'overlay explains the missing screen and creates no chat until a message is sent',
    (tester) async {
      final storage = Storage(await SharedPreferences.getInstance());

      await tester.pumpWidget(
        ChangeNotifierProvider<Storage>.value(
          value: storage,
          child: const AssistOverlayApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ask about this screen'), findsOneWidget);
      expect(find.textContaining('did not receive the screen'), findsOneWidget);
      expect(find.byTooltip('Open in Grace'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(storage.chats, isEmpty);
    },
  );

  test('overlay setting defaults on and the native key matches', () async {
    final storage = Storage(await SharedPreferences.getInstance());
    expect(storage.assistOverlay, isTrue);
    await storage.setAssistOverlay(false);
    // GraceSession.kt reads this exact key from FlutterSharedPreferences
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('assist_overlay'), isFalse);
  });

  test('reload picks up chats written by another engine', () async {
    final storage = Storage(await SharedPreferences.getInstance());
    expect(storage.chats, isEmpty);

    SharedPreferences.setMockInitialValues({
      'chat_list': '[{"name":"From overlay","timestamp":1,"pinned":false}]',
    });
    // A second engine writes to the same file; this engine's cache is stale until reload
    final other = await SharedPreferences.getInstance();
    await other.reload();
    await storage.reload();
    expect(storage.chats.map((c) => c.name), ['From overlay']);
  });
}

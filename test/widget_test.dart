import 'package:assistant/main.dart';
import 'package:assistant/services/storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('home screen lists chats and navigates to settings', (
    tester,
  ) async {
    final storage = Storage(await SharedPreferences.getInstance());
    await storage.addChat('Hello chat');

    await tester.pumpWidget(
      ChangeNotifierProvider<Storage>.value(
        value: storage,
        child: const GraceApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Grace'), findsWidgets);
    expect(find.text('Hello chat'), findsOneWidget);

    await tester.tap(find.text('Settings').last);
    await tester.pump();
    expect(find.text('API endpoints'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Set Grace as digital assistant'),
      200,
    );
    expect(find.text('Set Grace as digital assistant'), findsOneWidget);
  });
}

import 'package:assistant/main.dart';
import 'package:assistant/services/storage.dart';
import 'package:assistant/ui/assist_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Both Flutter engines of the app (main window and compact assistant) must use the linear
// scaler so that neither asks the shared Android configuration queue for font sizes.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<double> measureScale(WidgetTester tester, Widget app) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    final storage = Storage(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ChangeNotifierProvider<Storage>.value(value: storage, child: app),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    final scaler = MediaQuery.textScalerOf(context);
    // A linear scaler is a plain multiplication and never needs the platform
    expect(scaler, TextScaler.linear(1.5));
    return scaler.scale(10);
  }

  testWidgets('main window scales text linearly', (tester) async {
    expect(await measureScale(tester, const GraceApp()), 15);
  });

  testWidgets('compact assistant scales text linearly', (tester) async {
    expect(await measureScale(tester, const AssistOverlayApp()), 15);
  });
}

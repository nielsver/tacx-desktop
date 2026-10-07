import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/api/trainer.dart' as api;
import 'package:tacx_desktop/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('Dashboard + headless demo smoke', (tester) async {
    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Tacx Desktop'), findsOneWidget);
    final msg = await api.runHeadlessDemoSmoke();
    expect(msg.contains('OK'), isTrue);
  });
}

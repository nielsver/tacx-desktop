import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/main.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('Ride dashboard loads in demo mode', (tester) async {
    await tester.pumpWidget(const TacxDesktopApp());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Tacx Desktop'), findsOneWidget);
    expect(find.text('DEMO'), findsOneWidget);
    expect(find.text('ERG mode'), findsOneWidget);
    expect(find.text('Resistance'), findsOneWidget);
    expect(find.text('Intervals'), findsOneWidget);
  });
}

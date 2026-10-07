import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/app_shell.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/ui/window_chrome.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WindowChrome.init();
  await RustLib.init();
  runApp(const TacxDesktopApp());
}

class TacxDesktopApp extends StatelessWidget {
  const TacxDesktopApp({super.key, this.skipOnboarding = false});

  /// Widget tests that need the ride dashboard skip Welcome/Connect.
  final bool skipOnboarding;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tacx Desktop',
      debugShowCheckedModeBanner: false,
      theme: buildRideTheme(),
      home: AppShell(skipOnboarding: skipOnboarding),
    );
  }
}

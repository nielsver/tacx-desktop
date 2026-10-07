import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const TacxDesktopApp());
}

class TacxDesktopApp extends StatelessWidget {
  const TacxDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tacx Desktop',
      debugShowCheckedModeBanner: false,
      theme: buildRideTheme(),
      home: const RideDashboard(),
    );
  }
}

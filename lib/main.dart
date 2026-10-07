import 'package:flutter/material.dart';
import 'package:tacx_desktop/src/rust/frb_generated.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const TacxDesktopApp());
}

class TacxDesktopApp extends StatelessWidget {
  const TacxDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1E88E5),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Tacx Desktop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: base.copyWith(
          surface: const Color(0xFF12161C),
          primary: const Color(0xFF42A5F5),
          secondary: const Color(0xFF26C6DA),
          error: const Color(0xFFEF5350),
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0E12),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const RideDashboard(),
    );
  }
}

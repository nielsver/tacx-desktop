import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Suite-wide: a tap that would miss its widget fails the test instead of
/// printing a warning (those warnings hid a CI-only failure in 284902b).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  WidgetController.hitTestWarningShouldBeFatal = true;
  await testMain();
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';

void main() {
  test('type scale is strictly descending with readable minimums', () {
    for (var i = 1; i < RideType.all.length; i++) {
      expect(RideType.all[i], lessThan(RideType.all[i - 1]));
    }
    expect(RideType.hero, greaterThanOrEqualTo(48));
    expect(RideType.target, 40);
    expect(RideType.caption, greaterThanOrEqualTo(12));
    expect(RideType.footnote, greaterThanOrEqualTo(11));
  });

  test('power hero dominates the secondary metrics', () {
    expect(RideType.hero / RideType.metric, greaterThanOrEqualTo(2.5));
  });

  test('dashboard has no orphan font sizes outside RideType', () {
    final literal = RegExp(r'fontSize:\s*\d');
    for (final path in ['lib/main.dart', 'lib/src/ui/ride_dashboard.dart']) {
      final lines = File(path).readAsLinesSync();
      final offenders = <String>[];
      for (var i = 0; i < lines.length; i++) {
        if (literal.hasMatch(lines[i])) {
          offenders.add('$path:${i + 1}: ${lines[i].trim()}');
        }
      }
      expect(offenders, isEmpty, reason: 'Use RideType tokens instead');
    }
  });
}

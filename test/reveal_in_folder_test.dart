import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/ride_summary_view.dart';
import 'package:tacx_desktop/src/ui/ride_theme.dart';
import 'package:tacx_desktop/src/util/reveal_in_folder.dart';

class _Calls {
  final List<(String, List<String>)> calls = [];
  int Function(String exe) exit = (_) => 0;
  bool throwOn(String exe) => false;

  Future<ProcessResult> run(String exe, List<String> args) async {
    calls.add((exe, args));
    if (throwOn(exe)) throw ProcessException(exe, args);
    return ProcessResult(1, exit(exe), '', '');
  }
}

void main() {
  test('Linux ShowItems arg shape (file URI, spaces encoded)', () {
    final a = Reveal.showItemsArgs('/home/niels/Documents/Tacx Desktop/r.tcx');
    expect(a, [
      '--session',
      '--print-reply',
      '--dest=org.freedesktop.FileManager1',
      '--type=method_call',
      '/org/freedesktop/FileManager1',
      'org.freedesktop.FileManager1.ShowItems',
      'array:string:file:///home/niels/Documents/Tacx%20Desktop/r.tcx',
      'string:',
    ]);
  });

  test('Linux falls back to xdg-open on the folder when D-Bus fails', () async {
    final c = _Calls()..exit = (e) => e == 'dbus-send' ? 1 : 0;
    final ok = await Reveal(
      run: c.run,
      os: 'linux',
    ).showInFolder('/a/b c/r.tcx');
    expect(ok, isTrue);
    expect(c.calls.map((x) => x.$1), ['dbus-send', 'xdg-open']);
    expect(c.calls.last.$2, ['/a/b c']);
  });

  test('Windows: explorer /select, with spaces; any exit code is OK', () async {
    final c = _Calls()..exit = (_) => 1;
    const p = r'C:\Users\Niels\Documents\Tacx Desktop\r.tcx';
    expect(await Reveal(run: c.run, os: 'windows').showInFolder(p), isTrue);
    expect(
      [c.calls.single.$1, ...c.calls.single.$2],
      [
        'explorer',
        ...['/select,', p],
      ],
    );
    await Reveal(run: c.run, os: 'windows').openUrl(kGarminImportUrl);
    expect(
      [c.calls.last.$1, ...c.calls.last.$2],
      [
        'cmd',
        ...['/c', 'start', '', kGarminImportUrl],
      ],
    );
  });

  test('macOS open -R; missing tool → false', () async {
    final c = _Calls();
    expect(
      await Reveal(run: c.run, os: 'macos').showInFolder('/x/r.tcx'),
      isTrue,
    );
    expect(
      [c.calls.single.$1, ...c.calls.single.$2],
      [
        'open',
        ...['-R', '/x/r.tcx'],
      ],
    );
    final bad = _Calls()..exit = (_) => 0;
    bool t(String _) => true;
    final r = Reveal(
      run: (e, a) async => t(e) ? throw ProcessException(e, a) : bad.run(e, a),
      os: 'linux',
    );
    expect(await r.showInFolder('/x/r.tcx'), isFalse);
  });

  Widget host(_Calls c, {required bool demo, required List<int> saves}) =>
      MaterialApp(
        theme: buildRideTheme(),
        home: Scaffold(
          body: SummaryActions(
            isDemo: demo,
            saveTcx: () async {
              saves.add(1);
              return '/home/n/Documents/Tacx Desktop/tacx-ride-1.tcx';
            },
            reveal: Reveal(run: c.run, os: 'linux'),
            onDone: () {},
          ),
        ),
      );

  testWidgets('Garmin handoff: saves once, reveals, opens import page', (
    t,
  ) async {
    final c = _Calls();
    final saves = <int>[];
    await t.pumpWidget(host(c, demo: false, saves: saves));
    await t.tap(find.byKey(const ValueKey('summary-garmin')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('summary-show-folder')));
    await t.pumpAndSettle();
    expect(saves.length, 1, reason: 'one TCX per ride');
    expect(c.calls.map((x) => x.$1), ['dbus-send', 'xdg-open', 'dbus-send']);
    expect(c.calls[1].$2, [kGarminImportUrl]);
    expect(
      t.widget<Text>(find.byKey(const ValueKey('summary-status'))).data,
      contains('Import Data'),
    );
    final save = t.widget<OutlinedButton>(
      find.byKey(const ValueKey('summary-save-tcx')),
    );
    expect(save.onPressed, isNull, reason: 'Saved: no second file');
  });

  testWidgets('Demo effort: Garmin button refused, nothing launched', (
    t,
  ) async {
    final c = _Calls();
    final saves = <int>[];
    await t.pumpWidget(host(c, demo: true, saves: saves));
    final b = t.widget<OutlinedButton>(
      find.byKey(const ValueKey('summary-garmin')),
    );
    expect(b.onPressed, isNull);
    expect(c.calls, isEmpty);
    expect(saves, isEmpty);
    // Show in folder still works for a demo TCX (local file only).
    await t.tap(find.byKey(const ValueKey('summary-show-folder')));
    await t.pumpAndSettle();
    expect(c.calls.single.$1, 'dbus-send');
    expect(c.calls.any((x) => x.$2.contains(kGarminImportUrl)), isFalse);
  });
}

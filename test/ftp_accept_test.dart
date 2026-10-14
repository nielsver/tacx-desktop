import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/ui/ftp_accept_dialog.dart';

void main() {
  Future<bool?> run(
    WidgetTester t,
    int newW,
    int oldW,
    List<String> taps,
  ) async {
    bool? result;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async => result = await confirmNewFtp(
              ctx,
              newW: newW,
              oldW: oldW,
              method: 'ramp test',
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    for (final k in taps) {
      await t.tap(find.byKey(ValueKey(k)));
      await t.pumpAndSettle();
    }
    return result;
  }

  testWidgets('accept applies (small change, one confirm)', (t) async {
    expect(await run(t, 255, 240, ['ftp-accept']), isTrue);
    expect(find.textContaining('big change'), findsNothing);
  });

  testWidgets('keep never applies', (t) async {
    expect(await run(t, 255, 240, ['ftp-keep']), isFalse);
  });

  testWidgets('>15 % needs a second confirm', (t) async {
    expect(await run(t, 300, 240, ['ftp-accept', 'ftp-keep']), isFalse);
    expect(await run(t, 300, 240, ['ftp-accept', 'ftp-accept']), isTrue);
  });
}

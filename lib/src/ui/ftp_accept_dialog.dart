import 'package:flutter/material.dart';

/// Changes bigger than this need a second confirmation (step 4, F3).
const kFtpBigChange = 0.15;

/// "New FTP: 255 W (was 240 W, +6 %). Use it?" Never auto-applies: returns
/// true only when the rider accepts (twice for a change over ±15 %).
Future<bool> confirmNewFtp(
  BuildContext context, {
  required int newW,
  required int oldW,
  required String method,
}) async {
  final pct = oldW > 0 ? (newW - oldW) / oldW : 0.0;
  final sign = pct >= 0 ? '+' : '−';
  final pctText = '$sign${(pct.abs() * 100).round()} %';
  Future<bool> ask(String title, String body, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: ValueKey('ftp-dialog-$yes'),
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              key: const ValueKey('ftp-keep'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Keep $oldW W'),
            ),
            FilledButton(
              key: const ValueKey('ftp-accept'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(yes),
            ),
          ],
        ),
      ) ??
      false;

  final first = await ask(
    'New FTP: $newW W',
    'From your $method (was $oldW W, $pctText). Use it for zones and '
        'workout targets?',
    'Use $newW W',
  );
  if (!first) return false;
  if (pct.abs() <= kFtpBigChange) return true;
  if (!context.mounted) return false;
  return ask(
    'That is a big change ($pctText)',
    'A change over ${(kFtpBigChange * 100).round()} % usually means the test '
        'was paced off or a reading glitched. Apply $newW W anyway?',
    'Apply anyway',
  );
}

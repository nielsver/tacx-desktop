// Local calendar helpers for progress (Rust stays timezone-free). Computed
// once when an effort is processed and stored as given.

/// "2026-10-14" of [ms] in the OS timezone at processing time.
String localDateOf(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// Days since 1970-01-01 of the local calendar date (DST-proof: built from
/// the date, not from elapsed hours).
int localDayIndex(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/
      86400000;
}

/// Monday-based ISO week index (consecutive across years). 1970-01-01 was a
/// Thursday, so day 0 + 3 lands on Sunday of week 0.
int isoWeekIndexOfDay(int day) => ((day + 3) / 7).floor();

int isoWeekIndex(int ms) => isoWeekIndexOfDay(localDayIndex(ms));

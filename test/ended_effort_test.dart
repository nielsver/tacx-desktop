import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';
import 'package:tacx_desktop/src/util/reveal_in_folder.dart';

RideSlice _s(
  int id,
  EffortType t,
  String key, {
  EndReason? end,
  bool done = false,
  bool demo = false,
}) => RideSlice(
  id: id,
  kind: EffortKind(kind: t, key: key),
  demo: demo,
  startMs: id * 1000,
  endMs: id * 1000 + 500,
  first: 0,
  end: 0,
  movingS: 0,
  pausedS: 0,
  completed: done,
  eligibleForRecords: !demo && end != EndReason.abandoned,
  endReason: end,
);

void main() {
  test('QA c6 P1-A: a micro free ride after the finish never wins', () {
    // Repro: route ends (completed), rider pedals on → free ride opens.
    final all = [
      _s(1, EffortType.route, 'r', end: EndReason.completed, done: true),
      _s(2, EffortType.freeRide, 'free'),
    ];
    final s = resolveEndedEffort(all, startedId: 1)!;
    expect(s.id, 1);
    expect(shouldSaveGhost(s), isTrue);
    // Without a started id: the latest closed effort, not the open one.
    expect(resolveEndedEffort(all)!.id, 1);
  });

  test(
    'QA c6 P2-1: a route re-begun after a dropout resolves to the new id',
    () {
      final all = [
        _s(3, EffortType.route, 'r', end: EndReason.disconnectTimeout),
        _s(4, EffortType.route, 'r', end: EndReason.completed, done: true),
        _s(5, EffortType.freeRide, 'free'),
      ];
      expect(resolveEndedEffort(all, startedId: 3)!.id, 4);
    },
  );

  test('summary threshold: started efforts always, free rides need 60 s', () {
    expect(summaryMinS(EffortType.route), 1);
    expect(summaryMinS(EffortType.workout), 1);
    expect(summaryMinS(EffortType.freeRide), 60);
  });

  test('QA c6 P2-6: ShowItems URI keeps commas in one array element', () {
    final a = Reveal.showItemsArgs('/home/n/Rides/a,b ride.tcx');
    final arr = a.firstWhere((x) => x.startsWith('array:string:'));
    expect(arr, isNot(contains(',')));
    expect(arr, contains('a%2Cb'));
  });

  test('QA c7 P1-B / c8: progress on every real, non-demo end', () {
    final free = EffortType.freeRide, route = EffortType.route;
    for (final r in EndReason.values) {
      expect(progressOnEnd(_s(1, free, 'free', end: r)), isTrue, reason: '$r');
      expect(progressOnEnd(_s(1, route, 'r', end: r)), isTrue, reason: '$r');
    }
    expect(progressOnEnd(_s(1, free, 'free')), isFalse, reason: 'still open');
    expect(
      progressOnEnd(_s(1, free, 'free', end: EndReason.stopped, demo: true)),
      isFalse,
    );
  });

  test('QA c8 P1-C: link-lost summary only for free rides', () {
    expect(
      linkLostSummary(
        _s(1, EffortType.freeRide, 'free', end: EndReason.disconnectTimeout),
      ),
      isTrue,
    );
    for (final k in [EffortType.route, EffortType.workout]) {
      expect(
        linkLostSummary(_s(1, k, 'k', end: EndReason.disconnectTimeout)),
        isFalse,
      );
      expect(linkLostSummary(_s(1, k, 'k', end: EndReason.stopped)), isFalse);
    }
  });

  test('QA c10: after Abandoned, a fresh free ride records (toast once)', () {
    final abandoned = _s(1, EffortType.route, 'r', end: EndReason.abandoned);
    final free = _s(2, EffortType.freeRide, 'free');
    // The abandoned route keeps its summary; the free ride is a new effort.
    expect(resolveEndedEffort([abandoned, free], startedId: 1)!.id, 1);
    expect(shouldSaveGhost(abandoned), isFalse);
    expect(freeRideAfterAbandonToast(pending: true, current: free), isTrue);
    expect(freeRideAfterAbandonToast(pending: false, current: free), isFalse);
    expect(
      freeRideAfterAbandonToast(
        pending: true,
        current: _s(3, EffortType.route, 'r'),
      ),
      isFalse,
    );
    expect(freeRideAfterAbandonToast(pending: true), isFalse);
    expect(kFreeAfterAbandonToast, 'Trainer back — recording a free ride');
  });

  test('QA c11: a route / workout start clears the pending toast', () {
    final route = _s(3, EffortType.route, 'r');
    final free = _s(2, EffortType.freeRide, 'free');
    expect(freeAfterAbandonPending(pending: true), isTrue, reason: 'waiting');
    expect(freeAfterAbandonPending(pending: true, current: route), isFalse);
    expect(freeAfterAbandonPending(pending: true, current: free), isFalse);
    expect(freeAfterAbandonPending(pending: false), isFalse);
    // Route started first, then a later free ride: no out-of-context toast.
    var p = freeAfterAbandonPending(pending: true, current: route);
    expect(freeRideAfterAbandonToast(pending: p, current: free), isFalse);
  });
}

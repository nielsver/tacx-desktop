import 'package:flutter_test/flutter_test.dart';
import 'package:tacx_desktop/src/rust/trainer/types.dart';
import 'package:tacx_desktop/src/ui/ride_dashboard.dart';

/// Ride-boundary checklist: ghost save is gated on the closed effort.
void main() {
  RideSlice slice({
    EffortType kind = EffortType.route,
    bool demo = false,
    bool completed = true,
    bool? eligible,
  }) => RideSlice(
    id: 1,
    kind: EffortKind(kind: kind, key: 'v2-abc'),
    demo: demo,
    startMs: 0,
    endMs: 1000,
    first: 0,
    end: 10,
    movingS: 10,
    pausedS: 0,
    completed: completed,
    eligibleForRecords: eligible ?? !demo,
    endReason: completed ? EndReason.completed : EndReason.stopped,
  );

  test('completed real Route saves', () {
    expect(shouldSaveGhost(slice()), isTrue);
  });
  test('QA c9: Abandoned / LinkLost-gap rides never save', () {
    expect(shouldSaveGhost(slice(eligible: false)), isFalse);
  });
  test('Demo route never saves', () {
    expect(shouldSaveGhost(slice(demo: true)), isFalse);
  });
  test('Stopped route or a Workout does not save', () {
    expect(shouldSaveGhost(slice(completed: false)), isFalse);
    expect(shouldSaveGhost(slice(kind: EffortType.workout)), isFalse);
    expect(shouldSaveGhost(null), isFalse);
  });
}

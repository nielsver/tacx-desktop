# Power → speed model (design note)

*Step 2 follow-up. Ghost progress today uses the trainer's wheel-speed
odometer (or Demo creep). Racing friends fairly, and comparing across
trainers with different wheel radii / virtual gearing, needs a shared
physics model. This is the plan; a first implementation is fine once the
route-key / store work is in.*

## Goal

Given power (W), grade (%), rider + bike mass (kg), CdA (m²) and Crr,
produce a forward speed (m/s). The same function drives:

1. Ghost progress when the trainer reports no (or suspect) wheel speed.
2. Fair comparison between a Demo / ERG ride and a live sim ride.
3. Later: live multiplayer positions when a rider is on ERG without a
   speed sensor (step 5).

## Model (Martin / Coggan, steady-state)

\[
P = (½ ρ C_dA v^3 + C_{rr} m g v + m g \sin\theta · v) / η
\]

Solved for \(v\) with a short fixed-point / Newton iteration (≤ 8 steps).
Defaults for indoors: \(ρ = 1.2\), \(C_dA = 0.32\), \(C_{rr} = 0.004\),
\(η = 0.97\), \(m = rider + bike\) (bike 8 kg). Wind = 0 indoors.

## Where it lives

- Rust module `rust/src/trainer/physics.rs` (pure, no BLE).
- Exposed to Flutter as `powerToSpeedMps(powerW, gradePct, massKg)`.
- Unit tests: flat 200 W → ~8.3 m/s; 5 % @ 250 W → ~4.5 m/s; NaN / 0 W → 0.

## First cut (on main)

Implemented as a pure function, twice, with the same constants and the
same checked examples. Codegen 2.13.0 reformats `frb_generated` in place,
so the Flutter bridge was left as it was. The screen calls the Dart copy.
The Rust copy is what ghost progress and multiplayer should call once the
bridge is regenerated cleanly.

- Rust: `rust/src/trainer/physics.rs`, wrapped by `power_to_speed_mps` in
  `rust/src/api/trainer.rs`.
- Dart: `lib/src/ride/virtual_speed.dart` (`virtualSpeedMps`).
- Checked: 200 W flat, 83 kg → 9.47 m/s (34 km/h). 250 W at 5% → 4.98 m/s
  (18 km/h). 0 W stays 0, including downhill. The older "~8.3 m/s" note was
  a rough memory; these constants produce the checked values above.

The first world is a fixed flat loop on the FTP assessment screen
(`RideWorld` in `lib/src/ui/ride_world.dart`). Cadence turns the pedals.
Forward motion uses this model, not trainer wheel speed, and it is not
written into TCX. A GPX route and a real-time glTF scene stay later:
`flutter_scene` needs Flutter ≥ 3.47, and CI is still pinned to 3.35.5.

## Out of scope for the first cut

- Cascading (drafting) — step 5.
- Per-rider CdA / Crr prefs UI — step 4.
- Replacing the FTMS Indoor Bike Simulation path (the trainer already does
  its own physics there).

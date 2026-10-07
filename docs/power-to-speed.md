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

## Out of scope for the first cut

- Cascading (drafting) — step 5.
- Per-rider CdA / Crr prefs UI — step 4.
- Replacing the FTMS Indoor Bike Simulation path (the trainer already does
  its own physics there).

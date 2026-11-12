//! Martin/Coggan steady-state speed for the on-screen virtual world.
//! Not used for trainer control or recorded wheel speed.

const RHO: f64 = 1.2;
const CDA: f64 = 0.32;
const CRR: f64 = 0.004;
const ETA: f64 = 0.97;
const G: f64 = 9.80665;
const DEFAULT_MASS_KG: f64 = 83.0;
const MAX_SPEED_MPS: f64 = 40.0;
const MAX_NEWTON_ITERS: usize = 8;
const AERO: f64 = 0.5 * RHO * CDA;

/// Steady-state speed (m/s) from power (W), grade (percent), and total mass (kg).
///
/// `P_wheel = power * η = aero * v³ + mass * g * (Crr + sin(atan(grade/100))) * v`.
/// Non-finite or non-positive power returns 0 (no coast). Non-finite grade is
/// flat. Non-finite or non-positive mass uses 83 kg (75 kg rider + 8 kg bike).
pub fn power_to_speed_mps(power_w: f64, grade_pct: f64, mass_kg: f64) -> f64 {
    if !power_w.is_finite() || power_w <= 0.0 {
        return 0.0;
    }
    let grade_pct = if grade_pct.is_finite() { grade_pct } else { 0.0 };
    let mass_kg = if mass_kg.is_finite() && mass_kg > 0.0 {
        mass_kg
    } else {
        DEFAULT_MASS_KG
    };

    let p_wheel = power_w * ETA;
    let resist = mass_kg * G * (CRR + (grade_pct / 100.0).atan().sin());
    let residual = |v: f64| AERO * v * v * v + resist * v - p_wheel;

    // One positive root. At or above the cap, skip Newton.
    if residual(MAX_SPEED_MPS) <= 0.0 {
        return MAX_SPEED_MPS;
    }

    // Uphill/flat: the slower of pure-aero and pure-resist overestimates the root.
    // Downhill: coast speed alone overshoots and does not settle in 8 Newton steps.
    let v_aero = (p_wheel / AERO).cbrt();
    let mut v = if resist > 0.0 {
        v_aero.min(p_wheel / resist)
    } else if resist < 0.0 {
        let v_coast = (-resist / AERO).sqrt();
        v_coast.hypot(v_aero)
    } else {
        v_aero
    };

    for _ in 0..MAX_NEWTON_ITERS {
        let slope = 3.0 * AERO * v * v + resist;
        if !slope.is_finite() || slope.abs() < 1e-12 {
            break;
        }
        let next = v - residual(v) / slope;
        if !next.is_finite() {
            break;
        }
        v = next.max(0.0);
    }

    if !v.is_finite() {
        return 0.0;
    }
    v.clamp(0.0, MAX_SPEED_MPS)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_near(actual: f64, expected: f64) {
        assert!((actual - expected).abs() < 0.02, "actual {actual}");
    }

    #[test]
    fn flat_200w_83kg() {
        assert_near(power_to_speed_mps(200.0, 0.0, 83.0), 9.4719);
    }

    #[test]
    fn grade_5pct_250w() {
        assert_near(power_to_speed_mps(250.0, 5.0, 83.0), 4.9826);
    }

    #[test]
    fn flat_100w_83kg() {
        assert_near(power_to_speed_mps(100.0, 0.0, 83.0), 7.2568);
    }

    #[test]
    fn zero_power_is_zero() {
        assert_near(power_to_speed_mps(0.0, 0.0, 83.0), 0.0);
        // No coast on a descent either.
        assert_near(power_to_speed_mps(0.0, -5.0, 83.0), 0.0);
    }

    #[test]
    fn negative_power_is_zero() {
        assert_near(power_to_speed_mps(-50.0, 0.0, 83.0), 0.0);
    }

    #[test]
    fn nan_power_is_zero() {
        assert_near(power_to_speed_mps(f64::NAN, 0.0, 83.0), 0.0);
    }

    #[test]
    fn nan_grade_matches_flat_200w() {
        assert_near(power_to_speed_mps(200.0, f64::NAN, 83.0), 9.4719);
    }

    #[test]
    fn downhill_5pct_200w() {
        assert_near(power_to_speed_mps(200.0, -5.0, 83.0), 16.0527);
    }

    #[test]
    fn grade_8pct_400w() {
        assert_near(power_to_speed_mps(400.0, 8.0, 83.0), 5.2780);
    }

    #[test]
    fn non_positive_mass_uses_83kg() {
        assert_near(power_to_speed_mps(200.0, 0.0, 0.0), 9.4719);
    }
}

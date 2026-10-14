//! Automatic climb detection on a GPX elevation profile (step 4, P1;
//! thresholds from the climbs research checklist). Detection only: the
//! simulation grade path in `gpx.rs` is untouched.
//!
//! Pipeline: zero-elevation repair → 10 m resample → 50 m median → ±50 m
//! moving average → rising runs with a 3 m deadband → merge short dips →
//! trim flat ends (< 2 % over 100 m) → accept len ≥ 500 m, grade ≥ 3 %,
//! score ≥ 1 500 (Garmin ClimbPro "All"). Score = len_m × grade_% = 100 × gain.

use crate::trainer::gpx::elev_at;
use crate::trainer::types::{Climb, ClimbCat, ElevSample};

/// Bumped when any parameter changes: stored as `detector` in `.prs.json`.
pub const DETECTOR_VERSION: u32 = 1;
pub const STEP_M: f64 = 10.0;
pub const DEADBAND_M: f64 = 3.0;
/// Median window, samples (50 m).
const MEDIAN_N: usize = 5;
/// Moving-average half width, samples (±50 m).
const SMOOTH_HALF: usize = 5;
pub const MIN_LEN_M: f64 = 500.0;
pub const MIN_GRADE_PCT: f64 = 3.0;
pub const MIN_SCORE: f64 = 1500.0;
pub const TRIM_GRADE_PCT: f64 = 2.0;
/// Trim / max-grade window, samples (100 m).
const WIN_100: usize = 10;
pub const MAX_CLIMBS: usize = 20;
/// Zero elevation counts as missing when the route median is above this.
const ZERO_MISSING_MEDIAN_M: f64 = 20.0;

pub fn category(score: f64) -> ClimbCat {
    match score {
        x if x > 80_000.0 => ClimbCat::Hc,
        x if x > 64_000.0 => ClimbCat::Cat1,
        x if x > 32_000.0 => ClimbCat::Cat2,
        x if x > 16_000.0 => ClimbCat::Cat3,
        x if x > 8_000.0 => ClimbCat::Cat4,
        _ => ClimbCat::Climb,
    }
}

fn median(mut v: Vec<f64>) -> f64 {
    v.sort_by(f64::total_cmp);
    if v.is_empty() {
        0.0
    } else {
        v[v.len() / 2]
    }
}

/// Copy with `elev == 0` treated as missing (when the route sits above
/// 20 m) and linearly interpolated; edge gaps take the nearest value.
fn fix_zero(s: &[ElevSample]) -> Vec<ElevSample> {
    let med = median(s.iter().map(|x| x.elev_m).collect());
    let mut out = s.to_vec();
    if med <= ZERO_MISSING_MEDIAN_M {
        return out;
    }
    let ok: Vec<usize> = (0..s.len()).filter(|&i| s[i].elev_m != 0.0).collect();
    if ok.is_empty() {
        return out;
    }
    for i in 0..out.len() {
        if s[i].elev_m != 0.0 {
            continue;
        }
        let j = ok.partition_point(|&k| k < i);
        out[i].elev_m = match (j.checked_sub(1).map(|p| ok[p]), ok.get(j).copied()) {
            (Some(a), Some(b)) => {
                let span = (s[b].distance_m - s[a].distance_m).max(1e-9);
                let t = (s[i].distance_m - s[a].distance_m) / span;
                s[a].elev_m + (s[b].elev_m - s[a].elev_m) * t
            }
            (Some(a), None) => s[a].elev_m,
            (None, Some(b)) => s[b].elev_m,
            (None, None) => 0.0,
        };
    }
    out
}

fn resample(s: &[ElevSample]) -> Vec<f64> {
    let total = s.last().map_or(0.0, |l| l.distance_m);
    let n = (total / STEP_M).floor() as usize + 1;
    (0..n).map(|i| elev_at(s, i as f64 * STEP_M)).collect()
}

fn median_filter(e: &[f64], n: usize) -> Vec<f64> {
    let h = n / 2;
    (0..e.len())
        .map(|i| median(e[i.saturating_sub(h)..(i + h + 1).min(e.len())].to_vec()))
        .collect()
}

fn smooth(e: &[f64], half: usize) -> Vec<f64> {
    (0..e.len())
        .map(|i| {
            let w = &e[i.saturating_sub(half)..(i + half + 1).min(e.len())];
            w.iter().sum::<f64>() / w.len() as f64
        })
        .collect()
}

/// Spike-free 10 m grid (median only): what gain / grade are measured on.
fn measure_profile(s: &[ElevSample]) -> Vec<f64> {
    median_filter(&resample(&fix_zero(s)), MEDIAN_N)
}

/// Smoothed 10 m-grid elevation used to find and trim climbs.
pub fn detection_profile(s: &[ElevSample]) -> Vec<f64> {
    smooth(&measure_profile(s), SMOOTH_HALF)
}

/// (last low, last high) of every rise ≥ deadband.
fn rising_runs(e: &[f64], db: f64) -> Vec<(usize, usize)> {
    let mut runs = Vec::new();
    if e.is_empty() {
        return runs;
    }
    let mut low = 0usize;
    let mut high: Option<usize> = None;
    for i in 1..e.len() {
        match high {
            None => {
                if e[i] < e[low] {
                    low = i;
                } else if e[i] - e[low] >= db {
                    high = Some(i);
                }
            }
            Some(h) => {
                if e[i] > e[h] {
                    high = Some(i);
                } else if e[h] - e[i] >= db {
                    runs.push((low, h));
                    low = i;
                    high = None;
                }
            }
        }
    }
    if let Some(h) = high {
        runs.push((low, h));
    }
    runs
}

/// One merge pass; true if anything merged.
fn merge_pass(runs: &mut Vec<(usize, usize)>, e: &[f64]) -> bool {
    for k in 0..runs.len().saturating_sub(1) {
        let (a0, a1) = runs[k];
        let (b0, b1) = runs[k + 1];
        let gain_a = e[a1] - e[a0];
        let len_a = (a1 - a0) as f64 * STEP_M;
        // Lowest point of the dip between the two runs.
        let dip_low = (a1..=b0).map(|i| e[i]).fold(f64::INFINITY, f64::min);
        let loss = e[a1] - dip_low;
        let dip_len = (b0 - a1) as f64 * STEP_M;
        if loss <= (10.0f64).max(0.25 * gain_a) && dip_len <= (300.0f64).max(0.2 * len_a) {
            let end = if e[b1] >= e[a1] { b1 } else { a1 };
            runs[k] = (a0, end);
            runs.remove(k + 1);
            return true;
        }
    }
    false
}

fn grade_pct(e: &[f64], i: usize, j: usize) -> f64 {
    (e[j] - e[i]) / ((j - i) as f64 * STEP_M) * 100.0
}

/// Grade over the 100 m centred on `i` (shrunk at the profile ends).
fn grade_at(e: &[f64], i: usize) -> f64 {
    let h = WIN_100 / 2;
    let (a, b) = (i.saturating_sub(h), (i + h).min(e.len() - 1));
    if b > a { grade_pct(e, a, b) } else { 0.0 }
}

/// Drop flat ends: smoothing spreads a climb's corners ~50 m each way.
fn trim_flat((mut i0, mut i1): (usize, usize), e: &[f64]) -> (usize, usize) {
    while i0 < i1 && grade_at(e, i0) < TRIM_GRADE_PCT {
        i0 += 1;
    }
    while i1 > i0 && grade_at(e, i1) < TRIM_GRADE_PCT {
        i1 -= 1;
    }
    (i0, i1)
}

fn round10(m: f64) -> i64 {
    ((m / 10.0).round() * 10.0) as i64
}

/// Detect climbs on `samples` (at most [`MAX_CLIMBS`], ordered by start).
pub fn detect_climbs(samples: &[ElevSample], route_key: &str) -> Vec<Climb> {
    if samples.len() < 2 {
        return Vec::new();
    }
    let raw = measure_profile(samples);
    let e = smooth(&raw, SMOOTH_HALF);
    let mut runs = rising_runs(&e, DEADBAND_M);
    while merge_pass(&mut runs, &e) {}
    let mut out: Vec<Climb> = runs
        .into_iter()
        .map(|r| trim_flat(r, &e))
        .filter(|(i0, i1)| i1 > i0)
        .filter_map(|(i0, i1)| {
            let len = (i1 - i0) as f64 * STEP_M;
            // Bounds from the smoothed profile, numbers from the spike-free
            // one (smoothing shaves a few metres off every summit).
            let gain = raw[i1] - raw[i0];
            let g = gain / len * 100.0;
            let score = len * g;
            if !(len >= MIN_LEN_M && g >= MIN_GRADE_PCT && score >= MIN_SCORE) {
                return None;
            }
            let max_g = (i0..=i1.saturating_sub(WIN_100))
                .filter(|&i| i + WIN_100 <= i1)
                .map(|i| grade_pct(&raw, i, i + WIN_100))
                .fold(g, f64::max);
            let (start_m, end_m) = (i0 as f64 * STEP_M, i1 as f64 * STEP_M);
            Some(Climb {
                id: format!("{route_key}:{}-{}", round10(start_m), round10(end_m)),
                start_m,
                end_m,
                gain_m: gain,
                avg_grade: g,
                max_grade_100m: max_g,
                score,
                category: category(score),
            })
        })
        .collect();
    out.sort_by(|a, b| b.score.total_cmp(&a.score));
    out.truncate(MAX_CLIMBS);
    out.sort_by(|a, b| a.start_m.total_cmp(&b.start_m));
    out
}

/// Time at which the ride first crosses `m` metres (interpolated).
fn cross(track: &[(f64, f64)], m: f64) -> Option<f64> {
    let j = track.iter().position(|&(_, d)| d >= m)?;
    if j == 0 {
        return (track[0].1 == m).then_some(track[0].0);
    }
    let (t0, d0) = track[j - 1];
    let (t1, d1) = track[j];
    Some(t0 + (m - d0) / (d1 - d0).max(1e-9) * (t1 - t0))
}

/// Seconds from `start_m` to `end_m` on a `(t_s, ride distance m)` track
/// (route distance, never GPS). `None` if the climb wasn't finished.
pub fn climb_time_s(track: &[(f64, f64)], c: &Climb) -> Option<f64> {
    let t = cross(track, c.end_m)? - cross(track, c.start_m)?;
    (t > 0.0).then_some(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a 10 m-spaced profile from (length_m, grade_%) segments.
    fn profile(segs: &[(f64, f64)], base: f64) -> Vec<ElevSample> {
        let mut out = vec![];
        let (mut d, mut e) = (0.0, base);
        out.push(ElevSample { distance_m: 0.0, elev_m: e, grade_pct: 0.0, lat: 0.0, lon: 0.0 });
        for &(len, g) in segs {
            let n = (len / 10.0).round() as usize;
            for _ in 0..n {
                d += 10.0;
                e += g / 100.0 * 10.0;
                out.push(ElevSample { distance_m: d, elev_m: e, grade_pct: 0.0, lat: 0.0, lon: 0.0 });
            }
        }
        out
    }

    fn near(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    fn check(c: &Climb, len: f64, gain: f64, grade: f64) {
        let l = c.end_m - c.start_m;
        assert!(near(l, len, 60.0), "len {l} vs {len}: {c:?}");
        assert!(near(c.gain_m, gain, 2.0), "gain {} vs {gain}: {c:?}", c.gain_m);
        assert!(near(c.avg_grade, grade, 0.3), "grade {} vs {grade}: {c:?}", c.avg_grade);
    }

    #[test]
    fn f1_two_km_at_5_pct_is_one_cat4() {
        let c = detect_climbs(&profile(&[(1000.0, 0.0), (2000.0, 5.0), (1000.0, 0.0)], 30.0), "k");
        assert_eq!(c.len(), 1, "{c:?}");
        check(&c[0], 2000.0, 100.0, 5.0);
        assert!(near(c[0].score, 10_000.0, 250.0), "{}", c[0].score);
        assert_eq!(c[0].category, ClimbCat::Cat4);
        assert!(near(c[0].start_m, 1000.0, 60.0));
    }

    #[test]
    fn f2_short_flat_merges_into_one_climb() {
        let c = detect_climbs(
            &profile(&[(1000.0, 0.0), (1000.0, 6.0), (150.0, 0.0), (1000.0, 6.0), (1000.0, 0.0)], 30.0),
            "k",
        );
        assert_eq!(c.len(), 1, "merged: {c:?}");
        check(&c[0], 2150.0, 120.0, 5.58);
        assert!(near(c[0].score, 12_000.0, 300.0));
        assert_eq!(c[0].category, ClimbCat::Cat4);
    }

    #[test]
    fn f3_noisy_flat_with_spike_and_zero_has_no_climbs() {
        let mut s: Vec<ElevSample> = (0..=500)
            .map(|i| {
                let d = i as f64 * 10.0;
                let alt = if i % 2 == 0 { 1.0 } else { -1.0 };
                ElevSample {
                    distance_m: d,
                    elev_m: 100.0 + 3.0 * (2.0 * std::f64::consts::PI * d / 200.0).sin() + alt,
                    grade_pct: 0.0,
                    lat: 0.0,
                    lon: 0.0,
                }
            })
            .collect();
        assert!(detect_climbs(&s, "k").is_empty());
        s[250].elev_m += 40.0; // 1-point spike at 2 500 m
        s[300].elev_m = 0.0; // dropout at 3 000 m
        assert!(detect_climbs(&s, "k").is_empty());
    }

    #[test]
    fn f4_loop_twice_gives_two_climbs_with_distinct_ids() {
        let lap = [(1000.0, 0.0), (1000.0, 6.0), (1000.0, -6.0), (1000.0, 0.0)];
        let segs: Vec<(f64, f64)> = lap.iter().chain(lap.iter()).copied().collect();
        let c = detect_climbs(&profile(&segs, 30.0), "v2-loop");
        assert_eq!(c.len(), 2, "{c:?}");
        for (x, start) in c.iter().zip([1000.0, 5000.0]) {
            check(x, 1000.0, 60.0, 6.0);
            assert!(near(x.start_m, start, 60.0));
            assert_eq!(x.category, ClimbCat::Climb);
            assert!(near(x.score, 6000.0, 250.0));
        }
        assert_ne!(c[0].id, c[1].id);
        assert!(c[0].id.starts_with("v2-loop:"));
    }

    #[test]
    fn f5_short_bump_is_not_a_climb() {
        assert!(detect_climbs(&profile(&[(1000.0, 0.0), (300.0, 4.0), (1000.0, 0.0)], 30.0), "k").is_empty());
    }

    #[test]
    fn t1_climb_time_interpolates_crossings() {
        let c = Climb {
            id: "k:1000-3000".into(),
            start_m: 1000.0,
            end_m: 3000.0,
            gain_m: 100.0,
            avg_grade: 5.0,
            max_grade_100m: 5.0,
            score: 10_000.0,
            category: ClimbCat::Cat4,
        };
        let track = [(100.0, 990.0), (102.0, 1010.0), (500.0, 2990.0), (504.0, 3010.0)];
        assert!(near(climb_time_s(&track, &c).unwrap(), 401.0, 1e-9));
        assert!(climb_time_s(&track[..3], &c).is_none(), "not finished");
    }

    #[test]
    fn categories_follow_strava_scores() {
        assert_eq!(category(1500.0), ClimbCat::Climb);
        assert_eq!(category(8001.0), ClimbCat::Cat4);
        assert_eq!(category(16001.0), ClimbCat::Cat3);
        assert_eq!(category(32001.0), ClimbCat::Cat2);
        assert_eq!(category(64001.0), ClimbCat::Cat1);
        assert_eq!(category(80001.0), ClimbCat::Hc);
    }
}

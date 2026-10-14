//! Local FTP tests (step 4, F1–F3): ramp and 20-minute estimates with
//! guards, plus the append-only `ftp-history.json`. Nothing here applies an
//! FTP; the rider accepts in the UI first.

use crate::trainer::summary::{mean_max, power_segments};
use crate::trainer::tcx::TrackPoint;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const RAMP_WORKOUT_ID: &str = "ftp_ramp";
pub const TWENTY_WORKOUT_ID: &str = "ftp_20min";
pub const RAMP_START_W: u32 = 100;
pub const RAMP_STEP_W: u32 = 20;
pub const RAMP_MAX_STEPS: u32 = 30;
/// Ramp warm-up before the first step, seconds.
pub const RAMP_WARMUP_S: usize = 300;
/// A ramp counts only after this many 1-min steps.
pub const RAMP_MIN_STEPS: usize = 4;
pub const RAMP_FACTOR: f64 = 0.75;
pub const TWENTY_FACTOR: f64 = 0.95;
pub const TWENTY_WINDOW_S: u32 = 1200;
/// Most dropouts (0 W seconds) allowed inside the scoring window.
pub const MAX_ZERO_FRACTION: f64 = 0.05;
pub const FTP_MIN_W: u32 = 50;
pub const FTP_MAX_W: u32 = 600;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FtpMethod {
    Ramp,
    TwentyMin,
}

/// A proposed FTP (the rider still has to accept it).
#[derive(Clone, Debug, PartialEq)]
pub struct FtpEstimate {
    pub watts: u32,
    pub method: FtpMethod,
    /// Best 60 s (ramp) or best 20 min (20-min test), W.
    pub basis_w: f64,
    /// The test ended on a dropout, not on the rider's Stop (QA c6 P2-4).
    pub incomplete: bool,
}

/// Seconds from the effort start to the 20-min test step (WU 10′ + 5′).
pub const TWENTY_TEST_OFFSET_S: i64 = 900;

/// Test method for a workout id, if it is an FTP test.
pub fn method_for_workout(id: &str) -> Option<FtpMethod> {
    match id {
        RAMP_WORKOUT_ID => Some(FtpMethod::Ramp),
        TWENTY_WORKOUT_ID => Some(FtpMethod::TwentyMin),
        _ => None,
    }
}

/// Best `window` s average inside one unbroken segment, with its samples.
fn best_window(segs: &[Vec<f64>], window: usize) -> Option<(f64, &[f64])> {
    let mut best: Option<(f64, &[f64])> = None;
    for seg in segs {
        if seg.len() < window || window == 0 {
            continue;
        }
        let mut sum: f64 = seg[..window].iter().sum();
        let mut at = 0;
        let mut top = sum;
        for i in window..seg.len() {
            sum += seg[i] - seg[i - window];
            if sum > top {
                top = sum;
                at = i + 1 - window;
            }
        }
        let avg = top / window as f64;
        if best.is_none_or(|(b, _)| avg > b) {
            best = Some((avg, &seg[at..at + window]));
        }
    }
    best
}

fn zero_fraction(w: &[f64]) -> f64 {
    w.iter().filter(|p| **p < 1.0).count() as f64 / w.len().max(1) as f64
}

/// Estimate FTP from a test effort's points. Errors are rider-facing.
/// `test_start_ms`: the 20-min score only uses points from there on (the
/// warm-up never counts, QA c6 P2-3).
pub fn estimate(
    points: &[TrackPoint],
    method: FtpMethod,
    demo: bool,
    test_start_ms: Option<i64>,
) -> Result<FtpEstimate, String> {
    if demo {
        return Err("Demo rides never set your FTP.".into());
    }
    let points = match (method, test_start_ms) {
        (FtpMethod::TwentyMin, Some(t)) => {
            let i = points.partition_point(|p| p.unix_ms < t);
            &points[i..]
        }
        _ => points,
    };
    let segs = power_segments(points);
    let total: usize = segs.iter().map(Vec::len).sum();
    let (window, factor) = match method {
        FtpMethod::Ramp => {
            if total < RAMP_WARMUP_S + RAMP_MIN_STEPS * 60 {
                return Err(format!(
                    "Ramp too short: ride at least {RAMP_MIN_STEPS} steps after the warm-up."
                ));
            }
            (60usize, RAMP_FACTOR)
        }
        FtpMethod::TwentyMin => {
            if total < TWENTY_WINDOW_S as usize {
                return Err(format!(
                    "The 20-minute effort lasted {}:{:02} — it needs the full 20:00.",
                    total / 60,
                    total % 60
                ));
            }
            (TWENTY_WINDOW_S as usize, TWENTY_FACTOR)
        }
    };
    let (basis, win) = best_window(&segs, window).ok_or_else(|| match method {
        FtpMethod::TwentyMin => "No unbroken 20 minutes recorded (a dropout split the effort).".to_string(),
        FtpMethod::Ramp => "No full minute recorded.".to_string(),
    })?;
    if zero_fraction(win) > MAX_ZERO_FRACTION {
        return Err("Too many dropouts in the test window to trust the result.".into());
    }
    debug_assert!(mean_max(&segs, window as u32).is_some());
    let watts = (basis * factor).round() as u32;
    if !(FTP_MIN_W..=FTP_MAX_W).contains(&watts) {
        return Err(format!("{watts} W is outside {FTP_MIN_W}–{FTP_MAX_W} W; not used."));
    }
    Ok(FtpEstimate { watts, method, basis_w: basis, incomplete: false })
}

/// One accepted FTP.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FtpHistoryEntry {
    /// UTC date-time, ISO 8601.
    pub date: String,
    pub watts: u32,
    /// "ramp" | "twentyMin" | "manual" | "passive".
    pub method: String,
    /// What produced it (e.g. the TCX file name or "settings").
    pub source: String,
}

pub fn history_path() -> PathBuf {
    crate::trainer::ride::default_export_dir().join("ftp-history.json")
}

pub fn read_history(path: &Path) -> Vec<FtpHistoryEntry> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// Append (never rewrite old entries); atomic tmp + rename. A file that
/// exists but doesn't parse is kept as `.corrupt-<unix s>` first (QA c6 P2-5).
pub fn append_history(path: &Path, e: FtpHistoryEntry) -> Result<(), String> {
    if let Ok(raw) = std::fs::read_to_string(path) {
        if serde_json::from_str::<Vec<FtpHistoryEntry>>(&raw).is_err() {
            let ts = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let bad = path.with_extension(format!("json.corrupt-{ts}"));
            std::fs::rename(path, &bad).map_err(|e| e.to_string())?;
        }
    }
    let mut all = read_history(path);
    all.push(e);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.tmp");
    let body = serde_json::to_string_pretty(&all).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, body).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pts(watts: &[f64]) -> Vec<TrackPoint> {
        watts
            .iter()
            .enumerate()
            .map(|(i, w)| TrackPoint {
                unix_ms: 1_791_385_000_000 + i as i64 * 1000,
                power_w: *w,
                cadence_rpm: 90.0,
                speed_kmh: 30.0,
                distance_m: 0.0,
                heart_rate_bpm: None,
            })
            .collect()
    }

    fn ramp_to(peak_step: u32) -> Vec<f64> {
        let mut w = vec![100.0; RAMP_WARMUP_S];
        for k in 0..=peak_step {
            w.extend(std::iter::repeat_n(f64::from(RAMP_START_W + k * RAMP_STEP_W), 60));
        }
        w
    }

    #[test]
    fn ramp_peak_minute_340_gives_255() {
        // Steps 100…340 W: best minute 340 → 0.75 × 340 = 255.
        let e = estimate(&pts(&ramp_to(12)), FtpMethod::Ramp, false, None).unwrap();
        assert_eq!(e.watts, 255);
        assert_eq!(e.basis_w, 340.0);
    }

    #[test]
    fn twenty_min_260_gives_247() {
        let mut w = vec![120.0; 900];
        w.extend(std::iter::repeat_n(260.0, 1200));
        w.extend(std::iter::repeat_n(100.0, 300));
        let e = estimate(&pts(&w), FtpMethod::TwentyMin, false, None).unwrap();
        assert_eq!(e.watts, 247);
    }

    #[test]
    fn guards_demo_short_gap_zeros_range() {
        assert!(estimate(&pts(&ramp_to(12)), FtpMethod::Ramp, true, None).unwrap_err().contains("Demo"));
        // Warm-up + 2 steps only.
        assert!(estimate(&pts(&ramp_to(1)), FtpMethod::Ramp, false, None).is_err());
        // 20 min broken by a 10 s dropout gap → no unbroken window.
        let mut p = pts(&vec![260.0; 1300]);
        for q in p.iter_mut().skip(700) {
            q.unix_ms += 10_000;
        }
        assert!(estimate(&p, FtpMethod::TwentyMin, false, None).unwrap_err().contains("unbroken"));
        // 10 % zeros inside the window.
        let mut w = vec![260.0; 1200];
        for x in w.iter_mut().step_by(10) {
            *x = 0.0;
        }
        assert!(estimate(&pts(&w), FtpMethod::TwentyMin, false, None).unwrap_err().contains("dropouts"));
        // Out of range: 20 min at 30 W → 29 W.
        assert!(estimate(&pts(&vec![30.0; 1200]), FtpMethod::TwentyMin, false, None).is_err());
    }

    #[test]
    fn history_appends_atomically() {
        let dir = std::env::temp_dir().join(format!("tacx-ftp-hist-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let p = dir.join("ftp-history.json");
        let e = |w| FtpHistoryEntry { date: "2026-10-14T16:00:00Z".into(), watts: w, method: "ramp".into(), source: "t".into() };
        append_history(&p, e(250)).unwrap();
        append_history(&p, e(255)).unwrap();
        let h = read_history(&p);
        assert_eq!(h.iter().map(|x| x.watts).collect::<Vec<_>>(), vec![250, 255]);
        assert!(!p.with_extension("json.tmp").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn builtins_include_both_tests() {
        let ids: Vec<String> = crate::trainer::workouts::list_workouts()
            .unwrap_or_default()
            .into_iter()
            .map(|w| w.id)
            .collect();
        assert!(ids.iter().any(|i| i == RAMP_WORKOUT_ID));
        assert!(ids.iter().any(|i| i == TWENTY_WORKOUT_ID));
        let t = crate::trainer::workouts::load_workout(TWENTY_WORKOUT_ID).unwrap();
        assert!(t.steps.iter().any(|s| s.kind == "resistance" && s.duration_s == Some(1200)));
        assert!(t.validate().is_ok());
        assert!(crate::trainer::workouts::load_workout(RAMP_WORKOUT_ID).unwrap().validate().is_ok());
    }

    #[test]
    fn qa_c6_twenty_min_ignores_warmup_and_needs_full_test() {
        // 900 s warm-up at 120 W, then the test stopped at 18:20 at 240 W.
        let mut w = vec![120.0; 900];
        w.extend(std::iter::repeat_n(240.0, 1100));
        let p = pts(&w);
        let start = p[900].unix_ms;
        let e = estimate(&p, FtpMethod::TwentyMin, false, Some(start)).unwrap_err();
        assert!(e.contains("20:00"), "{e}");
        // Full 20 min → only the test counts (no warm-up dilution).
        w.extend(std::iter::repeat_n(240.0, 100));
        let p = pts(&w);
        let ok = estimate(&p, FtpMethod::TwentyMin, false, Some(p[900].unix_ms)).unwrap();
        assert_eq!(ok.basis_w, 240.0);
    }

    #[test]
    fn qa_c6_corrupt_history_is_kept_aside() {
        let dir = std::env::temp_dir().join(format!("tacx-ftp-corrupt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("ftp-history.json");
        std::fs::write(&p, "[{\"date\":\"x\",\"watts\":240").unwrap();
        let e = FtpHistoryEntry { date: "d".into(), watts: 250, method: "ramp".into(), source: "t".into() };
        append_history(&p, e).unwrap();
        assert_eq!(read_history(&p).len(), 1);
        let kept: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|f| f.file_name().to_string_lossy().contains("corrupt-"))
            .collect();
        assert_eq!(kept.len(), 1);
        assert!(std::fs::read_to_string(kept[0].path()).unwrap().contains("240"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}

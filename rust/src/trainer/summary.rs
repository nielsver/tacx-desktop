//! Post-ride summary from the 1 Hz track: NP / IF / TSS, mean-max power,
//! time in zone and chart series.
//!
//! The track is split into unbroken 1 Hz segments: a gap of more than
//! [`MAX_SAMPLE_GAP_S`] (pause, reconnect) ends a segment, and a shorter
//! missed tick is filled by repeating the previous sample. Rolling windows
//! (NP's 30 s average, mean-max bests) never span a gap, so a pause can
//! neither inflate nor dilute an effort.

use crate::trainer::ride::MAX_SAMPLE_GAP_S;
use crate::trainer::tcx::TrackPoint;
use crate::trainer::types::{PowerBest, RideSummary, SUMMARY_SERIES_MAX};

/// Mean-max durations shown on the summary, seconds.
pub const BEST_DURATIONS_S: [u32; 4] = [5, 60, 300, 1200];
/// NP rolling window, seconds.
pub const NP_WINDOW_S: usize = 30;

const MAX_POWER_W: f64 = 3000.0;
const MAX_CADENCE_RPM: f64 = 250.0;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Sample {
    power_w: f64,
    cadence_rpm: f64,
    hr_bpm: Option<u32>,
}

fn sane(x: f64, max: f64) -> f64 {
    if x.is_finite() {
        x.clamp(0.0, max)
    } else {
        0.0
    }
}

/// Collapse points to one sample per wall-clock second: the **mean** of
/// every point in that second (QA C3.3: a 4 Hz input kept only the first
/// sample, so NP and the 5 s best drifted from the per-second mean).
/// Finite spikes are clamped to 3000 W first, NaN / inf count as 0.
fn per_second(points: &[TrackPoint]) -> Vec<(i64, Sample)> {
    let mut out: Vec<(i64, Sample)> = Vec::new();
    // (second, power sum, cadence sum, n, hr sum, hr n)
    let mut acc: Option<(i64, f64, f64, u32, u64, u32)> = None;
    let flush = |a: (i64, f64, f64, u32, u64, u32), out: &mut Vec<(i64, Sample)>| {
        let (sec, p, c, n, hs, hn) = a;
        let n = f64::from(n.max(1));
        out.push((
            sec,
            Sample {
                power_w: p / n,
                cadence_rpm: c / n,
                hr_bpm: (hn > 0).then(|| ((hs as f64) / f64::from(hn)).round() as u32),
            },
        ));
    };
    for p in points {
        let sec = p.unix_ms.div_euclid(1000);
        let pw = sane(p.power_w, MAX_POWER_W);
        let cd = sane(p.cadence_rpm, MAX_CADENCE_RPM);
        let hr = p.heart_rate_bpm.filter(|h| (25..=250).contains(h));
        match acc.as_mut() {
            Some(a) if a.0 == sec => {
                a.1 += pw;
                a.2 += cd;
                a.3 += 1;
                if let Some(h) = hr {
                    a.4 += u64::from(h);
                    a.5 += 1;
                }
            }
            Some(a) if sec < a.0 => {} // clock stepped back: ignore
            _ => {
                if let Some(a) = acc.take() {
                    flush(a, &mut out);
                }
                acc = Some((sec, pw, cd, 1, hr.map_or(0, u64::from), u32::from(hr.is_some())));
            }
        }
    }
    if let Some(a) = acc {
        flush(a, &mut out);
    }
    out
}

/// Split per-second samples into 1 Hz segments (see module docs).
fn segments(points: &[TrackPoint]) -> Vec<Vec<Sample>> {
    let mut out: Vec<Vec<Sample>> = Vec::new();
    let mut prev_s: Option<i64> = None;
    for (sec, s) in per_second(points) {
        match prev_s {
            Some(ps) if (sec - ps) as f64 <= MAX_SAMPLE_GAP_S => {
                let seg = out.last_mut().expect("segment exists");
                let fill = *seg.last().expect("non-empty");
                for _ in 1..(sec - ps) {
                    seg.push(fill);
                }
                seg.push(s);
            }
            _ => out.push(vec![s]),
        }
        prev_s = Some(sec);
    }
    out
}

/// Coggan zone (1..=7) for `watts` at `ftp` — same bands as the Dart `powerZone`.
pub fn power_zone(watts: f64, ftp: u32) -> usize {
    let pct = watts / f64::from(ftp.max(1)) * 100.0;
    match pct {
        p if p < 55.0 => 1,
        p if p < 76.0 => 2,
        p if p < 91.0 => 3,
        p if p < 106.0 => 4,
        p if p < 121.0 => 5,
        p if p < 151.0 => 6,
        _ => 7,
    }
}

/// Best average over any `window` consecutive samples of one segment.
fn best_window(seg: &[f64], window: usize) -> Option<f64> {
    if window == 0 || seg.len() < window {
        return None;
    }
    let mut sum: f64 = seg[..window].iter().sum();
    let mut best = sum;
    for i in window..seg.len() {
        sum += seg[i] - seg[i - window];
        best = best.max(sum);
    }
    Some(best / window as f64)
}

/// Mean-max power for `duration_s` across all segments.
pub fn mean_max(power_segments: &[Vec<f64>], duration_s: u32) -> Option<f64> {
    power_segments
        .iter()
        .filter_map(|s| best_window(s, duration_s as usize))
        .reduce(f64::max)
}

/// Normalized Power over the segments; `None` with no 30 s stretch.
pub fn normalized_power(power_segments: &[Vec<f64>]) -> Option<f64> {
    let mut sum4 = 0.0;
    let mut n = 0usize;
    for seg in power_segments {
        if seg.len() < NP_WINDOW_S {
            continue;
        }
        let mut sum: f64 = seg[..NP_WINDOW_S].iter().sum();
        sum4 += (sum / NP_WINDOW_S as f64).powi(4);
        n += 1;
        for i in NP_WINDOW_S..seg.len() {
            sum += seg[i] - seg[i - NP_WINDOW_S];
            sum4 += (sum.max(0.0) / NP_WINDOW_S as f64).powi(4);
            n += 1;
        }
    }
    (n > 0).then(|| (sum4 / n as f64).powf(0.25))
}

/// Bucket means so the series has at most `max` points.
fn downsample(xs: &[f64], max: usize) -> Vec<f64> {
    if xs.len() <= max || max == 0 {
        return xs.to_vec();
    }
    let per = xs.len().div_ceil(max);
    xs.chunks(per)
        .map(|c| c.iter().sum::<f64>() / c.len() as f64)
        .collect()
}

/// HR bucket means over readings only (0 when a bucket has none).
fn downsample_hr(hr: &[Option<u32>], max: usize) -> Vec<f64> {
    if hr.is_empty() {
        return Vec::new();
    }
    let per = hr.len().div_ceil(max.max(1)).max(1);
    hr.chunks(per)
        .map(|c| {
            let v: Vec<f64> = c.iter().flatten().map(|h| f64::from(*h)).collect();
            if v.is_empty() {
                0.0
            } else {
                v.iter().sum::<f64>() / v.len() as f64
            }
        })
        .collect()
}

/// Shortest effort that gets NP / IF / TSS, seconds.
pub const MIN_NP_S: usize = 60;

/// Summarise a ride. `ftp_w = 0` means unknown FTP (no IF / TSS / zones).
pub fn summarize(points: &[TrackPoint], ftp_w: u32) -> RideSummary {
    let segs = segments(points);
    let power: Vec<Vec<f64>> = segs
        .iter()
        .map(|s| s.iter().map(|x| x.power_w).collect())
        .collect();
    let all: Vec<&Sample> = segs.iter().flatten().collect();
    let n = all.len();
    let recorded_s = n as u32;

    let moving: Vec<f64> = all
        .iter()
        .filter(|s| s.power_w >= 1.0 || s.cadence_rpm >= 1.0)
        .map(|s| s.power_w)
        .collect();
    let avg_power_w = if moving.is_empty() {
        0.0
    } else {
        moving.iter().sum::<f64>() / moving.len() as f64
    };
    let max_power_w = all.iter().map(|s| s.power_w).fold(0.0, f64::max);
    let pedalling: Vec<f64> = all
        .iter()
        .map(|s| s.cadence_rpm)
        .filter(|c| *c >= 1.0)
        .collect();
    let avg_cadence_rpm = if pedalling.is_empty() {
        0.0
    } else {
        pedalling.iter().sum::<f64>() / pedalling.len() as f64
    };
    let max_cadence_rpm = pedalling.iter().copied().fold(0.0, f64::max);
    let hrs: Vec<u32> = all.iter().filter_map(|s| s.hr_bpm).collect();
    let avg_heart_rate_bpm = if hrs.is_empty() {
        0.0
    } else {
        hrs.iter().map(|h| f64::from(*h)).sum::<f64>() / hrs.len() as f64
    };
    let max_heart_rate_bpm = hrs.iter().copied().max().unwrap_or(0);

    // NP / IF / TSS need at least a minute of riding (ride-boundary checklist).
    let np_w = if n >= MIN_NP_S { normalized_power(&power) } else { None };
    let (intensity_factor, tss) = match (np_w, ftp_w) {
        (Some(np), f) if f > 0 => {
            let i = np / f64::from(f);
            (Some(i), Some(n as f64 / 3600.0 * i * i * 100.0))
        }
        _ => (None, None),
    };
    let time_in_zone_s = if ftp_w > 0 {
        let mut z = vec![0u32; 7];
        for s in &all {
            z[power_zone(s.power_w, ftp_w) - 1] += 1;
        }
        z
    } else {
        Vec::new()
    };
    let best_power: Vec<PowerBest> = BEST_DURATIONS_S
        .iter()
        .map(|&d| PowerBest {
            duration_s: d,
            watts: mean_max(&power, d),
        })
        .collect();
    let best_20min_w = mean_max(&power, 1200);
    let flat_p: Vec<f64> = all.iter().map(|s| s.power_w).collect();
    let flat_hr: Vec<Option<u32>> = all.iter().map(|s| s.hr_bpm).collect();
    RideSummary {
        recorded_s,
        ftp_w,
        avg_power_w,
        max_power_w,
        np_w,
        intensity_factor,
        tss,
        avg_cadence_rpm,
        max_cadence_rpm,
        avg_heart_rate_bpm,
        max_heart_rate_bpm,
        time_in_zone_s,
        best_power,
        best_20min_w,
        power_series: downsample(&flat_p, SUMMARY_SERIES_MAX),
        heart_rate_series: if hrs.is_empty() {
            Vec::new()
        } else {
            downsample_hr(&flat_hr, SUMMARY_SERIES_MAX)
        },
        is_demo: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: i64 = 1_760_000_000_000;

    /// One point per second from `watts`, starting `start_s` after T0.
    fn track_at(start_s: i64, watts: &[f64]) -> Vec<TrackPoint> {
        watts
            .iter()
            .enumerate()
            .map(|(i, &w)| TrackPoint {
                unix_ms: T0 + (start_s + i as i64) * 1000,
                power_w: w,
                cadence_rpm: if w > 0.0 { 90.0 } else { 0.0 },
                speed_kmh: 30.0,
                distance_m: 0.0,
                heart_rate_bpm: Some(140),
            })
            .collect()
    }

    fn track(watts: &[f64]) -> Vec<TrackPoint> {
        track_at(0, watts)
    }

    fn best(s: &RideSummary, d: u32) -> Option<f64> {
        s.best_power.iter().find(|b| b.duration_s == d).and_then(|b| b.watts)
    }

    #[test]
    fn fixture_constant_200w_one_hour_at_ftp_200() {
        let s = summarize(&track(&[200.0; 3600]), 200);
        assert_eq!(s.recorded_s, 3600);
        assert!((s.np_w.unwrap() - 200.0).abs() < 1e-9);
        assert!((s.intensity_factor.unwrap() - 1.0).abs() < 1e-12);
        assert!((s.tss.unwrap() - 100.0).abs() < 1e-9);
        assert_eq!(s.avg_power_w, 200.0);
        for d in BEST_DURATIONS_S {
            assert_eq!(best(&s, d), Some(200.0), "best {d}s");
        }
        assert_eq!(s.best_20min_w, Some(200.0));
        assert_eq!(s.time_in_zone_s, vec![0, 0, 0, 3600, 0, 0, 0]);
        assert_eq!(s.max_cadence_rpm, 90.0);
        assert_eq!(s.avg_heart_rate_bpm, 140.0);
        assert!(s.power_series.len() <= SUMMARY_SERIES_MAX);
        assert_eq!(s.power_series.len(), 600);
        assert!(s.power_series.iter().all(|p| *p == 200.0));
    }

    #[test]
    fn half_hour_100w_then_300w_matches_reference_np() {
        // Reference computed independently (Python, Coggan 30 s rolling mean):
        // NP = 252.8262 W; at FTP 250 → IF 1.011305, TSS 102.2737.
        let mut w = vec![100.0; 1800];
        w.extend(vec![300.0; 1800]);
        let s = summarize(&track(&w), 250);
        assert!((s.np_w.unwrap() - 252.8262).abs() < 1e-3, "{:?}", s.np_w);
        assert!((s.intensity_factor.unwrap() - 1.011305).abs() < 1e-5);
        assert!((s.tss.unwrap() - 102.2737).abs() < 1e-3);
        assert_eq!(s.avg_power_w, 200.0);
        assert_eq!(best(&s, 1200), Some(300.0));
        // Zones at FTP 250: 100 W = 40 % (Z1), 300 W = 120 % (Z5).
        assert_eq!(s.time_in_zone_s, vec![1800, 0, 0, 0, 1800, 0, 0]);
    }

    #[test]
    fn mean_max_known_efforts() {
        // 10 min at 100 W; minute 5 is 400 W with a 5 s 1000 W sprint inside it.
        let mut w = vec![100.0; 600];
        for x in &mut w[300..360] {
            *x = 400.0;
        }
        for x in &mut w[330..335] {
            *x = 1000.0;
        }
        let s = summarize(&track(&w), 0);
        assert_eq!(best(&s, 5), Some(1000.0));
        assert_eq!(best(&s, 60), Some(450.0)); // (55·400 + 5·1000) / 60
        assert_eq!(best(&s, 300), Some(170.0)); // (27000 + 240·100) / 300
        assert_eq!(best(&s, 1200), None);
        assert_eq!(s.best_20min_w, None);
        assert_eq!(s.max_power_w, 1000.0);
    }

    #[test]
    fn no_ftp_keeps_np_but_drops_if_tss_and_zones() {
        let s = summarize(&track(&[250.0; 120]), 0);
        assert!((s.np_w.unwrap() - 250.0).abs() < 1e-9);
        assert_eq!(s.intensity_factor, None);
        assert_eq!(s.tss, None);
        assert!(s.time_in_zone_s.is_empty());
    }

    #[test]
    fn under_30s_has_no_np() {
        let s = summarize(&track(&[300.0; 29]), 250);
        assert_eq!(s.np_w, None);
        assert_eq!(s.tss, None);
        assert_eq!(best(&s, 5), Some(300.0));
        assert_eq!(best(&s, 60), None);
        // Zones still count without NP.
        assert_eq!(s.time_in_zone_s[4], 29);
    }

    #[test]
    fn empty_track_is_all_blank() {
        let s = summarize(&[], 250);
        assert_eq!(s.recorded_s, 0);
        assert_eq!(s.np_w, None);
        assert!(s.best_power.iter().all(|b| b.watts.is_none()));
        assert!(s.power_series.is_empty());
        assert!(s.heart_rate_series.is_empty());
        assert_eq!(s.time_in_zone_s, vec![0; 7]);
    }

    #[test]
    fn windows_never_span_a_pause() {
        // Two 15 min blocks at 300 W separated by a 10 min pause (trainer off).
        let mut pts = track(&[300.0; 900]);
        pts.extend(track_at(900 + 600, &[300.0; 900]));
        let s = summarize(&pts, 300);
        assert_eq!(s.recorded_s, 1800, "pause is not ride time");
        assert_eq!(best(&s, 300), Some(300.0));
        assert_eq!(s.best_20min_w, None, "no unbroken 20 min");
        assert!((s.np_w.unwrap() - 300.0).abs() < 1e-9);
        assert!((s.tss.unwrap() - 50.0).abs() < 1e-9); // 0.5 h × 1² × 100
    }

    #[test]
    fn short_missed_tick_is_filled_not_split() {
        // 2 s gap (one missed tick) repeats the previous sample.
        let mut pts = track(&[200.0; 10]);
        pts.extend(track_at(11, &[200.0; 10]));
        let s = summarize(&pts, 200);
        assert_eq!(s.recorded_s, 21);
        // Duplicate / out-of-order timestamps are ignored.
        let mut dup = track(&[200.0; 10]);
        dup.push(dup[3].clone());
        assert_eq!(summarize(&dup, 200).recorded_s, 10);
    }

    #[test]
    fn junk_power_is_sanitised() {
        let s = summarize(&track(&[f64::NAN, -50.0, f64::INFINITY, 9000.0, 200.0]), 200);
        assert_eq!(s.max_power_w, 3000.0);
        assert!(s.power_series.iter().all(|p| p.is_finite() && *p >= 0.0));
    }

    #[test]
    fn hr_series_ignores_missing_readings() {
        let mut pts = track(&[200.0; 4]);
        pts[1].heart_rate_bpm = None;
        pts[2].heart_rate_bpm = Some(300); // implausible → dropped
        let s = summarize(&pts, 200);
        assert_eq!(s.heart_rate_series, vec![140.0, 0.0, 0.0, 140.0]);
        assert_eq!(s.max_heart_rate_bpm, 140);
        let none: Vec<TrackPoint> = track(&[200.0; 4])
            .into_iter()
            .map(|mut p| {
                p.heart_rate_bpm = None;
                p
            })
            .collect();
        assert!(summarize(&none, 200).heart_rate_series.is_empty());
    }

    #[test]
    fn long_ride_series_is_bounded_and_mean_preserving() {
        let w: Vec<f64> = (0..7213).map(|i| (i % 400) as f64).collect();
        let s = summarize(&track(&w), 250);
        assert!(s.power_series.len() <= SUMMARY_SERIES_MAX);
        assert!(s.power_series.len() > SUMMARY_SERIES_MAX / 2);
        assert_eq!(s.heart_rate_series.len(), s.power_series.len());
    }

    #[test]
    fn zones_match_dart_bands() {
        let ftp = 200;
        let cases = [(109.0, 1), (110.0, 2), (151.0, 2), (152.0, 3), (182.0, 4), (212.0, 5), (242.0, 6), (302.0, 7)];
        for (w, z) in cases {
            assert_eq!(power_zone(w, ftp), z, "{w} W");
        }
    }

    #[test]
    fn four_hz_input_uses_the_per_second_mean() {
        // 4 samples per second alternating 100/300 W: per-second mean 200 W.
        let pts: Vec<TrackPoint> = (0..3600 * 4)
            .map(|i| TrackPoint {
                unix_ms: T0 + i * 250,
                power_w: if i % 2 == 0 { 100.0 } else { 300.0 },
                cadence_rpm: 90.0,
                speed_kmh: 30.0,
                distance_m: 0.0,
                heart_rate_bpm: Some(if i % 2 == 0 { 140 } else { 142 }),
            })
            .collect();
        let s = summarize(&pts, 200);
        assert_eq!(s.recorded_s, 3600);
        assert!((s.np_w.unwrap() - 200.0).abs() < 1e-9, "{:?}", s.np_w);
        assert!((s.tss.unwrap() - 100.0).abs() < 1e-6);
        assert_eq!(best(&s, 5), Some(200.0));
        assert_eq!(s.avg_heart_rate_bpm, 141.0);
    }

    #[test]
    fn one_4hz_spike_is_clamped_and_averaged_not_dropped() {
        // 3 × 200 W + one 9000 W glitch in one second: clamped to 3000 W,
        // then that second's mean is (600 + 3000) / 4 = 900 W.
        let mut pts: Vec<TrackPoint> = (0..120 * 4)
            .map(|i| TrackPoint {
                unix_ms: T0 + i * 250,
                power_w: 200.0,
                cadence_rpm: 90.0,
                speed_kmh: 30.0,
                distance_m: 0.0,
                heart_rate_bpm: None,
            })
            .collect();
        pts[200].power_w = 9000.0;
        let s = summarize(&pts, 200);
        assert_eq!(s.max_power_w, 900.0);
        assert_eq!(s.recorded_s, 120);
    }
}

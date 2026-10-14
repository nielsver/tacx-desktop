//! Minimal reader for our own TCX exports (progress rebuild, step 4 S5).
//! No XML crate: we only need Lap StartTime, the lap DistanceMeters and
//! per-Trackpoint Time + Watts. Demo files are skipped.

use crate::trainer::ride::MAX_SAMPLE_GAP_S;
use std::path::Path;

/// What a saved ride contributes to progress.
#[derive(Clone, Debug, PartialEq)]
pub struct TcxRide {
    pub start_ms: i64,
    pub moving_s: u32,
    pub energy_kj: f64,
    pub distance_km: f64,
    pub file_name: String,
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `2026-10-07T14:56:40Z` (optional `.sss`) → ms since epoch.
pub fn parse_iso_utc(s: &str) -> Option<i64> {
    let s = s.trim().strip_suffix('Z')?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.split('-').map(|x| x.parse::<i64>().ok());
    let (y, mo, da) = (d.next()??, d.next()??, d.next()??);
    let mut t = time.split(':');
    let h: i64 = t.next()?.parse().ok()?;
    let mi: i64 = t.next()?.parse().ok()?;
    let sec: f64 = t.next()?.parse().ok()?;
    let days = days_from_civil(y, mo, da);
    Some(((days * 86_400 + h * 3600 + mi * 60) as f64 * 1000.0 + sec * 1000.0).round() as i64)
}

fn between<'a>(s: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let i = s.find(open)? + open.len();
    let j = s[i..].find(close)? + i;
    Some(&s[i..j])
}

pub fn is_demo(xml: &str) -> bool {
    xml.contains("<Notes>DEMO</Notes>")
}

/// Parse one TCX document; `None` for Demo or unreadable files.
pub fn parse(xml: &str, file_name: &str) -> Option<TcxRide> {
    if is_demo(xml) {
        return None;
    }
    let start_ms = parse_iso_utc(between(xml, "<Lap StartTime=\"", "\"")?)?;
    let lap = between(xml, "<Lap ", "<Track>")?;
    let dist: f64 = between(lap, "<DistanceMeters>", "</DistanceMeters>")?.parse().ok()?;
    let mut prev: Option<(i64, f64)> = None;
    let (mut ws, mut moving) = (0.0f64, 0.0f64);
    for tp in xml.split("<Trackpoint>").skip(1) {
        let Some(t) = between(tp, "<Time>", "</Time>").and_then(parse_iso_utc) else {
            continue;
        };
        let w: f64 = between(tp, "<ns3:Watts>", "</ns3:Watts>")
            .and_then(|x| x.parse().ok())
            .unwrap_or(0.0);
        if let Some((t0, _)) = prev {
            let dt = ((t - t0) as f64 / 1000.0).clamp(0.0, MAX_SAMPLE_GAP_S);
            if w >= 1.0 {
                ws += w * dt;
                moving += dt;
            }
        }
        prev = Some((t, w));
    }
    Some(TcxRide {
        start_ms,
        moving_s: moving.round() as u32,
        energy_kj: ws / 1000.0,
        distance_km: dist / 1000.0,
        file_name: file_name.into(),
    })
}

/// All non-demo `tacx-ride-*.tcx` in `dir`, oldest first.
pub fn scan_dir(dir: &Path) -> Vec<TcxRide> {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<TcxRide> = rd
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            if !name.starts_with("tacx-ride-") || !name.ends_with(".tcx") || name.contains("-demo") {
                return None;
            }
            let xml = std::fs::read_to_string(e.path()).ok()?;
            parse(&xml, &name)
        })
        .collect();
    out.sort_by_key(|r| r.start_ms);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trainer::progress::{apply, EffortInput, ProgressState};
    use crate::trainer::ride::{write_tcx_doc, RideRecorder, Tick};
    use crate::trainer::types::{EffortKind, TrainerMetrics};
    use std::time::{Duration, Instant};

    #[test]
    fn iso_round_trip() {
        let ms = 1_791_385_000_000;
        assert_eq!(parse_iso_utc(&crate::trainer::tcx::iso8601_utc(ms)), Some(ms));
    }

    /// Apply efforts live, export their TCX, rebuild from the folder: same
    /// ride days, XP and totals.
    #[test]
    fn recompute_matches_live_progress() {
        let dir = std::env::temp_dir().join(format!("tacx-tcx-read-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let day_of = |ms: i64| ms.div_euclid(86_400_000);
        let mut live = ProgressState::default();
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let w0: i64 = 1_791_385_000_000;
        // Three rides on three days (+ one Demo that must be skipped).
        for (n, (offset_days, secs, watts, demo)) in
            [(0i64, 1800u64, 200.0, false), (1, 3700, 150.0, false), (1, 900, 300.0, true), (3, 1200, 120.0, false)]
                .into_iter()
                .enumerate()
        {
            let base_s = (offset_days * 86_400 + n as i64 * 4000) as u64;
            let start = w0 + base_s as i64 * 1000;
            let id = r.begin_effort(EffortKind::free_ride(), demo, start);
            for i in 0..secs {
                let m = TrainerMetrics { power_w: watts, cadence_rpm: 90.0, speed_kmh: 30.0, ..Default::default() };
                r.tick(t0 + Duration::from_secs(base_s + i), start + i as i64 * 1000, Tick::Connected(m, demo));
            }
            r.tick(t0 + Duration::from_secs(base_s + secs), start + secs as i64 * 1000, Tick::Idle);
            let sl = r.end_effort(false, start + secs as i64 * 1000).unwrap();
            let st = r.effort_stats(id).unwrap();
            let day = day_of(sl.start_ms);
            apply(
                &mut live,
                &EffortInput {
                    uid: format!("{}-free-", sl.start_ms),
                    demo,
                    kind: "free".into(),
                    moving_s: st.moving_s,
                    energy_kj: st.energy_kj,
                    distance_km: st.distance_km,
                    local_date: format!("d{day}"),
                    day,
                    week: day.div_euclid(7),
                    ..Default::default()
                },
                2,
            );
            write_tcx_doc(&r.effort_tcx(id).unwrap(), sl.start_ms, demo, &dir).unwrap();
        }
        let rides = scan_dir(&dir);
        assert_eq!(rides.len(), 3, "demo skipped: {rides:?}");
        let mut rebuilt = ProgressState::default();
        for t in &rides {
            let day = day_of(t.start_ms);
            apply(
                &mut rebuilt,
                &EffortInput {
                    uid: format!("{}-tcx-", t.start_ms),
                    kind: "free".into(),
                    moving_s: t.moving_s,
                    energy_kj: t.energy_kj,
                    distance_km: t.distance_km,
                    local_date: format!("d{day}"),
                    day,
                    week: day.div_euclid(7),
                    ..Default::default()
                },
                2,
            );
        }
        assert_eq!(rebuilt.ride_days, live.ride_days);
        assert_eq!(rebuilt.xp, live.xp);
        assert_eq!(rebuilt.totals.efforts, live.totals.efforts);
        assert!((rebuilt.totals.km - live.totals.km).abs() < 0.01);
        assert!((rebuilt.totals.kj - live.totals.kj).abs() < 0.5);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

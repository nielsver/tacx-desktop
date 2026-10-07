//! Ride totals: elapsed / moving time, avg + max power, avg cadence, kJ, distance.
//!
//! A 1 Hz background ticker samples live metrics while a trainer is connected.
//! Gaps (reconnect, busy controller) are clamped so a stall never inflates
//! time or energy.

use crate::trainer::tcx::{self, LapSummary, TrackPoint};
use crate::trainer::types::{RideStats, TrainerMetrics};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Longest gap credited between two samples, seconds.
pub const MAX_SAMPLE_GAP_S: f64 = 2.0;

/// Track points kept for export (12 h at 1 Hz); totals keep counting past it.
pub const MAX_TRACK_POINTS: usize = 12 * 3600;

#[derive(Clone, Debug, Default)]
pub struct RideAccumulator {
    elapsed_s: f64,
    moving_s: f64,
    pedalling_s: f64,
    power_ws: f64,
    cadence_rs: f64,
    max_power_w: f64,
    max_speed_kmh: f64,
    distance_m: f64,
    hr_s: f64,
    hr_bs: f64,
    max_hr_bpm: u32,
    recording: bool,
}

impl RideAccumulator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Credit `dt_s` seconds at metrics `m` (dt clamped to [0, MAX_SAMPLE_GAP_S]).
    pub fn add_sample(&mut self, m: &TrainerMetrics, dt_s: f64) {
        self.recording = true;
        let dt = if dt_s.is_finite() { dt_s.clamp(0.0, MAX_SAMPLE_GAP_S) } else { 0.0 };
        if dt == 0.0 {
            return;
        }
        let p = sane(m.power_w, 3000.0);
        let c = sane(m.cadence_rpm, 250.0);
        let v = sane(m.speed_kmh, 120.0);
        self.elapsed_s += dt;
        if p >= 1.0 || c >= 1.0 {
            self.moving_s += dt;
            self.power_ws += p * dt;
        }
        if c >= 1.0 {
            self.pedalling_s += dt;
            self.cadence_rs += c * dt;
        }
        if p > self.max_power_w {
            self.max_power_w = p;
        }
        if v > self.max_speed_kmh {
            self.max_speed_kmh = v;
        }
        self.distance_m += v / 3.6 * dt;
        if let Some(hr) = m.heart_rate_bpm.filter(|h| (25..=250).contains(h)) {
            self.hr_s += dt;
            self.hr_bs += hr as f64 * dt;
            self.max_hr_bpm = self.max_hr_bpm.max(hr);
        }
    }

    pub fn set_recording(&mut self, on: bool) {
        self.recording = on;
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn distance_m(&self) -> f64 {
        self.distance_m
    }

    pub fn lap_summary(&self) -> LapSummary {
        let s = self.stats();
        LapSummary {
            total_time_s: self.elapsed_s,
            distance_m: self.distance_m,
            max_speed_kmh: self.max_speed_kmh,
            avg_power_w: s.avg_power_w,
            max_power_w: s.max_power_w,
            avg_cadence_rpm: s.avg_cadence_rpm,
            energy_kj: s.energy_kj,
            avg_heart_rate_bpm: s.avg_heart_rate_bpm,
            max_heart_rate_bpm: s.max_heart_rate_bpm,
        }
    }

    pub fn stats(&self) -> RideStats {
        RideStats {
            elapsed_s: self.elapsed_s.round() as u32,
            moving_s: self.moving_s.round() as u32,
            avg_power_w: if self.moving_s > 0.0 { self.power_ws / self.moving_s } else { 0.0 },
            max_power_w: self.max_power_w,
            avg_cadence_rpm: if self.pedalling_s > 0.0 {
                self.cadence_rs / self.pedalling_s
            } else {
                0.0
            },
            energy_kj: self.power_ws / 1000.0,
            distance_km: self.distance_m / 1000.0,
            avg_heart_rate_bpm: if self.hr_s > 0.0 { self.hr_bs / self.hr_s } else { 0.0 },
            max_heart_rate_bpm: self.max_hr_bpm,
            recording: self.recording,
        }
    }
}

fn sane(x: f64, max: f64) -> f64 {
    if x.is_finite() {
        x.clamp(0.0, max)
    } else {
        0.0
    }
}

/// What one ticker pass saw.
pub enum Tick {
    /// Connected: credit time since the previous connected tick.
    Connected(TrainerMetrics),
    /// Not connected (or reconnecting): pause, next sample starts fresh.
    Idle,
    /// Controller busy: skip without breaking the time chain.
    Busy,
}

#[derive(Default)]
pub struct RideRecorder {
    acc: RideAccumulator,
    last: Option<Instant>,
    points: Vec<TrackPoint>,
}

impl RideRecorder {
    /// `wall_ms` is the UTC wall clock (ms since epoch) used for export timestamps.
    pub fn tick(&mut self, now: Instant, wall_ms: i64, t: Tick) {
        match t {
            Tick::Connected(m) => {
                let dt = self
                    .last
                    .map(|l| now.saturating_duration_since(l).as_secs_f64())
                    .unwrap_or(0.0);
                self.acc.add_sample(&m, dt);
                self.last = Some(now);
                // One point per connected tick (the anchor too), strictly increasing time.
                let newer = self.points.last().is_none_or(|p| wall_ms / 1000 > p.unix_ms / 1000);
                if newer && self.points.len() < MAX_TRACK_POINTS {
                    self.points.push(TrackPoint {
                        unix_ms: wall_ms,
                        power_w: m.power_w,
                        cadence_rpm: m.cadence_rpm,
                        speed_kmh: m.speed_kmh,
                        distance_m: self.acc.distance_m(),
                        heart_rate_bpm: m.heart_rate_bpm,
                    });
                }
            }
            Tick::Idle => {
                self.last = None;
                self.acc.set_recording(false);
            }
            Tick::Busy => {}
        }
    }

    pub fn reset(&mut self) {
        let recording = self.acc.stats().recording;
        self.acc.reset();
        self.acc.set_recording(recording);
        self.points.clear();
    }

    pub fn stats(&self) -> RideStats {
        self.acc.stats()
    }

    pub fn point_count(&self) -> usize {
        self.points.len()
    }

    /// TCX document for the current ride, or `None` if nothing was recorded.
    pub fn to_tcx(&self) -> Option<String> {
        tcx::render(&self.points, &self.acc.lap_summary())
    }

    /// Wall-clock start of the ride (first point), ms since epoch.
    pub fn start_ms(&self) -> Option<i64> {
        self.points.first().map(|p| p.unix_ms)
    }
}

static RECORDER: Lazy<Mutex<RideRecorder>> = Lazy::new(|| Mutex::new(RideRecorder::default()));

fn wall_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn record(t: Tick) {
    RECORDER.lock().tick(Instant::now(), wall_ms(), t);
}

/// `~/Documents/Tacx Desktop` (Windows: `%USERPROFILE%\Documents\Tacx Desktop`),
/// falling back to the home directory, then the temp directory.
pub fn default_export_dir() -> PathBuf {
    let home = std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .or_else(|| std::env::var_os("USERPROFILE").filter(|h| !h.is_empty()))
        .map(PathBuf::from);
    match home {
        Some(h) => {
            let docs = h.join("Documents");
            if docs.is_dir() {
                docs.join("Tacx Desktop")
            } else {
                h.join("Tacx Desktop")
            }
        }
        None => std::env::temp_dir().join("Tacx Desktop"),
    }
}

/// Write `recorder`'s ride as `tacx-ride-<UTC stamp>.tcx` into `dir`.
pub fn write_tcx(recorder: &RideRecorder, dir: &Path) -> Result<PathBuf, String> {
    let doc = recorder
        .to_tcx()
        .ok_or_else(|| "Nothing recorded yet — connect a trainer and ride first.".to_string())?;
    std::fs::create_dir_all(dir)
        .map_err(|e| format!("Could not create {}: {e}", dir.display()))?;
    let stamp = tcx::file_stamp_utc(recorder.start_ms().unwrap_or_else(wall_ms));
    let mut path = dir.join(format!("tacx-ride-{stamp}.tcx"));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("tacx-ride-{stamp}-{n}.tcx"));
        n += 1;
    }
    std::fs::write(&path, doc).map_err(|e| format!("Could not write {}: {e}", path.display()))?;
    Ok(path)
}

/// Export the live ride; `dir = None` uses [`default_export_dir`].
pub fn export_tcx(dir: Option<&Path>) -> Result<PathBuf, String> {
    // Render under the lock, write outside it so the 1 Hz ticker never waits on disk.
    let snapshot = {
        let r = RECORDER.lock();
        RideRecorder {
            acc: r.acc.clone(),
            last: None,
            points: r.points.clone(),
        }
    };
    let dir = dir.map(Path::to_path_buf).unwrap_or_else(default_export_dir);
    write_tcx(&snapshot, &dir)
}

pub fn stats() -> RideStats {
    RECORDER.lock().stats()
}

/// Post-ride summary of the live recording (`ftp_w = 0`: unknown FTP).
/// Points are copied under the lock; the analysis runs outside it.
pub fn summary(ftp_w: u32) -> crate::trainer::types::RideSummary {
    let points = RECORDER.lock().points.clone();
    crate::trainer::summary::summarize(&points, ftp_w)
}

pub fn reset() {
    RECORDER.lock().reset();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn m(p: f64, c: f64, v: f64) -> TrainerMetrics {
        TrainerMetrics {
            power_w: p,
            cadence_rpm: c,
            speed_kmh: v,
            ..Default::default()
        }
    }

    #[test]
    fn steady_ride_totals() {
        let mut a = RideAccumulator::new();
        for _ in 0..600 {
            a.add_sample(&m(200.0, 90.0, 36.0), 1.0);
        }
        let s = a.stats();
        assert_eq!(s.elapsed_s, 600);
        assert_eq!(s.moving_s, 600);
        assert!((s.avg_power_w - 200.0).abs() < 1e-9);
        assert!((s.energy_kj - 120.0).abs() < 1e-9); // 200 W × 600 s
        assert!((s.distance_km - 6.0).abs() < 1e-9); // 36 km/h × 10 min
        assert!((s.avg_cadence_rpm - 90.0).abs() < 1e-9);
        assert_eq!(s.max_power_w, 200.0);
        assert!(s.recording);
    }

    #[test]
    fn heart_rate_average_and_max_skip_missing_readings() {
        let mut a = RideAccumulator::new();
        let hr = |bpm: Option<u32>| TrainerMetrics { heart_rate_bpm: bpm, ..m(200.0, 90.0, 30.0) };
        for _ in 0..30 {
            a.add_sample(&hr(Some(120)), 1.0);
        }
        for _ in 0..30 {
            a.add_sample(&hr(Some(160)), 1.0);
        }
        a.add_sample(&hr(None), 1.0); // strap dropped
        a.add_sample(&hr(Some(255)), 1.0); // garbage
        let s = a.stats();
        assert!((s.avg_heart_rate_bpm - 140.0).abs() < 1e-9);
        assert_eq!(s.max_heart_rate_bpm, 160);
        let lap = a.lap_summary();
        assert_eq!(lap.max_heart_rate_bpm, 160);
        assert_eq!(RideAccumulator::new().stats().max_heart_rate_bpm, 0);
    }

    #[test]
    fn coasting_counts_elapsed_not_moving() {
        let mut a = RideAccumulator::new();
        for _ in 0..60 {
            a.add_sample(&m(300.0, 100.0, 40.0), 1.0);
        }
        for _ in 0..60 {
            a.add_sample(&m(0.0, 0.0, 0.0), 1.0);
        }
        let s = a.stats();
        assert_eq!(s.elapsed_s, 120);
        assert_eq!(s.moving_s, 60);
        assert!((s.avg_power_w - 300.0).abs() < 1e-9);
        assert!((s.avg_cadence_rpm - 100.0).abs() < 1e-9);
        assert!((s.energy_kj - 18.0).abs() < 1e-9);
    }

    #[test]
    fn gaps_and_garbage_are_clamped() {
        let mut a = RideAccumulator::new();
        a.add_sample(&m(250.0, 90.0, 30.0), 45.0); // stall → 2 s credited
        a.add_sample(&m(f64::NAN, -5.0, f64::INFINITY), 1.0);
        a.add_sample(&m(99_999.0, 0.0, 0.0), 1.0); // clamp spike
        a.add_sample(&m(100.0, 80.0, 30.0), -1.0); // negative dt ignored
        let s = a.stats();
        assert_eq!(s.elapsed_s, 4);
        assert_eq!(s.max_power_w, 3000.0);
        assert!(s.energy_kj.is_finite() && s.distance_km.is_finite());
    }

    #[test]
    fn recorder_pauses_while_disconnected_and_resets() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let w0: i64 = 1_791_385_000_000;
        r.tick(t0, w0, Tick::Connected(m(200.0, 90.0, 30.0))); // anchor, dt 0
        r.tick(t0 + Duration::from_secs(1), w0 + 1_000, Tick::Connected(m(200.0, 90.0, 30.0)));
        r.tick(t0 + Duration::from_secs(2), w0 + 2_000, Tick::Busy);
        r.tick(t0 + Duration::from_secs(3), w0 + 3_000, Tick::Connected(m(200.0, 90.0, 30.0))); // 2 s (clamped)
        assert_eq!(r.stats().elapsed_s, 3);
        r.tick(t0 + Duration::from_secs(4), w0 + 4_000, Tick::Idle);
        assert!(!r.stats().recording);
        // 60 s offline (reconnecting) is not credited.
        r.tick(t0 + Duration::from_secs(64), w0 + 64_000, Tick::Connected(m(200.0, 90.0, 30.0)));
        r.tick(t0 + Duration::from_secs(65), w0 + 65_000, Tick::Connected(m(200.0, 90.0, 30.0)));
        let s = r.stats();
        assert_eq!(s.elapsed_s, 4);
        assert!(s.recording);
        assert!((s.energy_kj - 0.8).abs() < 1e-9);
        r.reset();
        let s = r.stats();
        assert_eq!(s.elapsed_s, 0);
        assert_eq!(s.energy_kj, 0.0);
        assert!(s.recording, "reset keeps recording state");
    }

    #[test]
    fn recorder_keeps_track_points_and_exports_tcx() {
        let mut r = RideRecorder::default();
        assert!(r.to_tcx().is_none());
        let t0 = Instant::now();
        let w0: i64 = 1_791_385_000_000;
        for i in 0..5u64 {
            r.tick(
                t0 + Duration::from_secs(i),
                w0 + i as i64 * 1000,
                Tick::Connected(m(200.0, 90.0, 36.0)),
            );
        }
        // Same wall second twice → no duplicate point.
        r.tick(t0 + Duration::from_millis(4500), w0 + 4500, Tick::Busy);
        assert_eq!(r.point_count(), 5);
        r.tick(t0 + Duration::from_secs(6), w0 + 6000, Tick::Idle);
        assert_eq!(r.point_count(), 5, "idle adds no points");
        let x = r.to_tcx().unwrap();
        assert_eq!(x.matches("<Trackpoint>").count(), 5);
        assert!(x.contains("<TotalTimeSeconds>4.0</TotalTimeSeconds>"));
        assert!(x.contains("<DistanceMeters>40.0</DistanceMeters>"));
        assert!(x.contains("<Time>2026-10-07T14:56:44Z</Time>"));

        let dir = std::env::temp_dir().join(format!("tacx-tcx-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let p1 = write_tcx(&r, &dir).unwrap();
        assert_eq!(p1.file_name().unwrap(), "tacx-ride-20261007-145640Z.tcx");
        let p2 = write_tcx(&r, &dir).unwrap();
        assert_eq!(p2.file_name().unwrap(), "tacx-ride-20261007-145640Z-2.tcx");
        assert_eq!(std::fs::read_to_string(&p1).unwrap(), x);
        let _ = std::fs::remove_dir_all(&dir);

        r.reset();
        assert_eq!(r.point_count(), 0);
        assert!(write_tcx(&r, &std::env::temp_dir()).is_err());
    }

    #[test]
    fn default_export_dir_is_named() {
        assert!(default_export_dir().ends_with("Tacx Desktop"));
    }
}

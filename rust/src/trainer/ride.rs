//! Ride totals: elapsed / moving time, avg + max power, avg cadence, kJ, distance.
//!
//! A 1 Hz background ticker samples live metrics while a trainer is connected.
//! Gaps (reconnect, busy controller) are clamped so a stall never inflates
//! time or energy.

use crate::trainer::tcx::{self, LapSummary, TrackPoint};
use crate::trainer::types::{
    EffortKind, EffortType, EndReason, RideEvent, RideEventKind, RideSlice, RideStats, RideSummary, TrainerMetrics,
};
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
    /// Connected: credit time since the previous connected tick. The flag
    /// says whether the source is the Demo trainer (synthetic data).
    Connected(TrainerMetrics, bool),
    /// Not connected (or reconnecting): pause, next sample starts fresh.
    Idle,
    /// Controller busy: skip without breaking the time chain.
    Busy,
}

/// An Idle streak longer than this ends the open effort.
pub const EFFORT_IDLE_TIMEOUT_S: f64 = 60.0;

#[derive(Clone, Debug)]
struct Effort {
    id: u32,
    kind: EffortKind,
    demo: bool,
    first: usize,
    end: Option<usize>,
    start_ms: i64,
    end_ms: i64,
    acc: RideAccumulator,
    paused_s: f64,
    completed: bool,
    reason: Option<EndReason>,
}

/// Session recorder. Points are pushed once; efforts are index ranges into
/// them (no copying). Points outside efforts only feed the live view and
/// session totals; they are never summarised or exported.
#[derive(Default)]
pub struct RideRecorder {
    acc: RideAccumulator,
    last: Option<Instant>,
    points: Vec<TrackPoint>,
    efforts: Vec<Effort>,
    next_id: u32,
    paused: bool,
    idle_since: Option<Instant>,
    /// Events raised under the lock, delivered after it is released.
    events: Vec<RideEvent>,
    /// No auto free ride before this wall time (QA c6 P1-A): pedalling on
    /// after Stop / finish must not open a micro ride that steals the UI.
    no_auto_until_ms: i64,
    /// Last wall time the open effort saw ≥ 1 W.
    last_power_ms: i64,
    /// Route / workout the controller is running (P2-1): when no effort is
    /// open (e.g. after a > 60 s dropout) it is re-begun as that kind.
    active: Option<EffortKind>,
    /// `LinkLost` raised for the open route / workout (once per dropout).
    link_lost: bool,
}

/// A route / workout with no trainer this long is closed as `Abandoned`.
pub const LINK_ABANDON_S: f64 = 30.0 * 60.0;

/// Auto free rides are suppressed this long after any effort closes.
pub const AUTO_BEGIN_COOLDOWN_MS: i64 = 5_000;
/// An auto free ride with almost no riding closes after this much 0 W.
pub const BLIP_IDLE_MS: i64 = 60_000;
/// "Almost no riding" for the blip rule.
pub const BLIP_MAX_MOVING_S: u32 = 10;

impl RideRecorder {
    /// `wall_ms` is the UTC wall clock (ms since epoch) used for export timestamps.
    pub fn tick(&mut self, now: Instant, wall_ms: i64, t: Tick) {
        match t {
            Tick::Connected(m, demo) => {
                self.idle_since = None;
                if std::mem::take(&mut self.link_lost) {
                    if let Some(sl) = self.current_effort() {
                        self.events.push(RideEvent::link(RideEventKind::LinkRestored, &sl));
                    }
                }
                let dt = self
                    .last
                    .map(|l| now.saturating_duration_since(l).as_secs_f64())
                    .unwrap_or(0.0);
                self.last = Some(now);
                if self.paused {
                    if let Some(e) = self.open_mut() {
                        e.paused_s += dt.clamp(0.0, MAX_SAMPLE_GAP_S);
                        e.end_ms = wall_ms;
                    }
                    return;
                }
                let pedalling = sane(m.power_w, 3000.0) >= 1.0;
                if self.open().is_none() {
                    if let Some(kind) = self.active.clone() {
                        // A running route / workout without an open effort (e.g.
                        // after Abandoned): begin it again, never a FreeRide.
                        self.begin_at(kind, demo, wall_ms);
                    } else if pedalling && wall_ms >= self.no_auto_until_ms {
                        self.begin_at(EffortKind::free_ride(), demo, wall_ms);
                    }
                }
                if pedalling {
                    self.last_power_ms = wall_ms;
                } else if let Some(e) = self.open() {
                    // A ≥ 1 W blip must not leave a free ride open forever.
                    if e.kind == EffortKind::free_ride()
                        && e.acc.stats().moving_s <= BLIP_MAX_MOVING_S
                        && wall_ms - self.last_power_ms.max(e.start_ms) > BLIP_IDLE_MS
                    {
                        self.close(false, EndReason::Stopped, wall_ms);
                    }
                }
                self.acc.add_sample(&m, dt);
                let newer = self.points.last().is_none_or(|p| wall_ms / 1000 > p.unix_ms / 1000);
                let pushed = newer && self.points.len() < MAX_TRACK_POINTS;
                if let Some(e) = self.open_mut() {
                    // The effort's first sample is its anchor (no time credited).
                    let edt = if e.acc.stats().recording { dt } else { 0.0 };
                    e.acc.add_sample(&m, edt);
                    e.end_ms = wall_ms;
                }
                if pushed {
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
                let since = *self.idle_since.get_or_insert(now);
                let idle_s = now.saturating_duration_since(since).as_secs_f64();
                match self.open().map(|e| e.kind.kind) {
                    // Free ride: a long dropout ends it (link-lost summary).
                    Some(EffortType::FreeRide) if idle_s > EFFORT_IDLE_TIMEOUT_S => {
                        self.close(false, EndReason::DisconnectTimeout, wall_ms);
                    }
                    // Route / workout: a dropout is never an end (QA c8 P1-C).
                    Some(_) if idle_s > LINK_ABANDON_S => {
                        self.link_lost = false;
                        self.close(false, EndReason::Abandoned, wall_ms);
                    }
                    Some(_) if idle_s > EFFORT_IDLE_TIMEOUT_S && !self.link_lost => {
                        self.link_lost = true;
                        if let Some(sl) = self.current_effort() {
                            self.events.push(RideEvent::link(RideEventKind::LinkLost, &sl));
                        }
                    }
                    _ => {}
                }
            }
            Tick::Busy => {}
        }
    }

    fn open(&self) -> Option<&Effort> {
        self.efforts.last().filter(|e| e.end.is_none())
    }

    fn open_mut(&mut self) -> Option<&mut Effort> {
        self.efforts.last_mut().filter(|e| e.end.is_none())
    }

    fn begin_at(&mut self, kind: EffortKind, demo: bool, wall_ms: i64) -> u32 {
        if let Some(e) = self.open() {
            if e.kind == kind {
                return e.id;
            }
            self.close(false, EndReason::Superseded, wall_ms);
        }
        self.next_id += 1;
        self.efforts.push(Effort {
            id: self.next_id,
            kind,
            demo,
            first: self.points.len(),
            end: None,
            start_ms: wall_ms,
            end_ms: wall_ms,
            acc: RideAccumulator::default(),
            paused_s: 0.0,
            completed: false,
            reason: None,
        });
        self.next_id
    }

    /// Open an effort (idempotent for the same kind; a different kind
    /// supersedes the open one). `demo` is captured here.
    pub fn begin_effort(&mut self, kind: EffortKind, demo: bool, wall_ms: i64) -> u32 {
        self.begin_at(kind, demo, wall_ms)
    }

    fn close(&mut self, completed: bool, reason: EndReason, wall_ms: i64) -> Option<RideSlice> {
        let end = self.points.len();
        let e = self.open_mut()?;
        e.end = Some(end);
        e.end_ms = e.end_ms.max(wall_ms);
        e.completed = completed;
        e.reason = Some(reason);
        let id = e.id;
        self.no_auto_until_ms = wall_ms + AUTO_BEGIN_COOLDOWN_MS;
        let sl = self.slice(id)?;
        self.events.push(RideEvent::ride_ended(&sl));
        Some(sl)
    }

    /// Close the open effort (`Completed` or `Stopped`) and raise one
    /// `RideEnded`. With none open, returns the last closed slice, no event.
    pub fn end_effort(&mut self, completed: bool, wall_ms: i64) -> Option<RideSlice> {
        if self.open().is_some() {
            self.link_lost = false;
            let reason = if completed { EndReason::Completed } else { EndReason::Stopped };
            return self.close(completed, reason, wall_ms);
        }
        self.efforts.last().and_then(|e| self.slice(e.id))
    }

    /// What the controller is running right now (None: nothing).
    pub fn set_active(&mut self, kind: Option<EffortKind>) {
        self.active = kind;
    }

    pub fn set_paused(&mut self, paused: bool) {
        self.paused = paused;
    }

    fn effort(&self, id: u32) -> Option<&Effort> {
        self.efforts.iter().find(|e| e.id == id)
    }

    pub fn slice(&self, id: u32) -> Option<RideSlice> {
        let e = self.effort(id)?;
        let s = e.acc.stats();
        Some(RideSlice {
            id: e.id,
            kind: e.kind.clone(),
            demo: e.demo,
            start_ms: e.start_ms,
            end_ms: e.end_ms,
            first: e.first as u32,
            end: e.end.unwrap_or(self.points.len()) as u32,
            moving_s: s.moving_s,
            paused_s: e.paused_s.round() as u32,
            completed: e.completed,
            end_reason: e.reason,
        })
    }

    pub fn current_effort(&self) -> Option<RideSlice> {
        self.open().and_then(|e| self.slice(e.id))
    }

    pub fn list_efforts(&self) -> Vec<RideSlice> {
        self.efforts.iter().filter_map(|e| self.slice(e.id)).collect()
    }

    pub fn latest_id(&self) -> Option<u32> {
        self.efforts.last().map(|e| e.id)
    }

    fn range(&self, e: &Effort) -> &[TrackPoint] {
        let end = e.end.unwrap_or(self.points.len()).min(self.points.len());
        &self.points[e.first.min(end)..end]
    }

    /// Points of an effort (borrowed, no copy).
    pub fn effort_points(&self, id: u32) -> Option<&[TrackPoint]> {
        self.effort(id).map(|e| self.range(e))
    }

    pub fn effort_stats(&self, id: u32) -> Option<RideStats> {
        self.effort(id).map(|e| e.acc.stats())
    }

    pub fn effort_summary(&self, id: u32, ftp_w: u32) -> Option<RideSummary> {
        let e = self.effort(id)?;
        let mut s = crate::trainer::summary::summarize(self.range(e), ftp_w);
        s.is_demo = e.demo;
        Some(s)
    }

    /// TCX for one effort: Lap StartTime = effort start, distance from 0,
    /// `<Notes>DEMO</Notes>` on Demo efforts.
    pub fn effort_tcx(&self, id: u32) -> Option<String> {
        let e = self.effort(id)?;
        let pts = self.range(e);
        let base = pts.first()?.distance_m;
        let pts: Vec<TrackPoint> = pts
            .iter()
            .map(|p| TrackPoint { distance_m: p.distance_m - base, ..p.clone() })
            .collect();
        tcx::render(&pts, &e.acc.lap_summary(), e.start_ms, e.demo)
    }

    /// Ends the open effort, then clears the session.
    pub fn reset(&mut self, wall_ms: i64) {
        self.end_effort(false, wall_ms);
        let recording = self.acc.stats().recording;
        self.acc.reset();
        self.acc.set_recording(recording);
        self.points.clear();
        self.efforts.clear();
    }

    pub fn stats(&self) -> RideStats {
        self.acc.stats()
    }

    pub fn point_count(&self) -> usize {
        self.points.len()
    }

    /// TCX of the whole session (fallback when no effort exists).
    pub fn session_tcx(&self) -> Option<String> {
        let start = self.points.first()?.unix_ms;
        tcx::render(&self.points, &self.acc.lap_summary(), start, false)
    }

    fn take_events(&mut self) -> Vec<RideEvent> {
        std::mem::take(&mut self.events)
    }
}

static RECORDER: Lazy<Mutex<RideRecorder>> = Lazy::new(|| Mutex::new(RideRecorder::default()));

type RideEventHook = Box<dyn Fn(&RideEvent) + Send + Sync>;
static RIDE_EVENT_HOOKS: Lazy<Mutex<Vec<RideEventHook>>> = Lazy::new(|| Mutex::new(Vec::new()));

/// Subscribe to recorder events (the FRB `ride_events` stream uses this;
/// step 5's remote End & Save will too).
pub fn on_ride_event(f: impl Fn(&RideEvent) + Send + Sync + 'static) {
    RIDE_EVENT_HOOKS.lock().push(Box::new(f));
}

/// Deliver an event to every subscriber (outside the recorder lock).
pub fn emit(ev: RideEvent) {
    for h in RIDE_EVENT_HOOKS.lock().iter() {
        h(&ev);
    }
}

/// Run `f` under the recorder lock, then deliver its events outside it.
fn with_recorder<T>(f: impl FnOnce(&mut RideRecorder) -> T) -> T {
    let (out, events) = {
        let mut r = RECORDER.lock();
        let out = f(&mut r);
        (out, r.take_events())
    };
    if !events.is_empty() {
        let hooks = RIDE_EVENT_HOOKS.lock();
        for ev in &events {
            for h in hooks.iter() {
                h(ev);
            }
        }
    }
    out
}

fn wall_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn record(t: Tick) {
    with_recorder(|r| r.tick(Instant::now(), wall_ms(), t));
}

/// Ticker entry: `active` = the route / workout the controller is running.
pub fn record_with(t: Tick, active: Option<EffortKind>) {
    with_recorder(|r| {
        r.set_active(active);
        r.tick(Instant::now(), wall_ms(), t)
    });
}

pub fn begin_effort(kind: EffortKind, demo: bool) -> u32 {
    with_recorder(|r| r.begin_effort(kind, demo, wall_ms()))
}

pub fn end_effort(completed: bool) -> Option<RideSlice> {
    with_recorder(|r| r.end_effort(completed, wall_ms()))
}

pub fn current_effort() -> Option<RideSlice> {
    RECORDER.lock().current_effort()
}

pub fn list_efforts() -> Vec<RideSlice> {
    RECORDER.lock().list_efforts()
}

pub fn effort(id: u32) -> Option<RideSlice> {
    RECORDER.lock().slice(id)
}

/// Copy of effort `id`'s points (for analysis outside the lock).
pub fn effort_points_copy(id: u32) -> Option<Vec<TrackPoint>> {
    RECORDER.lock().effort_points(id).map(<[TrackPoint]>::to_vec)
}

pub fn effort_stats(id: u32) -> Option<RideStats> {
    RECORDER.lock().effort_stats(id)
}

pub fn set_paused(paused: bool) {
    RECORDER.lock().set_paused(paused);
}

/// Summary of effort `id`; points are copied under the lock, analysed outside.
pub fn effort_summary(id: u32, ftp_w: u32) -> Option<RideSummary> {
    let (pts, demo) = {
        let r = RECORDER.lock();
        let e = r.effort(id)?;
        (r.range(e).to_vec(), e.demo)
    };
    let mut s = crate::trainer::summary::summarize(&pts, ftp_w);
    s.is_demo = demo;
    Some(s)
}

/// Latest effort's summary, or the whole session when there is none.
pub fn summary(ftp_w: u32) -> RideSummary {
    let latest = RECORDER.lock().latest_id();
    match latest.and_then(|id| effort_summary(id, ftp_w)) {
        Some(s) => s,
        None => {
            let pts = RECORDER.lock().points.clone();
            crate::trainer::summary::summarize(&pts, ftp_w)
        }
    }
}

/// Write `doc` as `tacx-ride-<UTC stamp>[-demo].tcx` into `dir` (never
/// overwrites: `-2`, `-3`, …).
pub fn write_tcx_doc(doc: &str, start_ms: i64, demo: bool, dir: &Path) -> Result<PathBuf, String> {
    std::fs::create_dir_all(dir)
        .map_err(|e| format!("Could not create {}: {e}", dir.display()))?;
    let stamp = tcx::file_stamp_utc(start_ms);
    let tag = if demo { "-demo" } else { "" };
    let mut path = dir.join(format!("tacx-ride-{stamp}{tag}.tcx"));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("tacx-ride-{stamp}{tag}-{n}.tcx"));
        n += 1;
    }
    std::fs::write(&path, doc).map_err(|e| format!("Could not write {}: {e}", path.display()))?;
    Ok(path)
}

const NOTHING: &str = "Nothing recorded yet — connect a trainer and ride first.";

/// Export effort `id`; render under the lock, write outside it.
pub fn export_effort_tcx(id: u32, dir: Option<&Path>) -> Result<PathBuf, String> {
    let (doc, start, demo) = {
        let r = RECORDER.lock();
        let e = r.effort(id).ok_or_else(|| format!("No ride #{id} in this session."))?;
        (r.effort_tcx(id).ok_or_else(|| NOTHING.to_string())?, e.start_ms, e.demo)
    };
    let dir = dir.map(Path::to_path_buf).unwrap_or_else(default_export_dir);
    write_tcx_doc(&doc, start, demo, &dir)
}

/// Export the latest effort (whole session when there is none).
pub fn export_tcx(dir: Option<&Path>) -> Result<PathBuf, String> {
    let latest = RECORDER.lock().latest_id();
    if let Some(id) = latest {
        return export_effort_tcx(id, dir);
    }
    let (doc, start) = {
        let r = RECORDER.lock();
        let doc = r.session_tcx().ok_or_else(|| NOTHING.to_string())?;
        (doc, r.points[0].unix_ms)
    };
    let dir = dir.map(Path::to_path_buf).unwrap_or_else(default_export_dir);
    write_tcx_doc(&doc, start, false, &dir)
}

pub fn stats() -> RideStats {
    RECORDER.lock().stats()
}

pub fn reset() {
    with_recorder(|r| r.reset(wall_ms()));
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
        r.tick(t0, w0, Tick::Connected(m(200.0, 90.0, 30.0), false)); // anchor, dt 0
        r.tick(t0 + Duration::from_secs(1), w0 + 1_000, Tick::Connected(m(200.0, 90.0, 30.0), false));
        r.tick(t0 + Duration::from_secs(2), w0 + 2_000, Tick::Busy);
        r.tick(t0 + Duration::from_secs(3), w0 + 3_000, Tick::Connected(m(200.0, 90.0, 30.0), false)); // 2 s (clamped)
        assert_eq!(r.stats().elapsed_s, 3);
        r.tick(t0 + Duration::from_secs(4), w0 + 4_000, Tick::Idle);
        assert!(!r.stats().recording);
        // 60 s offline (reconnecting) is not credited.
        r.tick(t0 + Duration::from_secs(64), w0 + 64_000, Tick::Connected(m(200.0, 90.0, 30.0), false));
        r.tick(t0 + Duration::from_secs(65), w0 + 65_000, Tick::Connected(m(200.0, 90.0, 30.0), false));
        let s = r.stats();
        assert_eq!(s.elapsed_s, 4);
        assert!(s.recording);
        assert!((s.energy_kj - 0.8).abs() < 1e-9);
        r.reset(W0);
        let s = r.stats();
        assert_eq!(s.elapsed_s, 0);
        assert_eq!(s.energy_kj, 0.0);
        assert!(s.recording, "reset keeps recording state");
    }

    const W0: i64 = 1_791_385_000_000;

    /// `secs` connected ticks at `p` W starting at second `from`.
    fn ride(r: &mut RideRecorder, t0: Instant, from: u64, secs: u64, p: f64, demo: bool) {
        for i in from..from + secs {
            r.tick(
                t0 + Duration::from_secs(i),
                W0 + i as i64 * 1000,
                Tick::Connected(m(p, if p > 0.0 { 90.0 } else { 0.0 }, 36.0), demo),
            );
        }
    }

    fn idle(r: &mut RideRecorder, t0: Instant, from: u64, secs: u64) {
        for i in from..from + secs {
            r.tick(t0 + Duration::from_secs(i), W0 + i as i64 * 1000, Tick::Idle);
        }
    }

    fn at(s: u64) -> i64 {
        W0 + s as i64 * 1000
    }

    fn route() -> EffortKind {
        EffortKind::route("v2-abc")
    }

    #[test]
    fn recorder_keeps_track_points_and_exports_tcx() {
        let mut r = RideRecorder::default();
        assert!(r.latest_id().is_none());
        let t0 = Instant::now();
        ride(&mut r, t0, 0, 5, 200.0, false); // auto-begins a FreeRide
        // Same wall second twice → no duplicate point.
        r.tick(t0 + Duration::from_millis(4500), W0 + 4500, Tick::Busy);
        assert_eq!(r.point_count(), 5);
        r.tick(t0 + Duration::from_secs(6), W0 + 6000, Tick::Idle);
        assert_eq!(r.point_count(), 5, "idle adds no points");
        let id = r.latest_id().unwrap();
        let x = r.effort_tcx(id).unwrap();
        assert_eq!(x.matches("<Trackpoint>").count(), 5);
        assert!(x.contains("<TotalTimeSeconds>4.0</TotalTimeSeconds>"));
        assert!(x.contains("<DistanceMeters>40.0</DistanceMeters>"));
        assert!(x.contains("<Time>2026-10-07T14:56:44Z</Time>"));
        assert!(!x.contains("<Notes>"));

        let dir = std::env::temp_dir().join(format!("tacx-tcx-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let p1 = write_tcx_doc(&x, W0, false, &dir).unwrap();
        assert_eq!(p1.file_name().unwrap(), "tacx-ride-20261007-145640Z.tcx");
        let p2 = write_tcx_doc(&x, W0, false, &dir).unwrap();
        assert_eq!(p2.file_name().unwrap(), "tacx-ride-20261007-145640Z-2.tcx");
        let p3 = write_tcx_doc(&x, W0, true, &dir).unwrap();
        assert_eq!(p3.file_name().unwrap(), "tacx-ride-20261007-145640Z-demo.tcx");
        assert_eq!(std::fs::read_to_string(&p1).unwrap(), x);
        let _ = std::fs::remove_dir_all(&dir);

        r.reset(at(7));
        assert_eq!(r.point_count(), 0);
        assert!(r.latest_id().is_none());
    }

    #[test]
    fn idle_before_start_is_excluded_and_lap_starts_at_begin() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        ride(&mut r, t0, 0, 300, 0.0, false); // connected, not pedalling
        assert!(r.latest_id().is_none(), "0 W never auto-begins");
        let id = r.begin_effort(route(), false, at(300));
        ride(&mut r, t0, 300, 600, 200.0, false);
        let s = r.effort_summary(id, 200).unwrap();
        assert!((s.np_w.unwrap() - 200.0).abs() < 1e-6);
        assert_eq!(r.effort_points(id).unwrap().len(), 600);
        let x = r.effort_tcx(id).unwrap();
        assert_eq!(x.matches("<Trackpoint>").count(), 600);
        // Lap StartTime and first Trackpoint = begin (14:56:40 + 300 s).
        assert!(x.contains("<Lap StartTime=\"2026-10-07T15:01:40Z\">"));
        let first_time = x.split("<Time>").nth(1).unwrap();
        assert!(first_time.starts_with("2026-10-07T15:01:40Z"));
    }

    #[test]
    fn two_efforts_are_disjoint_and_default_is_latest() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let a = r.begin_effort(route(), false, at(0));
        ride(&mut r, t0, 0, 30, 150.0, false);
        r.end_effort(true, at(30));
        let b = r.begin_effort(EffortKind::workout("sweet"), false, at(30));
        ride(&mut r, t0, 30, 20, 250.0, false);
        assert_eq!((a, b), (1, 2));
        let l = r.list_efforts();
        assert_eq!(l.len(), 2);
        assert!(l[0].end <= l[1].first, "disjoint ranges");
        assert_eq!(r.latest_id(), Some(2));
        assert_eq!(r.effort_summary(2, 0).unwrap().recorded_s, 20);
        assert_eq!(r.effort_summary(1, 0).unwrap().recorded_s, 30);
    }

    #[test]
    fn demo_effort_is_marked_and_flag_is_fixed_at_begin() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let id = r.begin_effort(route(), true, at(0));
        ride(&mut r, t0, 0, 5, 200.0, true);
        ride(&mut r, t0, 5, 5, 200.0, false); // source flips mid-effort
        let sl = r.slice(id).unwrap();
        assert!(sl.demo);
        let x = r.effort_tcx(id).unwrap();
        let i = |k: &str| x.find(k).unwrap();
        assert!(i("</Track>") < i("<Notes>DEMO</Notes>"));
        assert!(i("<Notes>DEMO</Notes>") < i("</Lap>"));
        assert!(r.effort_summary(id, 0).unwrap().is_demo);
    }

    #[test]
    fn stop_before_a_minute_has_no_np() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let id = r.begin_effort(EffortKind::free_ride(), false, at(0));
        ride(&mut r, t0, 0, 45, 180.0, false);
        r.end_effort(false, at(45));
        let s = r.effort_summary(id, 200).unwrap();
        assert!(s.np_w.is_none() && s.tss.is_none() && s.intensity_factor.is_none());
        assert!((s.avg_power_w - 180.0).abs() < 1e-9);
        assert_eq!(s.recorded_s, 45);
    }

    #[test]
    fn disconnect_keeps_effort_under_60s_and_ends_it_after() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let id = r.begin_effort(EffortKind::free_ride(), false, at(0));
        ride(&mut r, t0, 0, 30, 200.0, false);
        idle(&mut r, t0, 30, 20);
        ride(&mut r, t0, 50, 30, 200.0, false);
        let sl = r.current_effort().expect("still open");
        assert_eq!(sl.id, id);
        assert_eq!(sl.moving_s, 58, "the 20 s gap is not credited");
        assert!(r.take_events().is_empty());
        idle(&mut r, t0, 80, 62);
        assert!(r.current_effort().is_none());
        let sl = r.slice(id).unwrap();
        assert_eq!(sl.end_reason, Some(EndReason::DisconnectTimeout));
        assert!(!sl.completed);
        assert_eq!(r.take_events(), vec![RideEvent::ride_ended(&r.slice(id).unwrap())]);
    }

    #[test]
    fn begin_and_end_are_idempotent_with_one_event() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let a = r.begin_effort(route(), false, at(0));
        assert_eq!(r.begin_effort(route(), false, at(1)), a);
        ride(&mut r, t0, 0, 10, 200.0, false);
        let s1 = r.end_effort(true, at(10)).unwrap();
        let s2 = r.end_effort(true, at(11)).unwrap();
        assert_eq!(s1.id, s2.id);
        assert_eq!(s1.end_reason, Some(EndReason::Completed));
        assert_eq!(r.take_events(), vec![RideEvent::ride_ended(&r.slice(a).unwrap())]);
    }

    #[test]
    fn pause_is_excluded_from_moving_time_and_np() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let id = r.begin_effort(EffortKind::free_ride(), false, at(0));
        ride(&mut r, t0, 0, 301, 200.0, false);
        r.set_paused(true);
        ride(&mut r, t0, 301, 120, 0.0, false);
        r.set_paused(false);
        ride(&mut r, t0, 421, 300, 200.0, false);
        let sl = r.slice(id).unwrap();
        assert_eq!(sl.moving_s, 600);
        assert_eq!(sl.paused_s, 120);
        let s = r.effort_summary(id, 200).unwrap();
        assert!((s.np_w.unwrap() - 200.0).abs() < 1e-6);
    }

    #[test]
    fn auto_free_ride_then_superseded_by_route() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        ride(&mut r, t0, 0, 10, 150.0, false);
        let free = r.current_effort().unwrap();
        assert_eq!(free.kind, EffortKind::free_ride());
        let rt = r.begin_effort(route(), false, at(10));
        assert_ne!(rt, free.id);
        assert_eq!(r.slice(free.id).unwrap().end_reason, Some(EndReason::Superseded));
        assert_eq!(r.current_effort().unwrap().kind, route());
        assert_eq!(r.take_events(), vec![RideEvent::ride_ended(&r.slice(free.id).unwrap())]);
    }

    #[test]
    fn global_hook_receives_ride_ended() {
        use std::sync::atomic::{AtomicU32, Ordering};
        static SEEN: AtomicU32 = AtomicU32::new(0);
        on_ride_event(|e| {
            SEEN.store(e.slice_id, Ordering::SeqCst);
        });
        let id = begin_effort(EffortKind::workout("hook"), false);
        let sl = end_effort(false).unwrap();
        assert_eq!(sl.id, id);
        let ev = RideEvent::ride_ended(&sl);
        assert_eq!(ev.uid, format!("{}-workout-hook", sl.start_ms));
        assert_eq!(ev.end_reason, Some(EndReason::Stopped));
        assert!(!ev.demo && ev.end_ms >= ev.start_ms);
        assert_eq!(SEEN.load(Ordering::SeqCst), id);
    }

    #[test]
    fn default_export_dir_is_named() {
        assert!(default_export_dir().ends_with("Tacx Desktop"));
    }

    #[test]
    fn qa_c6_p1a_pedalling_on_after_finish_keeps_the_route_latest() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        let id = r.begin_effort(route(), true, at(0));
        ride(&mut r, t0, 0, 89, 200.0, true);
        r.end_effort(true, at(89));
        // Rider keeps pedalling: no micro free ride within the cooldown.
        ride(&mut r, t0, 89, 4, 200.0, true);
        assert!(r.current_effort().is_none());
        assert_eq!(r.latest_id(), Some(id));
        let sl = r.slice(id).unwrap();
        assert!(sl.completed && sl.kind == route());
        // After the cooldown a real free ride may start.
        ride(&mut r, t0, 95, 3, 200.0, true);
        assert_eq!(r.current_effort().unwrap().kind, EffortKind::free_ride());
    }

    #[test]
    fn qa_c6_blip_free_ride_closes_on_idle() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        ride(&mut r, t0, 0, 1, 5.0, false); // 1 s blip
        let blip = r.current_effort().unwrap().id;
        ride(&mut r, t0, 1, 62, 0.0, false); // connected, 0 W
        assert!(r.current_effort().is_none(), "blip ride closed");
        assert_eq!(r.slice(blip).unwrap().end_reason, Some(EndReason::Stopped));
        // A real free ride coasting for 2 min is not split.
        let mut r = RideRecorder::default();
        ride(&mut r, t0, 0, 60, 150.0, false);
        ride(&mut r, t0, 60, 120, 0.0, false);
        assert!(r.current_effort().is_some());
    }

    fn kinds(r: &mut RideRecorder) -> Vec<(RideEventKind, Option<EndReason>)> {
        r.take_events().into_iter().map(|e| (e.kind, e.end_reason)).collect()
    }

    #[test]
    fn qa_c8_p1c_dropout_is_never_an_end() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        r.set_active(Some(route()));
        let a = r.begin_effort(route(), false, at(0));
        ride(&mut r, t0, 0, 30, 200.0, false);
        idle(&mut r, t0, 30, 90); // 90 s dropout
        assert_eq!(r.current_effort().unwrap().id, a, "still open, not ended");
        ride(&mut r, t0, 120, 30, 200.0, false);
        let done = r.end_effort(false, at(150)).unwrap();
        assert!(r.end_effort(false, at(151)).is_some(), "second end: no event");
        assert_eq!(
            kinds(&mut r),
            vec![
                (RideEventKind::LinkLost, None),
                (RideEventKind::LinkRestored, None),
                (RideEventKind::RideEnded, Some(EndReason::Stopped)),
            ]
        );
        assert_eq!(done.id, a);
        assert!(done.moving_s >= 58, "both halves count: {}", done.moving_s);
        assert_eq!(r.list_efforts().len(), 1);
    }

    #[test]
    fn qa_c8_link_lost_30_min_abandons_once() {
        let mut r = RideRecorder::default();
        let t0 = Instant::now();
        r.set_active(Some(route()));
        let a = r.begin_effort(EffortKind::workout("w"), false, at(0));
        ride(&mut r, t0, 0, 30, 200.0, false);
        // Coarse idle ticks across 30 min.
        for i in 0..=62u64 {
            r.tick(t0 + Duration::from_secs(30 + i * 30), at(30 + i * 30), Tick::Idle);
        }
        assert!(r.current_effort().is_none());
        assert_eq!(r.slice(a).unwrap().end_reason, Some(EndReason::Abandoned));
        assert_eq!(
            kinds(&mut r),
            vec![(RideEventKind::LinkLost, None), (RideEventKind::RideEnded, Some(EndReason::Abandoned))]
        );
    }
}

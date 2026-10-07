//! Ride totals: elapsed / moving time, avg + max power, avg cadence, kJ, distance.
//!
//! A 1 Hz background ticker samples live metrics while a trainer is connected.
//! Gaps (reconnect, busy controller) are clamped so a stall never inflates
//! time or energy.

use crate::trainer::types::{RideStats, TrainerMetrics};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::time::Instant;

/// Longest gap credited between two samples, seconds.
pub const MAX_SAMPLE_GAP_S: f64 = 2.0;

#[derive(Clone, Debug, Default)]
pub struct RideAccumulator {
    elapsed_s: f64,
    moving_s: f64,
    pedalling_s: f64,
    power_ws: f64,
    cadence_rs: f64,
    max_power_w: f64,
    distance_m: f64,
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
        self.distance_m += v / 3.6 * dt;
    }

    pub fn set_recording(&mut self, on: bool) {
        self.recording = on;
    }

    pub fn reset(&mut self) {
        *self = Self::default();
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
}

impl RideRecorder {
    pub fn tick(&mut self, now: Instant, t: Tick) {
        match t {
            Tick::Connected(m) => {
                let dt = self
                    .last
                    .map(|l| now.saturating_duration_since(l).as_secs_f64())
                    .unwrap_or(0.0);
                self.acc.add_sample(&m, dt);
                self.last = Some(now);
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
    }

    pub fn stats(&self) -> RideStats {
        self.acc.stats()
    }
}

static RECORDER: Lazy<Mutex<RideRecorder>> = Lazy::new(|| Mutex::new(RideRecorder::default()));

pub fn record(t: Tick) {
    RECORDER.lock().tick(Instant::now(), t);
}

pub fn stats() -> RideStats {
    RECORDER.lock().stats()
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
        r.tick(t0, Tick::Connected(m(200.0, 90.0, 30.0))); // anchor, dt 0
        r.tick(t0 + Duration::from_secs(1), Tick::Connected(m(200.0, 90.0, 30.0)));
        r.tick(t0 + Duration::from_secs(2), Tick::Busy);
        r.tick(t0 + Duration::from_secs(3), Tick::Connected(m(200.0, 90.0, 30.0))); // 2 s (clamped)
        assert_eq!(r.stats().elapsed_s, 3);
        r.tick(t0 + Duration::from_secs(4), Tick::Idle);
        assert!(!r.stats().recording);
        // 60 s offline (reconnecting) is not credited.
        r.tick(t0 + Duration::from_secs(64), Tick::Connected(m(200.0, 90.0, 30.0)));
        r.tick(t0 + Duration::from_secs(65), Tick::Connected(m(200.0, 90.0, 30.0)));
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
}

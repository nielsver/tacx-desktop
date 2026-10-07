//! Demo stub trainer — no BLE required.

use crate::trainer::types::*;
use parking_lot::Mutex;
use std::time::Instant;

pub struct DemoTrainer {
    pub metrics: Mutex<TrainerMetrics>,
    pub snapshot: Mutex<ConnectionSnapshot>,
    pub resistance_range: ResistanceRange,
    pub power_range: PowerRange,
    target_power: Mutex<u32>,
    resistance_pct: Mutex<f64>,
    mode: Mutex<ControlMode>,
    t0: Mutex<Instant>,
    running: Mutex<bool>,
}

impl DemoTrainer {
    pub fn new() -> Self {
        Self {
            metrics: Mutex::new(TrainerMetrics::default()),
            snapshot: Mutex::new(ConnectionSnapshot {
                is_demo: true,
                protocol: ProtocolKind::Demo,
                ..Default::default()
            }),
            resistance_range: ResistanceRange::default(),
            power_range: PowerRange::default(),
            target_power: Mutex::new(150),
            resistance_pct: Mutex::new(20.0),
            mode: Mutex::new(ControlMode::Idle),
            t0: Mutex::new(Instant::now()),
            running: Mutex::new(false),
        }
    }

    pub fn set_state(&self, state: ConnectionState, detail: impl Into<String>) {
        let mut s = self.snapshot.lock();
        s.state = state;
        s.detail = detail.into();
        s.mode = *self.mode.lock();
        s.is_demo = true;
        s.protocol = ProtocolKind::Demo;
        s.supports_simulation = true;
    }

    pub async fn scan(&self) -> Vec<DiscoveredDevice> {
        self.set_state(ConnectionState::Scanning, "DEMO scan…");
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        self.set_state(ConnectionState::Disconnected, "Found 2 demo device(s)");
        vec![
            DiscoveredDevice {
                id: "DEMO:00:11:22:33:44:55".into(),
                name: "DEMO Tacx Neo (stub)".into(),
                rssi: Some(-42),
                protocol_hint: "demo".into(),
            },
            DiscoveredDevice {
                id: "DEMO:AA:BB:CC:DD:EE:FF".into(),
                name: "DEMO Flux 2 (stub)".into(),
                rssi: Some(-55),
                protocol_hint: "demo".into(),
            },
        ]
    }

    pub async fn connect(&self, id: Option<String>) -> Result<(), String> {
        self.set_state(ConnectionState::Connecting, "DEMO connecting…");
        tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        *self.t0.lock() = Instant::now();
        *self.running.lock() = true;
        let name = id.unwrap_or_else(|| "DEMO Tacx Neo (stub)".into());
        {
            let mut s = self.snapshot.lock();
            s.state = ConnectionState::Connected;
            s.detail = name.clone();
            s.device_name = name;
            s.is_demo = true;
            s.protocol = ProtocolKind::Demo;
        }
        Ok(())
    }

    pub fn disconnect(&self) {
        *self.running.lock() = false;
        *self.mode.lock() = ControlMode::Idle;
        *self.metrics.lock() = TrainerMetrics::default();
        self.set_state(ConnectionState::Disconnected, "DEMO disconnected");
        self.snapshot.lock().device_name.clear();
    }

    pub fn set_target_power(&self, watts: u32) {
        let pr = &self.power_range;
        let w = watts.clamp(pr.min_w, pr.max_w);
        *self.target_power.lock() = w;
        *self.mode.lock() = ControlMode::Erg;
        let mut m = self.metrics.lock();
        m.target_power_w = Some(w as f64);
        m.resistance_pct = None;
        self.snapshot.lock().mode = ControlMode::Erg;
    }

    pub fn set_resistance(&self, percent: f64) {
        let rr = &self.resistance_range;
        let p = percent.clamp(rr.min_pct, rr.max_pct);
        *self.resistance_pct.lock() = p;
        *self.mode.lock() = ControlMode::Resistance;
        let mut m = self.metrics.lock();
        m.resistance_pct = Some(p);
        m.target_power_w = None;
        self.snapshot.lock().mode = ControlMode::Resistance;
    }

    /// Demo stand-in for grade/wind simulation (maps grade into resistance feel).
    pub fn set_simulation_grade(&self, grade_pct: f64) {
        let approx = (grade_pct.clamp(-10.0, 20.0) + 10.0) / 30.0 * 100.0;
        let p = approx.clamp(0.0, 100.0);
        *self.resistance_pct.lock() = p;
        *self.mode.lock() = ControlMode::Simulation;
        let mut m = self.metrics.lock();
        m.resistance_pct = Some(p);
        m.target_power_w = None;
        self.snapshot.lock().mode = ControlMode::Simulation;
    }

    pub fn tick(&self) {
        if !*self.running.lock() {
            return;
        }
        let t = self.t0.lock().elapsed().as_secs_f64();
        let wobble = (t * 1.7).sin() * 8.0;
        let mode = *self.mode.lock();
        let mut m = self.metrics.lock();
        match mode {
            ControlMode::Erg => {
                let target = *self.target_power.lock() as f64;
                let power = m.power_w + (target - m.power_w) * 0.35 + wobble * 0.4;
                m.power_w = power.max(0.0);
                m.cadence_rpm = 85.0 + (t * 0.9).sin() * 4.0;
                m.speed_kmh = 28.0 + (power / 250.0) * 6.0;
                m.target_power_w = Some(target);
                m.resistance_pct = None;
            }
            ControlMode::Resistance => {
                let res = *self.resistance_pct.lock();
                let expected = 50.0 + res * 4.5;
                let power = m.power_w + (expected - m.power_w) * 0.25 + wobble;
                m.power_w = power.max(0.0);
                m.cadence_rpm = 80.0 + (t * 0.7).sin() * 5.0;
                m.speed_kmh = 22.0 + (100.0 - res) * 0.12;
                m.resistance_pct = Some(res);
                m.target_power_w = None;
            }
            ControlMode::Idle => {
                m.power_w = (40.0 + wobble).max(0.0);
                m.cadence_rpm = 60.0 + t.sin() * 3.0;
                m.speed_kmh = 18.0 + (t * 0.4).sin() * 1.5;
            }
            ControlMode::Simulation => {
                let res = *self.resistance_pct.lock();
                let expected = 80.0 + res * 3.0;
                let power = m.power_w + (expected - m.power_w) * 0.2 + wobble;
                m.power_w = power.max(0.0);
                m.cadence_rpm = 82.0 + (t * 0.8).sin() * 4.0;
                m.speed_kmh = 24.0 + (50.0 - res) * 0.08;
                m.resistance_pct = Some(res);
                m.target_power_w = None;
            }
        }
        // Simulated chest strap: drifts 1 bpm per tick toward a power-based target.
        let target_hr = (88.0 + m.power_w * 0.3).clamp(60.0, 185.0);
        let prev = m.heart_rate_bpm.unwrap_or(95) as f64;
        let next = if (target_hr - prev).abs() >= 1.0 {
            prev + (target_hr - prev).signum()
        } else {
            prev
        };
        m.heart_rate_bpm = Some(next as u32);
    }
}

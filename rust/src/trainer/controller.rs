//! Global trainer controller: demo by default; live BLE via btleplug (FTMS → FE-C fallback).

use crate::trainer::demo::DemoTrainer;
use crate::trainer::fec;
use crate::trainer::fec_rate::{FecWriteRateLimiter, RateDecision};
use crate::trainer::ftms;
use crate::trainer::gatt;
use crate::trainer::intervals::IntervalEngine;
use crate::trainer::types::*;
use btleplug::api::{
    bleuuid::uuid_from_u16, Central, CentralState, Characteristic, Manager as _, Peripheral as _, ScanFilter,
    WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use once_cell::sync::OnceCell;
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::runtime::Runtime;
use tokio::sync::Mutex as AsyncMutex;

static RUNTIME: OnceCell<Runtime> = OnceCell::new();
static CONTROLLER: OnceCell<Arc<AsyncMutex<TrainerController>>> = OnceCell::new();

pub fn ensure_runtime() {
    RUNTIME.get_or_init(|| Runtime::new().expect("tokio runtime"));
    CONTROLLER.get_or_init(|| Arc::new(AsyncMutex::new(TrainerController::new())));
}

pub fn runtime() -> &'static Runtime {
    ensure_runtime();
    RUNTIME.get().unwrap()
}

pub fn controller() -> Arc<AsyncMutex<TrainerController>> {
    ensure_runtime();
    CONTROLLER.get().unwrap().clone()
}

enum Backend {
    Demo(DemoTrainer),
    Ble(BleSession),
}

struct BleSession {
    peripheral: Peripheral,
    protocol: ProtocolKind,
    control_char: Option<Characteristic>,
    fec_rx: Option<Characteristic>,
    max_resistance_raw: i16,
    resistance_range: ResistanceRange,
    power_range: PowerRange,
    metrics: Arc<Mutex<TrainerMetrics>>,
    mode: Arc<Mutex<ControlMode>>,
    device_name: String,
    /// Cleared when notification stream ends or peripheral disconnects.
    alive: Arc<AtomicBool>,
    /// Last FTMS Control Point indication: (request_op, result).
    last_cp: Arc<Mutex<Option<(u8, u8)>>>,
    gatt_summary: String,
    /// FE-C WithoutResponse throttle (~4 Hz, latest-wins).
    fec_limiter: Arc<Mutex<FecWriteRateLimiter>>,
    /// True while a background FE-C flush task is scheduled.
    fec_flush_armed: Arc<AtomicBool>,
    /// Fitness Machine Status / control-lost banner text.
    status_banner: Arc<Mutex<Option<String>>>,
    /// Set when FTMS Status reports Control Permission Lost (0xFF).
    control_lost: Arc<AtomicBool>,
    /// FTMS Feature bit 13 or FE-C path — simulation grade/wind allowed.
    simulation_supported: bool,
}

pub struct TrainerController {
    demo_mode: bool,
    backend: Backend,
    snapshot: ConnectionSnapshot,
    intervals: IntervalEngine,
    interval_handle: Option<tokio::task::JoinHandle<()>>,
    demo_tick_handle: Option<tokio::task::JoinHandle<()>>,
    last_device_id: Option<String>,
}

impl TrainerController {
    pub fn new() -> Self {
        Self {
            demo_mode: true,
            backend: Backend::Demo(DemoTrainer::new()),
            snapshot: ConnectionSnapshot {
                is_demo: true,
                protocol: ProtocolKind::Demo,
                ..Default::default()
            },
            intervals: IntervalEngine::new(),
            interval_handle: None,
            demo_tick_handle: None,
            last_device_id: None,
        }
    }

    pub async fn set_demo_mode(&mut self, enabled: bool) {
        let _ = self.disconnect().await;
        self.demo_mode = enabled;
        self.backend = Backend::Demo(DemoTrainer::new());
        self.snapshot = ConnectionSnapshot {
            is_demo: enabled,
            protocol: if enabled {
                ProtocolKind::Demo
            } else {
                ProtocolKind::Ftms
            },
            detail: if enabled {
                "Demo mode on".into()
            } else {
                "Live BLE — close Zwift / Tacx Training / MyWhoosh first (exclusive control)".into()
            },
            ..Default::default()
        };
    }

    pub fn is_demo(&self) -> bool {
        self.demo_mode
    }

    pub fn snapshot(&self) -> ConnectionSnapshot {
        match &self.backend {
            Backend::Demo(d) => {
                let mut s = d.snapshot.lock().clone();
                s.is_demo = true;
                s.protocol = ProtocolKind::Demo;
                s.supports_simulation = true;
                s
            }
            Backend::Ble(b) => {
                let alive = b.alive.load(Ordering::SeqCst);
                let control_lost = b.control_lost.load(Ordering::SeqCst);
                let banner = b.status_banner.lock().clone();
                let base_detail = if b.gatt_summary.is_empty() {
                    b.device_name.clone()
                } else {
                    format!("{} · {}", b.device_name, b.gatt_summary)
                };
                if !alive {
                    ConnectionSnapshot {
                        state: ConnectionState::Error,
                        detail: "Link lost — tap Reconnect to resume ERG / intervals".into(),
                        protocol: b.protocol,
                        is_demo: false,
                        mode: *b.mode.lock(),
                        device_name: b.device_name.clone(),
                        supports_simulation: b.simulation_supported,
                    }
                } else if control_lost {
                    ConnectionSnapshot {
                        state: ConnectionState::Error,
                        detail: banner.unwrap_or_else(|| {
                            "Control lost — another app took the trainer. Close other apps and Reconnect."
                                .into()
                        }),
                        protocol: b.protocol,
                        is_demo: false,
                        mode: *b.mode.lock(),
                        device_name: b.device_name.clone(),
                        supports_simulation: b.simulation_supported,
                    }
                } else {
                    let detail = match banner {
                        Some(msg) => format!("{base_detail} · {msg}"),
                        None => base_detail,
                    };
                    ConnectionSnapshot {
                        state: ConnectionState::Connected,
                        detail,
                        protocol: b.protocol,
                        is_demo: false,
                        mode: *b.mode.lock(),
                        device_name: b.device_name.clone(),
                        supports_simulation: b.simulation_supported,
                    }
                }
            }
        }
    }

    pub fn metrics(&self) -> TrainerMetrics {
        match &self.backend {
            Backend::Demo(d) => d.metrics.lock().clone(),
            Backend::Ble(b) => b.metrics.lock().clone(),
        }
    }

    pub fn resistance_range(&self) -> ResistanceRange {
        match &self.backend {
            Backend::Demo(d) => d.resistance_range.clone(),
            Backend::Ble(b) => b.resistance_range.clone(),
        }
    }

    pub fn power_range(&self) -> PowerRange {
        match &self.backend {
            Backend::Demo(d) => d.power_range.clone(),
            Backend::Ble(b) => b.power_range.clone(),
        }
    }

    pub fn interval_status(&self) -> IntervalStatus {
        self.intervals.status()
    }

    pub async fn scan(&mut self, timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String> {
        if self.demo_mode {
            self.backend = Backend::Demo(DemoTrainer::new());
            if let Backend::Demo(d) = &self.backend {
                return Ok(d.scan().await);
            }
        }
        self.snapshot.state = ConnectionState::Scanning;
        self.snapshot.detail = "Scanning for FTMS / Tacx FE-C…".into();
        match scan_ble(timeout_ms).await {
            Ok(v) => {
                self.snapshot.state = ConnectionState::Disconnected;
                self.snapshot.detail = format!("Found {} device(s)", v.len());
                Ok(v)
            }
            Err(e) => {
                let msg = friendly_ble_error(&e);
                self.snapshot.state = ConnectionState::Error;
                self.snapshot.detail = msg.clone();
                Err(msg)
            }
        }
    }

    pub async fn connect(&mut self, device_id: Option<String>) -> Result<(), String> {
        self.connect_inner(device_id, false).await
    }

    async fn connect_inner(
        &mut self,
        device_id: Option<String>,
        preserve_intervals: bool,
    ) -> Result<(), String> {
        if !preserve_intervals {
            self.stop_interval();
        }
        if let Some(h) = self.demo_tick_handle.take() {
            h.abort();
        }

        if self.demo_mode {
            self.backend = Backend::Demo(DemoTrainer::new());
            if let Backend::Demo(d) = &self.backend {
                let id = device_id.clone();
                d.connect(device_id).await?;
                self.snapshot = d.snapshot.lock().clone();
                self.last_device_id = id.or_else(|| Some(self.snapshot.device_name.clone()));
            }
            let ctrl = controller();
            self.demo_tick_handle = Some(tokio::spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    let g = ctrl.lock().await;
                    if let Backend::Demo(d) = &g.backend {
                        if d.snapshot.lock().state != ConnectionState::Connected {
                            break;
                        }
                        d.tick();
                    } else {
                        break;
                    }
                }
            }));
            return Ok(());
        }

        let id = device_id
            .ok_or_else(|| "No device selected. Scan first, then connect.".to_string())?;
        self.snapshot.state = ConnectionState::Connecting;
        self.snapshot.detail = format!("Connecting to {id}…");
        self.snapshot.is_demo = false;

        match connect_ble(&id).await {
            Ok(session) => {
                self.snapshot.state = ConnectionState::Connected;
                self.snapshot.detail = session.device_name.clone();
                self.snapshot.device_name = session.device_name.clone();
                self.snapshot.protocol = session.protocol;
                self.snapshot.mode = ControlMode::Idle;
                self.last_device_id = Some(id.clone());
                self.backend = Backend::Ble(session);
                Ok(())
            }
            Err(e) => {
                let msg = friendly_ble_error(&e);
                self.snapshot.state = ConnectionState::Error;
                self.snapshot.detail = msg.clone();
                Err(msg)
            }
        }
    }

    pub async fn disconnect(&mut self) -> Result<(), String> {
        self.stop_interval();
        if let Some(h) = self.demo_tick_handle.take() {
            h.abort();
        }
        match &self.backend {
            Backend::Demo(d) => d.disconnect(),
            Backend::Ble(b) => {
                let _ = b.peripheral.disconnect().await;
            }
        }
        self.backend = Backend::Demo(DemoTrainer::new());
        self.snapshot = ConnectionSnapshot {
            state: ConnectionState::Disconnected,
            detail: "Disconnected".into(),
            is_demo: self.demo_mode,
            protocol: if self.demo_mode {
                ProtocolKind::Demo
            } else {
                ProtocolKind::Ftms
            },
            ..Default::default()
        };
        Ok(())
    }

    pub async fn set_target_power(&mut self, watts: u32) -> Result<(), String> {
        match &mut self.backend {
            Backend::Demo(d) => {
                d.set_target_power(watts);
                Ok(())
            }
            Backend::Ble(b) => {
                if !b.alive.load(Ordering::SeqCst) {
                    return Err(
                        "Trainer link lost — tap Reconnect, then re-apply ERG".into(),
                    );
                }
                if b.control_lost.load(Ordering::SeqCst) {
                    return Err(
                        "Control lost (Fitness Machine Status) — close other apps and Reconnect"
                            .into(),
                    );
                }
                let w = ftms::clamp_target_power(watts, &b.power_range);
                match b.protocol {
                    ProtocolKind::Ftms => {
                        let ch = b
                            .control_char
                            .as_ref()
                            .ok_or_else(|| "FTMS Control Point missing".to_string())?;
                        let payload = ftms::encode_set_target_power(w as i16);
                        *b.last_cp.lock() = None;
                        b.peripheral
                            .write(ch, &payload, WriteType::WithResponse)
                            .await
                            .map_err(|e| format!("FTMS set power failed: {e}"))?;
                        await_cp_result(&b.last_cp, ftms::OP_SET_TARGET_POWER, Duration::from_secs(3))
                            .await?;
                    }
                    ProtocolKind::TacxFecBle => {
                        let payload = fec::encode_target_power(w);
                        write_fec_throttled(b, payload)
                            .await
                            .map_err(|e| format!("FE-C set power failed: {e}"))?;
                    }
                    ProtocolKind::Demo => {}
                }
                *b.mode.lock() = ControlMode::Erg;
                let mut m = b.metrics.lock();
                m.target_power_w = Some(w as f64);
                m.resistance_pct = None;
                Ok(())
            }
        }
    }

    pub async fn set_resistance(&mut self, percent: f64) -> Result<(), String> {
        match &mut self.backend {
            Backend::Demo(d) => {
                d.set_resistance(percent);
                Ok(())
            }
            Backend::Ble(b) => {
                if !b.alive.load(Ordering::SeqCst) {
                    return Err(
                        "Trainer link lost — tap Reconnect, then re-apply resistance".into(),
                    );
                }
                if b.control_lost.load(Ordering::SeqCst) {
                    return Err(
                        "Control lost (Fitness Machine Status) — close other apps and Reconnect"
                            .into(),
                    );
                }
                let p = ftms::clamp_resistance_percent(percent, &b.resistance_range);
                match b.protocol {
                    ProtocolKind::Ftms => {
                        let ch = b
                            .control_char
                            .as_ref()
                            .ok_or_else(|| "FTMS Control Point missing".to_string())?;
                        let payload = ftms::encode_set_resistance(p, b.max_resistance_raw);
                        *b.last_cp.lock() = None;
                        b.peripheral
                            .write(ch, &payload, WriteType::WithResponse)
                            .await
                            .map_err(|e| format!("FTMS set resistance failed: {e}"))?;
                        await_cp_result(
                            &b.last_cp,
                            ftms::OP_SET_TARGET_RESISTANCE,
                            Duration::from_secs(3),
                        )
                        .await?;
                    }
                    ProtocolKind::TacxFecBle => {
                        let payload =
                            fec::encode_basic_resistance_newtons(fec::percent_to_newtons(p));
                        write_fec_throttled(b, payload)
                            .await
                            .map_err(|e| format!("FE-C set resistance failed: {e}"))?;
                    }
                    ProtocolKind::Demo => {}
                }
                *b.mode.lock() = ControlMode::Resistance;
                let mut m = b.metrics.lock();
                m.resistance_pct = Some(p);
                m.target_power_w = None;
                Ok(())
            }
        }
    }

    /// Track / grade simulation: FE-C page 0x33 or FTMS Indoor Bike Simulation (`0x11`).
    pub async fn set_track_resistance(&mut self, grade_pct: f64, crr: f64) -> Result<(), String> {
        match &mut self.backend {
            Backend::Demo(d) => {
                d.set_simulation_grade(grade_pct);
                Ok(())
            }
            Backend::Ble(b) => {
                if !b.alive.load(Ordering::SeqCst) || b.control_lost.load(Ordering::SeqCst) {
                    return Err("Trainer not controllable — Reconnect first".into());
                }
                match b.protocol {
                    ProtocolKind::TacxFecBle => {
                        let payload = fec::encode_track_resistance(grade_pct, ftms::clamp_simulation_crr(crr))?;
                        write_fec_throttled(b, payload).await?;
                        *b.mode.lock() = ControlMode::Simulation;
                        Ok(())
                    }
                    ProtocolKind::Ftms => {
                        if !b.simulation_supported {
                            return Err(
                                "This FTMS trainer does not advertise Indoor Bike Simulation (Feature bit 13)."
                                    .into(),
                            );
                        }
                        let ch = b
                            .control_char
                            .as_ref()
                            .ok_or_else(|| "FTMS Control Point missing".to_string())?;
                        let payload = ftms::encode_indoor_bike_simulation(
                            0.0,
                            grade_pct,
                            ftms::clamp_simulation_crr(crr),
                            ftms::DEFAULT_SIM_CW,
                        );
                        *b.last_cp.lock() = None;
                        b.peripheral
                            .write(ch, &payload, WriteType::WithResponse)
                            .await
                            .map_err(|e| format!("FTMS simulation (grade) failed: {e}"))?;
                        await_cp_result(
                            &b.last_cp,
                            ftms::OP_SET_INDOOR_BIKE_SIMULATION,
                            Duration::from_secs(3),
                        )
                        .await?;
                        *b.mode.lock() = ControlMode::Simulation;
                        let mut m = b.metrics.lock();
                        m.target_power_w = None;
                        Ok(())
                    }
                    ProtocolKind::Demo => Ok(()),
                }
            }
        }
    }

    /// FE-C simulation: Wind Resistance (page 0x32). Rate-limited.
    pub async fn set_wind_resistance(
        &mut self,
        wind_resistance_coefficient: f64,
        wind_speed_kmh: f64,
        drafting_factor: f64,
    ) -> Result<(), String> {
        match &mut self.backend {
            Backend::Demo(_) => Ok(()),
            Backend::Ble(b) => {
                if !b.alive.load(Ordering::SeqCst) || b.control_lost.load(Ordering::SeqCst) {
                    return Err("Trainer not controllable — Reconnect first".into());
                }
                match b.protocol {
                    ProtocolKind::TacxFecBle => {
                        let payload = fec::encode_wind_resistance(
                            ftms::clamp_simulation_cw(wind_resistance_coefficient),
                            wind_speed_kmh,
                            drafting_factor,
                        )?;
                        write_fec_throttled(b, payload).await?;
                        Ok(())
                    }
                    ProtocolKind::Ftms => {
                        if !b.simulation_supported {
                            return Err(
                                "This FTMS trainer does not advertise Indoor Bike Simulation (Feature bit 13)."
                                    .into(),
                            );
                        }
                        // Map FE-C wind (km/h, kg/m) into FTMS 0x11 (m/s, cw).
                        let wind_mps = wind_speed_kmh / 3.6;
                        let ch = b
                            .control_char
                            .as_ref()
                            .ok_or_else(|| "FTMS Control Point missing".to_string())?;
                        let payload = ftms::encode_indoor_bike_simulation(
                            wind_mps,
                            0.0,
                            ftms::DEFAULT_SIM_CRR,
                            ftms::clamp_simulation_cw(wind_resistance_coefficient),
                        );
                        *b.last_cp.lock() = None;
                        b.peripheral
                            .write(ch, &payload, WriteType::WithResponse)
                            .await
                            .map_err(|e| format!("FTMS simulation (wind) failed: {e}"))?;
                        await_cp_result(
                            &b.last_cp,
                            ftms::OP_SET_INDOOR_BIKE_SIMULATION,
                            Duration::from_secs(3),
                        )
                        .await?;
                        *b.mode.lock() = ControlMode::Simulation;
                        Ok(())
                    }
                    ProtocolKind::Demo => Ok(()),
                }
            }
        }
    }

    /// FE-C User Configuration (page 0x37) — rider/bike weight + wheel. Rate-limited.
    pub async fn set_user_configuration(
        &mut self,
        user_weight_kg: f64,
        bicycle_weight_kg: f64,
        wheel_diameter_m: f64,
        gear_ratio: f64,
    ) -> Result<(), String> {
        match &mut self.backend {
            Backend::Demo(_) => Ok(()),
            Backend::Ble(b) => {
                if !b.alive.load(Ordering::SeqCst) || b.control_lost.load(Ordering::SeqCst) {
                    return Err("Trainer not controllable — Reconnect first".into());
                }
                match b.protocol {
                    ProtocolKind::TacxFecBle => {
                        let payload = fec::encode_user_configuration(
                            user_weight_kg,
                            bicycle_weight_kg,
                            wheel_diameter_m,
                            gear_ratio,
                        )?;
                        write_fec_throttled(b, payload).await?;
                        Ok(())
                    }
                    ProtocolKind::Ftms => Err(
                        "User Configuration is FE-C page 0x37. This trainer is on FTMS."
                            .into(),
                    ),
                    ProtocolKind::Demo => Ok(()),
                }
            }
        }
    }


    /// FTMS Indoor Bike Simulation Parameters (`0x11`) or FE-C Track+Wind pair.
    pub async fn set_indoor_bike_simulation(
        &mut self,
        wind_speed_mps: f64,
        grade_pct: f64,
        crr: f64,
        cw: f64,
    ) -> Result<(), String> {
        match &mut self.backend {
            Backend::Demo(d) => {
                d.set_simulation_grade(grade_pct);
                Ok(())
            }
            Backend::Ble(b) => {
                if !b.alive.load(Ordering::SeqCst) || b.control_lost.load(Ordering::SeqCst) {
                    return Err("Trainer not controllable — Reconnect first".into());
                }
                match b.protocol {
                    ProtocolKind::Ftms => {
                        if !b.simulation_supported {
                            return Err(
                                "Indoor Bike Simulation not advertised (Feature 0x2ACC bit 13)."
                                    .into(),
                            );
                        }
                        let ch = b
                            .control_char
                            .as_ref()
                            .ok_or_else(|| "FTMS Control Point missing".to_string())?;
                        let payload = ftms::encode_indoor_bike_simulation(
                            wind_speed_mps,
                            grade_pct,
                            ftms::clamp_simulation_crr(crr),
                            ftms::clamp_simulation_cw(cw),
                        );
                        *b.last_cp.lock() = None;
                        b.peripheral
                            .write(ch, &payload, WriteType::WithResponse)
                            .await
                            .map_err(|e| format!("FTMS 0x11 simulation failed: {e}"))?;
                        await_cp_result(
                            &b.last_cp,
                            ftms::OP_SET_INDOOR_BIKE_SIMULATION,
                            Duration::from_secs(3),
                        )
                        .await?;
                        *b.mode.lock() = ControlMode::Simulation;
                        let mut m = b.metrics.lock();
                        m.target_power_w = None;
                        Ok(())
                    }
                    ProtocolKind::TacxFecBle => {
                        let track = fec::encode_track_resistance(
                            grade_pct,
                            ftms::clamp_simulation_crr(crr),
                        )?;
                        write_fec_throttled(b, track).await?;
                        let wind = fec::encode_wind_resistance(
                            ftms::clamp_simulation_cw(cw),
                            wind_speed_mps * 3.6,
                            1.0,
                        )?;
                        write_fec_throttled(b, wind).await?;
                        *b.mode.lock() = ControlMode::Simulation;
                        Ok(())
                    }
                    ProtocolKind::Demo => Ok(()),
                }
            }
        }
    }

    pub async fn start_interval(&mut self, key: String) -> Result<(), String> {
        self.stop_interval();
        let _ = crate::trainer::intervals::preset_by_key(&key)
            .ok_or_else(|| format!("Unknown preset: {key}"))?;
        let ctrl = controller();
        let engine = self.intervals.clone();
        let key_clone = key.clone();
        self.interval_handle = Some(tokio::spawn(async move {
            let _ = engine
                .run(&key_clone, |watts| {
                    let ctrl = ctrl.clone();
                    async move {
                        let mut g = ctrl.lock().await;
                        g.set_target_power(watts).await
                    }
                })
                .await;
        }));
        Ok(())
    }

    pub async fn reconnect(&mut self) -> Result<(), String> {
        let id = self
            .last_device_id
            .clone()
            .ok_or_else(|| "Nothing to reconnect — scan and connect first".to_string())?;
        let resume_watts = self.resume_watts();
        let preserve = self.intervals.status().running || resume_watts.is_some();
        // Drop existing BLE session without aborting an active interval preset.
        if let Backend::Ble(b) = &self.backend {
            b.alive.store(false, Ordering::SeqCst);
            let _ = b.peripheral.disconnect().await;
        }
        self.backend = Backend::Demo(DemoTrainer::new());
        self.connect_inner(Some(id), preserve).await?;
        if let Some(w) = resume_watts {
            self.set_target_power(w).await.map_err(|e| {
                format!("Reconnected but failed to restore ERG target {w} W: {e}")
            })?;
        }
        Ok(())
    }

    fn resume_watts(&self) -> Option<u32> {
        if let Some(w) = self.intervals.current_target_watts() {
            return Some(w);
        }
        match &self.backend {
            Backend::Demo(d) => d.metrics.lock().target_power_w.map(|w| w as u32),
            Backend::Ble(b) => b.metrics.lock().target_power_w.map(|w| w as u32),
        }
    }

    pub fn stop_interval(&mut self) {
        self.intervals.stop();
        if let Some(h) = self.interval_handle.take() {
            h.abort();
        }
    }
}

fn friendly_ble_error(err: &str) -> String {
    let lower = err.to_lowercase();
    if lower.contains("busy") || lower.contains("in use") || lower.contains("already") {
        return format!(
            "Trainer busy or already connected elsewhere. Close Zwift / Tacx Training / MyWhoosh / TrainerRoad and retry. ({err})"
        );
    }
    if lower.contains("permission")
        || lower.contains("not authorized")
        || lower.contains("tcc")
        || lower.contains("denied")
    {
        return format!(
            "Bluetooth permission denied. macOS: System Settings → Privacy & Security → Bluetooth → allow Tacx Desktop (TCC). Linux: BlueZ + D-Bus session, user in `bluetooth` group. Windows: enable Bluetooth in Settings. ({err})"
        );
    }
    if lower.contains("adapter") || lower.contains("no bluetooth") || lower.contains("powered off") {
        return format!(
            "No Bluetooth adapter / radio off. Enable Bluetooth (BlueZ on Linux; Windows Settings → Bluetooth; macOS menu bar Bluetooth). ({err})"
        );
    }
    if lower.contains("control") || lower.contains("noctrl") {
        return format!(
            "Could not take exclusive control (NOCTRL). Disconnect other FTMS clients and retry. On Windows: do NOT OS-pair the trainer in Settings → Bluetooth — leave it unpaired and connect only from this app. ({err})"
        );
    }
    if lower.contains("paired") || lower.contains("bonding") {
        return format!(
            "OS Bluetooth pairing can break FTMS control. Windows: remove/forget the trainer in Settings → Bluetooth so it is unpaired, then Connect from Tacx Desktop only. macOS: Forget This Device if control fails after system pairing. ({err})"
        );
    }
    err.to_string()
}

async fn adapter() -> Result<Adapter, String> {
    let manager = Manager::new()
        .await
        .map_err(|e| format!("Bluetooth manager failed: {e}"))?;
    let adapters = manager
        .adapters()
        .await
        .map_err(|e| format!("List adapters failed: {e}"))?;
    adapters
        .into_iter()
        .next()
        .ok_or_else(|| "No Bluetooth adapter found".to_string())
}

/// Map btleplug's adapter state onto the UI-facing radio enum.
pub fn radio_from_central(state: &CentralState) -> BluetoothRadio {
    match state {
        CentralState::PoweredOn => BluetoothRadio::On,
        CentralState::PoweredOff => BluetoothRadio::Off,
        CentralState::Unknown => BluetoothRadio::Unknown,
    }
}

/// Probe the host Bluetooth radio without scanning (cheap; safe to call on startup).
pub async fn probe_bluetooth() -> BluetoothStatus {
    match adapter().await {
        Err(e) => BluetoothStatus::from_radio(BluetoothRadio::NoAdapter, Some(e)),
        Ok(central) => match central.adapter_state().await {
            Ok(st) => BluetoothStatus::from_radio(radio_from_central(&st), None),
            Err(_) => BluetoothStatus::from_radio(BluetoothRadio::Unknown, None),
        },
    }
}

async fn scan_ble(timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String> {
    let central = adapter().await?;
    if let Ok(CentralState::PoweredOff) = central.adapter_state().await {
        return Err(BluetoothStatus::from_radio(BluetoothRadio::Off, None).hint);
    }
    central
        .start_scan(ScanFilter::default())
        .await
        .map_err(|e| format!("Scan failed: {e}"))?;
    tokio::time::sleep(Duration::from_millis(timeout_ms.max(1000) as u64)).await;
    let peripherals = central
        .peripherals()
        .await
        .map_err(|e| format!("List peripherals failed: {e}"))?;

    let ftms_uuid = uuid_from_u16(ftms::FTMS_SERVICE);
    let fec_tx = fec::tacx_uart_tx();
    let mut out = Vec::new();

    for p in peripherals {
        let props = match p.properties().await {
            Ok(Some(props)) => props,
            _ => continue,
        };
        let name = props
            .local_name
            .clone()
            .unwrap_or_else(|| "(unknown)".into());
        let name_l = name.to_lowercase();
        let services = &props.services;
        let has_ftms = services.iter().any(|u| *u == ftms_uuid);
        let looks_trainer = ["tacx", "neo", "flux", "trainer", "kickr", "smart"]
            .iter()
            .any(|k| name_l.contains(k));
        // FE-C UART may not advertise in service list until connect; name heuristic helps.
        let hint = if has_ftms {
            "ftms"
        } else if looks_trainer {
            "tacx_fec"
        } else {
            continue;
        };
        let _ = fec_tx; // reserved for future service-data matching
        out.push(DiscoveredDevice {
            id: p.id().to_string(),
            name,
            rssi: props.rssi.map(|v| v as i32),
            protocol_hint: hint.into(),
        });
    }
    central.stop_scan().await.ok();
    out.sort_by(|a, b| b.rssi.unwrap_or(-999).cmp(&a.rssi.unwrap_or(-999)));
    Ok(out)
}

async fn connect_ble(device_id: &str) -> Result<BleSession, String> {
    let central = adapter().await?;
    // Ensure we have seen the device
    central
        .start_scan(ScanFilter::default())
        .await
        .map_err(|e| format!("Scan before connect failed: {e}"))?;
    tokio::time::sleep(Duration::from_millis(1500)).await;

    let peripherals = central
        .peripherals()
        .await
        .map_err(|e| format!("List peripherals failed: {e}"))?;
    let peripheral = peripherals
        .into_iter()
        .find(|p| p.id().to_string() == device_id)
        .ok_or_else(|| {
            format!("Device {device_id} not found — scan again while the trainer is awake")
        })?;

    peripheral
        .connect()
        .await
        .map_err(|e| format!("Connect failed (busy trainer?): {e}"))?;
    peripheral
        .discover_services()
        .await
        .map_err(|e| format!("Service discovery failed: {e}"))?;

    let chars: Vec<Characteristic> = peripheral.characteristics().into_iter().collect();
    let inventory_table = gatt::format_inventory_table(&chars);
    let gatt_summary = gatt::format_inventory_summary(&chars);
    log::info!("{inventory_table}");
    eprintln!("[tacx-desktop] {inventory_table}");

    let ftms_bike = uuid_from_u16(ftms::INDOOR_BIKE_DATA);
    let ftms_cp = uuid_from_u16(ftms::CONTROL_POINT);
    let ftms_res = uuid_from_u16(ftms::SUPPORTED_RESISTANCE_RANGE);
    let ftms_pwr = uuid_from_u16(ftms::SUPPORTED_POWER_RANGE);
    let fec_rx = fec::tacx_uart_rx();
    let fec_tx = fec::tacx_uart_tx();

    let class = gatt::classify_chars(&chars);
    let has_ftms = matches!(
        class,
        gatt::TrainerGattClass::Ftms | gatt::TrainerGattClass::Dual
    );
    let has_fec = matches!(
        class,
        gatt::TrainerGattClass::FecOnly | gatt::TrainerGattClass::Dual
    );

    let name = peripheral
        .properties()
        .await
        .ok()
        .flatten()
        .and_then(|p| p.local_name)
        .unwrap_or_else(|| device_id.to_string());

    let metrics = Arc::new(Mutex::new(TrainerMetrics::default()));
    let mode = Arc::new(Mutex::new(ControlMode::Idle));
    let alive = Arc::new(AtomicBool::new(true));
    let last_cp: Arc<Mutex<Option<(u8, u8)>>> = Arc::new(Mutex::new(None));
    let fec_limiter = Arc::new(Mutex::new(FecWriteRateLimiter::new()));
    let fec_flush_armed = Arc::new(AtomicBool::new(false));
    let status_banner: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let control_lost = Arc::new(AtomicBool::new(false));
    let mut simulation_supported = false;

    if has_ftms {
        // Prefer FTMS (even on Dual — FE-C UART stays unused while FTMS works).
        let mut resistance_range = ResistanceRange::default();
        let mut power_range = PowerRange::default();
        let mut max_resistance_raw: i16 = 1000;

        if let Some(ch) = chars.iter().find(|c| c.uuid == ftms_res) {
            if let Ok(raw) = peripheral.read(ch).await {
                let (rr, max_raw) = ftms::parse_resistance_range(&raw);
                resistance_range = rr;
                max_resistance_raw = max_raw;
            }
        }
        if let Some(ch) = chars.iter().find(|c| c.uuid == ftms_pwr) {
            if let Ok(raw) = peripheral.read(ch).await {
                power_range = ftms::parse_power_range(&raw);
            }
        }
        let ftms_feature = uuid_from_u16(ftms::FEATURE);
        if let Some(ch) = chars.iter().find(|c| c.uuid == ftms_feature) {
            if let Ok(raw) = peripheral.read(ch).await {
                simulation_supported = ftms::features_support_simulation(&raw);
                log::info!(
                    "FTMS Feature: indoor bike simulation supported={simulation_supported}"
                );
            }
        } else {
            log::info!("FTMS Feature (0x2ACC) absent — simulation gated off");
        }

        let bike_ch = chars
            .iter()
            .find(|c| c.uuid == ftms_bike)
            .cloned()
            .ok_or("FTMS Indoor Bike Data characteristic missing")?;
        let cp_ch = chars
            .iter()
            .find(|c| c.uuid == ftms_cp)
            .cloned()
            .ok_or("FTMS Control Point characteristic missing")?;

        let ftms_status = uuid_from_u16(ftms::MACHINE_STATUS);
        peripheral
            .subscribe(&bike_ch)
            .await
            .map_err(|e| format!("Subscribe Indoor Bike Data failed: {e}"))?;
        peripheral
            .subscribe(&cp_ch)
            .await
            .map_err(|e| format!("Subscribe FTMS Control Point failed: {e}"))?;
        // 0x2ADA is optional — trainers without Machine Status still connect/control.
        if let Some(status_ch) = chars.iter().find(|c| c.uuid == ftms_status) {
            match peripheral.subscribe(status_ch).await {
                Ok(()) => log::info!("Subscribed Fitness Machine Status (0x2ADA)"),
                Err(e) => log::warn!(
                    "Fitness Machine Status subscribe failed (optional, continuing): {e}"
                ),
            }
        } else {
            log::info!(
                "Fitness Machine Status (0x2ADA) not present — continuing without status notifications"
            );
        }

        // Notification pump: Indoor Bike Data + CP + Machine Status; mark link lost on stream end.
        let metrics_n = metrics.clone();
        let last_cp_n = last_cp.clone();
        let alive_n = alive.clone();
        let banner_n = status_banner.clone();
        let lost_n = control_lost.clone();
        let peri_n = peripheral.clone();
        tokio::spawn(async move {
            if let Ok(mut stream) = peri_n.notifications().await {
                while let Some(n) = stream.next().await {
                    if n.uuid == ftms_bike {
                        let mut m = metrics_n.lock();
                        merge_ftms_metrics(&mut m, &n.value);
                    } else if n.uuid == ftms_cp {
                        if let Some((op, result)) = ftms::parse_cp_indication(&n.value) {
                            log::info!(
                                "FTMS CP indication: {}",
                                ftms::format_cp_response(op, result)
                            );
                            *last_cp_n.lock() = Some((op, result));
                        }
                    } else if n.uuid == ftms_status {
                        if let Some(ev) = ftms::parse_machine_status(&n.value) {
                            log::info!("FTMS Machine Status: {}", ev.as_ux_message());
                            *banner_n.lock() = Some(ev.as_ux_message().to_string());
                            if ev.is_control_lost() {
                                lost_n.store(true, Ordering::SeqCst);
                            }
                        }
                    }
                    if !peri_n.is_connected().await.unwrap_or(true) {
                        break;
                    }
                }
            }
            alive_n.store(false, Ordering::SeqCst);
            log::warn!("FTMS notification stream ended — trainer link lost");
        });

        // Live ERG validation path: Request Control → Start/Resume (CP results checked).
        *last_cp.lock() = None;
        peripheral
            .write(
                &cp_ch,
                &ftms::encode_request_control(),
                WriteType::WithResponse,
            )
            .await
            .map_err(|e| format!("Request Control failed (NOCTRL?): {e}"))?;
        await_cp_result(&last_cp, ftms::OP_REQUEST_CONTROL, Duration::from_secs(3))
            .await
            .map_err(|e| {
                friendly_ble_error(&format!(
                    "Request Control rejected: {e}. Close other apps; on Windows leave trainer unpaired."
                ))
            })?;

        *last_cp.lock() = None;
        peripheral
            .write(
                &cp_ch,
                &ftms::encode_start_resume(),
                WriteType::WithResponse,
            )
            .await
            .map_err(|e| format!("Start/Resume failed: {e}"))?;
        // Some trainers omit Start/Resume response — soft-fail with log only.
        if let Err(e) =
            await_cp_result(&last_cp, ftms::OP_START_RESUME, Duration::from_secs(2)).await
        {
            log::warn!("Start/Resume CP: {e} (continuing)");
        }

        central.stop_scan().await.ok();
        return Ok(BleSession {
            peripheral,
            protocol: ProtocolKind::Ftms,
            control_char: Some(cp_ch),
            fec_rx: None,
            max_resistance_raw,
            resistance_range,
            power_range,
            metrics,
            mode,
            device_name: name,
            alive,
            last_cp,
            gatt_summary,
            fec_limiter,
            fec_flush_armed,
            status_banner,
            control_lost,
            simulation_supported,
        });
    }

    if has_fec {
        let rx = chars
            .iter()
            .find(|c| c.uuid == fec_rx)
            .cloned()
            .ok_or("Tacx FE-C RX characteristic missing")?;
        let tx = chars
            .iter()
            .find(|c| c.uuid == fec_tx)
            .cloned()
            .ok_or("Tacx FE-C TX characteristic missing")?;

        peripheral
            .subscribe(&tx)
            .await
            .map_err(|e| format!("Subscribe Tacx FE-C TX failed: {e}"))?;

        let metrics_n = metrics.clone();
        let alive_n = alive.clone();
        let peri_n = peripheral.clone();
        tokio::spawn(async move {
            if let Ok(mut stream) = peri_n.notifications().await {
                while let Some(n) = stream.next().await {
                    if n.uuid == fec::tacx_uart_tx() {
                        if let Some(msg) = fec::extract_fec_message_data(&n.value) {
                            let mut m = metrics_n.lock();
                            if let Some((power, cadence)) = fec::parse_specific_trainer_page(&msg) {
                                if let Some(p) = power {
                                    m.power_w = p;
                                }
                                if let Some(c) = cadence {
                                    m.cadence_rpm = c;
                                }
                            }
                            if let Some(spd) = fec::parse_general_fe_speed(&msg) {
                                m.speed_kmh = spd;
                            }
                        }
                    }
                    if !peri_n.is_connected().await.unwrap_or(true) {
                        break;
                    }
                }
            }
            alive_n.store(false, Ordering::SeqCst);
            log::warn!("FE-C notification stream ended — trainer link lost");
        });

        central.stop_scan().await.ok();
        simulation_supported = true;
        return Ok(BleSession {
            peripheral,
            protocol: ProtocolKind::TacxFecBle,
            control_char: None,
            fec_rx: Some(rx),
            max_resistance_raw: 1000,
            resistance_range: ResistanceRange::default(),
            power_range: PowerRange {
                min_w: 0,
                max_w: 4000,
                step_w: 1,
            },
            metrics,
            mode,
            device_name: format!("{name} (FE-C)"),
            alive,
            last_cp,
            gatt_summary,
            fec_limiter,
            fec_flush_armed,
            status_banner,
            control_lost,
            simulation_supported,
        });
    }

    let _ = peripheral.disconnect().await;
    Err(format!(
        "Trainer has neither FTMS (0x1826) nor Tacx FE-C UART. Unsupported device. GATT: {gatt_summary}"
    ))
}


/// FE-C UART write with ~4 Hz latest-wins coalescing (non-blocking when throttled).
async fn write_fec_throttled(b: &BleSession, payload: Vec<u8>) -> Result<(), String> {
    let ch = b
        .fec_rx
        .as_ref()
        .ok_or_else(|| "Tacx FE-C RX characteristic missing".to_string())?;
    let decision = b.fec_limiter.lock().offer(payload, Instant::now());
    match decision {
        RateDecision::SendNow(frame) => b
            .peripheral
            .write(ch, &frame, WriteType::WithoutResponse)
            .await
            .map_err(|e| e.to_string()),
        RateDecision::Coalesced { wait } => {
            if b
                .fec_flush_armed
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                let lim = b.fec_limiter.clone();
                let armed = b.fec_flush_armed.clone();
                let peri = b.peripheral.clone();
                let ch = ch.clone();
                tokio::spawn(async move {
                    let mut delay = wait;
                    loop {
                        tokio::time::sleep(delay).await;
                        let frame = {
                            let mut g = lim.lock();
                            g.take_pending_if_ready(Instant::now())
                        };
                        if let Some(p) = frame {
                            if let Err(e) =
                                peri.write(&ch, &p, WriteType::WithoutResponse).await
                            {
                                log::warn!("FE-C coalesced flush failed: {e}");
                            }
                        }
                        let next = {
                            let g = lim.lock();
                            g.pending_wait(Instant::now())
                        };
                        match next {
                            Some(w) => delay = w.max(Duration::from_millis(1)),
                            None => break,
                        }
                    }
                    armed.store(false, Ordering::SeqCst);
                });
            }
            Ok(())
        }
    }
}

/// Wait for FTMS Control Point indication matching `expected_op`.
async fn await_cp_result(
    last_cp: &Arc<Mutex<Option<(u8, u8)>>>,
    expected_op: u8,
    timeout: Duration,
) -> Result<(), String> {
    let start = Instant::now();
    loop {
        if let Some((op, result)) = *last_cp.lock() {
            if op == expected_op {
                if ftms::cp_success(result) {
                    return Ok(());
                }
                return Err(ftms::format_cp_response(op, result));
            }
        }
        if start.elapsed() > timeout {
            return Err(format!(
                "FTMS Control Point timeout waiting for 0x{expected_op:02X} ({})",
                ftms::format_cp_response(expected_op, 0xFF)
            )
            .replace("unknown control-point result", "no indication received"));
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn merge_ftms_metrics(m: &mut TrainerMetrics, data: &[u8]) {
    if data.len() < 2 {
        return;
    }
    let flags = u16::from_le_bytes([data[0], data[1]]);
    let parsed = ftms::parse_indoor_bike_data(data);
    let more_data = flags & 0x0001 != 0;
    if !more_data {
        m.speed_kmh = parsed.speed_kmh;
    }
    if flags & 0x0004 != 0 {
        m.cadence_rpm = parsed.cadence_rpm;
    }
    if flags & 0x0040 != 0 {
        m.power_w = parsed.power_w;
    }
}

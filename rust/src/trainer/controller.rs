//! Global trainer controller: live BLE by default (FTMS → FE-C); optional Demo stubs.

use crate::trainer::demo::DemoTrainer;
use crate::trainer::fec;
use crate::trainer::fec_rate::{FecWriteRateLimiter, RateDecision};
use crate::trainer::ftms;
use crate::trainer::gatt;
use crate::trainer::scan;
use crate::trainer::intervals::IntervalEngine;
use crate::trainer::workouts::{self, WorkoutCommand, WorkoutEngine};
use crate::trainer::gpx::{self, grade_at_distance, slew_grade};
use crate::trainer::types::{GpxProfileInfo, RouteStatus, WorkoutStatus};
use crate::trainer::ride;
use crate::trainer::reconnect::{
    self, AutoReconnect, BackoffPolicy, LossDecision, NextStep, ReconnectGate, ResumeTarget,
    SimParams,
};
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
use tokio::sync::Notify;

static RUNTIME: OnceCell<Runtime> = OnceCell::new();
static CONTROLLER: OnceCell<Arc<AsyncMutex<TrainerController>>> = OnceCell::new();
/// Last connection snapshot published for sync UI polls. Updated whenever the
/// controller mutates connection state; read via [`try_snapshot`] so Flutter's
/// 250 ms timer never blocks behind a long BlueZ connect/scan holding the
/// async mutex (manual Connect freeze on Linux).
static PUBLISHED_SNAPSHOT: OnceCell<Arc<Mutex<ConnectionSnapshot>>> = OnceCell::new();

pub fn ensure_runtime() {
    RUNTIME.get_or_init(|| Runtime::new().expect("tokio runtime"));
    CONTROLLER.get_or_init(|| Arc::new(AsyncMutex::new(TrainerController::new_global())));
    PUBLISHED_SNAPSHOT.get_or_init(|| {
        Arc::new(Mutex::new(ConnectionSnapshot {
            is_demo: false,
            protocol: ProtocolKind::Ftms,
            detail: "Live BLE — close Zwift / Wahoo app / Tacx Training / MyWhoosh first (exclusive control)".into(),
            ..Default::default()
        }))
    });
    RIDE_TICKER.get_or_init(|| {
        RUNTIME.get().unwrap().spawn(ride_ticker());
    });
}

static RIDE_TICKER: OnceCell<()> = OnceCell::new();

/// 1 Hz sampler feeding ride totals; never waits on the controller mutex.
async fn ride_ticker() {
    let mut iv = tokio::time::interval(Duration::from_secs(1));
    iv.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        iv.tick().await;
        let tick = match CONTROLLER.get().map(|c| c.try_lock()) {
            Some(Ok(g)) => {
                if g.snapshot().state == ConnectionState::Connected {
                    ride::Tick::Connected(g.metrics())
                } else {
                    ride::Tick::Idle
                }
            }
            Some(Err(_)) => ride::Tick::Busy,
            None => ride::Tick::Idle,
        };
        ride::record(tick);
    }
}

fn publish_snapshot(s: &ConnectionSnapshot) {
    ensure_runtime();
    *PUBLISHED_SNAPSHOT.get().unwrap().lock() = s.clone();
}

/// Non-blocking snapshot for sync FRB getters. Prefer live controller state;
/// if the async mutex is held (scan/connect in flight), return the last
/// published copy so the Flutter UI isolate stays responsive.
pub fn try_snapshot() -> ConnectionSnapshot {
    ensure_runtime();
    match CONTROLLER.get().unwrap().try_lock() {
        Ok(g) => {
            let s = g.snapshot();
            publish_snapshot(&s);
            s
        }
        Err(_) => PUBLISHED_SNAPSHOT.get().unwrap().lock().clone(),
    }
}

pub fn try_metrics() -> TrainerMetrics {
    ensure_runtime();
    match CONTROLLER.get().unwrap().try_lock() {
        Ok(g) => g.metrics(),
        Err(_) => {
            let mut m = TrainerMetrics::default();
            crate::trainer::hr_strap::overlay(&mut m);
            m
        }
    }
}

pub fn try_resistance_range() -> ResistanceRange {
    ensure_runtime();
    match CONTROLLER.get().unwrap().try_lock() {
        Ok(g) => g.resistance_range(),
        Err(_) => ResistanceRange::default(),
    }
}

pub fn try_power_range() -> PowerRange {
    ensure_runtime();
    match CONTROLLER.get().unwrap().try_lock() {
        Ok(g) => g.power_range(),
        Err(_) => PowerRange::default(),
    }
}

pub fn try_workout_status() -> WorkoutStatus {
    ensure_runtime();
    match CONTROLLER.get().unwrap().try_lock() {
        Ok(g) => g.workout_status(),
        Err(_) => WorkoutStatus::default(),
    }
}

pub fn try_route_status() -> RouteStatus {
    ensure_runtime();
    match CONTROLLER.get().unwrap().try_lock() {
        Ok(g) => g.route_status(),
        Err(_) => RouteStatus::default(),
    }
}

pub fn try_interval_status() -> IntervalStatus {
    ensure_runtime();
    match CONTROLLER.get().unwrap().try_lock() {
        Ok(g) => g.interval_status(),
        Err(_) => IntervalStatus::default(),
    }
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

/// Result of [`TrainerController::prepare_connect`]: either finished (demo) or
/// ready for an unlocked `connect_ble` call.
enum ConnectPrep {
    Done,
    Ble(String),
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
    /// False when FTMS has no 0x2AD6 / Target Resistance bit (e.g. Kickr Bike).
    resistance_supported: bool,
    /// Signalled once by the notification pump when the link drops.
    link_lost: Arc<Notify>,
}

const CONTROL_LOST_AT_DROP: &str =
    "another app took the trainer. Close Zwift / Wahoo app / Tacx Training / MyWhoosh, then tap Reconnect.";

pub struct TrainerController {
    demo_mode: bool,
    backend: Backend,
    snapshot: ConnectionSnapshot,
    intervals: IntervalEngine,
    interval_handle: Option<tokio::task::JoinHandle<()>>,
    workout_engine: WorkoutEngine,
    workout_handle: Option<tokio::task::JoinHandle<()>>,
    route_profile: Option<GpxProfileInfo>,
    route_status: RouteStatus,
    route_handle: Option<tokio::task::JoinHandle<()>>,
    route_grade: f64,
    erg_from_grade: bool,
    rider_mass_kg: f64,
    demo_tick_handle: Option<tokio::task::JoinHandle<()>>,
    last_device_id: Option<String>,
    /// Invalidated by user Disconnect / demo switch / manual connect.
    reconnect_gate: ReconnectGate,
    backoff: BackoffPolicy,
    auto_reconnect: AutoReconnect,
    /// Link watcher → auto-reconnect loop for the current session.
    link_watch_handle: Option<tokio::task::JoinHandle<()>>,
    /// When the last automatic reconnect succeeded, and on which attempt.
    last_auto_success: Option<(Instant, u32)>,
    /// Last simulation parameters sent (restored after reconnect).
    last_sim: Option<SimParams>,
    /// Only the process-wide controller publishes to [`PUBLISHED_SNAPSHOT`];
    /// scratch instances (tests, tools) must not clobber the UI's fallback copy.
    publishes: bool,
}

impl TrainerController {
    /// The singleton behind [`controller`]; mirrors state into [`PUBLISHED_SNAPSHOT`].
    fn new_global() -> Self {
        Self {
            publishes: true,
            ..Self::new()
        }
    }

    fn publish(&self) {
        if self.publishes {
            publish_snapshot(&self.snapshot);
        }
    }

    pub fn new() -> Self {
        Self {
            demo_mode: false,
            backend: Backend::Demo(DemoTrainer::new()),
            snapshot: ConnectionSnapshot {
                is_demo: false,
                protocol: ProtocolKind::Ftms,
                detail: "Live BLE — close Zwift / Wahoo app / Tacx Training / MyWhoosh first (exclusive control)".into(),
                ..Default::default()
            },
            intervals: IntervalEngine::new(),
            interval_handle: None,
            workout_engine: WorkoutEngine::new(),
            workout_handle: None,
            route_profile: None,
            route_status: RouteStatus::default(),
            route_handle: None,
            route_grade: 0.0,
            erg_from_grade: false,
            rider_mass_kg: 75.0,
            demo_tick_handle: None,
            last_device_id: None,
            reconnect_gate: ReconnectGate::default(),
            backoff: BackoffPolicy::default(),
            auto_reconnect: AutoReconnect::Inactive,
            link_watch_handle: None,
            last_auto_success: None,
            last_sim: None,
            publishes: false,
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
                "Live BLE — close Zwift / Wahoo app / Tacx Training / MyWhoosh first (exclusive control)".into()
            },
            ..Default::default()
        };
        self.publish();
    }

    pub fn is_demo(&self) -> bool {
        self.demo_mode
    }

    pub fn snapshot(&self) -> ConnectionSnapshot {
        match &self.backend {
            Backend::Demo(d) => {
                // Demo backend is also the idle placeholder when live BLE is off.
                // Always honor `demo_mode` so the Demo switch cannot snap back on
                // after the rider turns it off (UI poll called this every 250 ms).
                if !self.demo_mode {
                    return self.snapshot.clone();
                }
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
                    let lost = ConnectionSnapshot {
                        state: ConnectionState::Error,
                        detail: "Link lost — tap Reconnect to resume ERG / intervals".into(),
                        protocol: b.protocol,
                        is_demo: false,
                        mode: *b.mode.lock(),
                        device_name: b.device_name.clone(),
                        supports_simulation: b.simulation_supported,
                        ..Default::default()
                    };
                    match self.auto_reconnect.view(Instant::now()) {
                        Some(v) => ConnectionSnapshot {
                            state: v.state,
                            detail: v.detail,
                            reconnect_attempt: v.attempt,
                            reconnect_max_attempts: v.max_attempts,
                            reconnect_in_s: v.in_s,
                            reconnect_gave_up: v.gave_up,
                            ..lost
                        },
                        None => lost,
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
                        ..Default::default()
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
                        ..Default::default()
                    }
                }
            }
        }
    }

    pub fn metrics(&self) -> TrainerMetrics {
        let mut m = match &self.backend {
            Backend::Demo(d) => d.metrics.lock().clone(),
            Backend::Ble(b) => b.metrics.lock().clone(),
        };
        crate::trainer::hr_strap::overlay(&mut m);
        m
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
        // Prefer [`scan_trainers_unlocked`] from the API so BlueZ scan does not
        // hold the controller mutex (UI freeze). Kept for demo / internal use.
        if self.demo_mode {
            self.backend = Backend::Demo(DemoTrainer::new());
            if let Backend::Demo(d) = &self.backend {
                return Ok(d.scan().await);
            }
        }
        self.snapshot.state = ConnectionState::Scanning;
        self.snapshot.detail = "Scanning for FTMS / Kickr / Tacx FE-C…".into();
        self.publish();
        match scan_ble(timeout_ms).await {
            Ok(v) => {
                self.snapshot.state = ConnectionState::Disconnected;
                self.snapshot.detail = format!("Found {} device(s)", v.len());
                self.publish();
                Ok(v)
            }
            Err(e) => {
                let msg = friendly_ble_error(&e);
                self.snapshot.state = ConnectionState::Error;
                self.snapshot.detail = msg.clone();
                self.publish();
                Err(msg)
            }
        }
    }

    pub async fn connect(&mut self, device_id: Option<String>) -> Result<(), String> {
        // Prefer [`connect_trainer_unlocked`] — this path still holds the mutex
        // for the whole BLE handshake (legacy / tests).
        self.connect_inner(device_id, false).await
    }

    async fn connect_inner(
        &mut self,
        device_id: Option<String>,
        preserve_intervals: bool,
    ) -> Result<(), String> {
        match self.prepare_connect(device_id, preserve_intervals).await? {
            ConnectPrep::Done => Ok(()),
            ConnectPrep::Ble(id) => {
                // Holding &mut self: callers that care about UI responsiveness
                // must use connect_trainer_unlocked instead.
                match connect_ble(&id).await {
                    Ok(session) => {
                        self.install_ble_session(session, id);
                        Ok(())
                    }
                    Err(e) => Err(self.fail_connect(e)),
                }
            }
        }
    }

    /// Prepare a connect: cancel auto-reconnect, start demo tick or mark
    /// Connecting. Returns [`ConnectPrep::Ble`] so the caller can run
    /// `connect_ble` **without** holding the controller mutex.
    async fn prepare_connect(
        &mut self,
        device_id: Option<String>,
        preserve_intervals: bool,
    ) -> Result<ConnectPrep, String> {
        self.cancel_auto_reconnect();
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
                self.publish();
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
            return Ok(ConnectPrep::Done);
        }

        let id = device_id
            .ok_or_else(|| "No device selected. Scan first, then connect.".to_string())?;
        self.snapshot.state = ConnectionState::Connecting;
        self.snapshot.detail = format!("Connecting to {id}…");
        self.snapshot.is_demo = false;
        self.publish();
        Ok(ConnectPrep::Ble(id))
    }

    fn install_ble_session(&mut self, session: BleSession, id: String) {
        self.snapshot.state = ConnectionState::Connected;
        self.snapshot.detail = session.device_name.clone();
        self.snapshot.device_name = session.device_name.clone();
        self.snapshot.protocol = session.protocol;
        self.snapshot.mode = ControlMode::Idle;
        self.snapshot.supports_simulation = session.simulation_supported;
        self.last_device_id = Some(id);
        self.backend = Backend::Ble(session);
        self.publish();
        self.arm_link_watch();
    }

    fn fail_connect(&mut self, e: String) -> String {
        let msg = friendly_ble_error(&e);
        self.snapshot.state = ConnectionState::Error;
        self.snapshot.detail = msg.clone();
        self.publish();
        msg
    }

    pub async fn disconnect(&mut self) -> Result<(), String> {
        // User-initiated: never auto-reconnect after this.
        self.cancel_auto_reconnect();
        self.stop_interval();
        self.stop_workout();
        self.stop_gpx_route();
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
        self.publish();
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
                        "Control lost (Fitness Machine Status) — close other apps (Zwift / Wahoo) and Reconnect"
                            .into(),
                    );
                }
                if !b.resistance_supported || b.resistance_range.max_pct <= 0.0 {
                    return Err(
                        "Resistance % is not supported on this trainer (e.g. Kickr Bike / Bike Shift). Use ERG or Simulation instead."
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
        let result = self.set_track_resistance_inner(grade_pct, crr).await;
        if result.is_ok() {
            let prev = self.last_sim;
            self.last_sim = Some(SimParams {
                wind_speed_mps: prev.map(|p| p.wind_speed_mps).unwrap_or(0.0),
                grade_pct,
                crr,
                cw: prev.map(|p| p.cw).unwrap_or(ftms::DEFAULT_SIM_CW),
            });
        }
        result
    }

    async fn set_track_resistance_inner(&mut self, grade_pct: f64, crr: f64) -> Result<(), String> {
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
        let result = self
            .set_indoor_bike_simulation_inner(wind_speed_mps, grade_pct, crr, cw)
            .await;
        if result.is_ok() {
            self.last_sim = Some(SimParams {
                wind_speed_mps,
                grade_pct,
                crr,
                cw,
            });
        }
        result
    }

    async fn set_indoor_bike_simulation_inner(
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
                        let r = g.set_target_power(watts).await;
                        match r {
                            // Keep the preset ticking through a drop; reconnect
                            // re-applies the current phase target.
                            Err(e) if g.link_down() => {
                                log::warn!("Interval target {watts} W deferred — link down ({e})");
                                Ok(())
                            }
                            r => r,
                        }
                    }
                })
                .await;
        }));
        Ok(())
    }

    /// Tear down the current BLE link (keep interval engine) and return the
    /// device id + whether to restore control after reconnect. Used by
    /// [`reconnect_trainer_unlocked`].
    async fn prepare_manual_reconnect(&mut self) -> Result<(String, Option<ResumeTarget>, bool), String> {
        let id = self
            .last_device_id
            .clone()
            .ok_or_else(|| "Nothing to reconnect — scan and connect first".to_string())?;
        self.cancel_auto_reconnect();
        let resume = self.resume_target();
        let preserve = self.intervals.status().running || resume.is_some();
        if let Backend::Ble(b) = &self.backend {
            b.alive.store(false, Ordering::SeqCst);
            let _ = b.peripheral.disconnect().await;
        }
        self.backend = Backend::Demo(DemoTrainer::new());
        self.snapshot.state = ConnectionState::Connecting;
        self.snapshot.detail = format!("Reconnecting to {id}…");
        self.snapshot.is_demo = false;
        self.publish();
        Ok((id, resume, preserve))
    }

    pub async fn reconnect(&mut self) -> Result<(), String> {
        // Legacy path (holds mutex). Prefer reconnect_trainer_unlocked.
        let (id, resume, preserve) = self.prepare_manual_reconnect().await?;
        self.connect_inner(Some(id), preserve).await?;
        if let Some(t) = resume {
            self.apply_resume_target(t).await?;
        }
        Ok(())
    }

    /// Control target to restore after reconnect: running interval phase
    /// watts, else the last ERG watts / resistance % / simulation grade.
    fn resume_target(&self) -> Option<ResumeTarget> {
        let (mode, m) = match &self.backend {
            Backend::Demo(d) => (d.snapshot.lock().mode, d.metrics.lock().clone()),
            Backend::Ble(b) => (*b.mode.lock(), b.metrics.lock().clone()),
        };
        reconnect::pick_resume_target(
            self.intervals.current_target_watts(),
            mode,
            m.target_power_w,
            m.resistance_pct,
            self.last_sim,
        )
    }

    async fn apply_resume_target(&mut self, t: ResumeTarget) -> Result<(), String> {
        match t {
            ResumeTarget::Erg(w) => self.set_target_power(w).await.map_err(|e| {
                format!("Reconnected but failed to restore ERG target {w} W: {e}")
            }),
            ResumeTarget::Resistance(p) => self.set_resistance(p).await.map_err(|e| {
                format!("Reconnected but failed to restore resistance {p:.0} %: {e}")
            }),
            ResumeTarget::Simulation(sp) => self
                .set_indoor_bike_simulation(sp.wind_speed_mps, sp.grade_pct, sp.crr, sp.cw)
                .await
                .map_err(|e| {
                    format!(
                        "Reconnected but failed to restore simulation grade {:.1} %: {e}",
                        sp.grade_pct
                    )
                }),
        }
    }

    /// Live BLE session whose link has dropped.
    fn link_down(&self) -> bool {
        matches!(&self.backend, Backend::Ble(b) if !b.alive.load(Ordering::SeqCst))
    }

    /// Cancel any pending automatic reconnect (user Disconnect, demo switch,
    /// manual connect / Reconnect). A retry sleeping in its backoff is aborted;
    /// an attempt already mid-connect sees the stale token afterwards and
    /// releases its link itself (aborting it could orphan a BLE connection).
    fn cancel_auto_reconnect(&mut self) {
        self.reconnect_gate.cancel();
        let attempting = matches!(self.auto_reconnect, AutoReconnect::Attempting { .. });
        if let Some(h) = self.link_watch_handle.take() {
            if !attempting {
                h.abort();
            }
        }
        self.auto_reconnect = AutoReconnect::Inactive;
        self.last_auto_success = None;
    }

    /// Watch the current BLE session; on unexpected link loss run the
    /// bounded auto-reconnect loop.
    fn arm_link_watch(&mut self) {
        let Backend::Ble(b) = &self.backend else {
            return;
        };
        let lost = b.link_lost.clone();
        let token = self.reconnect_gate.token();
        // Replacing (not aborting) the old handle: it may be the auto-reconnect
        // task that is calling us right now.
        self.link_watch_handle = Some(tokio::spawn(async move {
            lost.notified().await;
            auto_reconnect_loop(token).await;
        }));
    }

    /// Install a session obtained by the auto-reconnect loop and restore the
    /// previous control target (interval preset keeps running).
    async fn finish_auto_reconnect(&mut self, session: BleSession, attempt: u32) {
        let resume = self.resume_target();
        self.snapshot.state = ConnectionState::Connected;
        self.snapshot.detail = session.device_name.clone();
        self.snapshot.device_name = session.device_name.clone();
        self.snapshot.protocol = session.protocol;
        self.snapshot.mode = ControlMode::Idle;
        self.backend = Backend::Ble(session);
        self.auto_reconnect = AutoReconnect::Inactive;
        self.last_auto_success = Some((Instant::now(), attempt));
        self.arm_link_watch();
        log::info!("Auto-reconnect succeeded on attempt {attempt}; restoring {resume:?}");
        if let Some(t) = resume {
            if let Err(e) = self.apply_resume_target(t).await {
                log::warn!("{e}");
                if let Backend::Ble(b) = &self.backend {
                    *b.status_banner.lock() = Some(e);
                }
            }
        }
    }

    pub fn stop_interval(&mut self) {
        self.intervals.stop();
        if let Some(h) = self.interval_handle.take() {
            h.abort();
        }
    }

    pub fn workout_status(&self) -> WorkoutStatus {
        self.workout_engine.status()
    }

    pub fn stop_workout(&mut self) {
        self.workout_engine.stop();
        if let Some(h) = self.workout_handle.take() {
            h.abort();
        }
    }

    pub async fn start_workout(&mut self, id: String) -> Result<(), String> {
        self.stop_workout();
        self.stop_interval();
        self.stop_gpx_route();
        let workout = workouts::load_workout(&id)?;
        // Gate sim-only workouts when trainer lacks simulation (demo always OK).
        let needs_sim = workout
            .steps
            .iter()
            .any(|s| s.kind == "simGrade");
        if needs_sim && !self.demo_mode && !self.snapshot.supports_simulation {
            return Err(
                "This workout needs simulation grade — use an ERG workout or a trainer with sim support"
                    .into(),
            );
        }
        let ctrl = controller();
        let engine = self.workout_engine.clone();
        self.workout_handle = Some(tokio::spawn(async move {
            let _ = engine
                .run(workout, |cmd| {
                    let ctrl = ctrl.clone();
                    async move {
                        let mut g = ctrl.lock().await;
                        let r = match cmd {
                            WorkoutCommand::Erg(w) => g.set_target_power(w).await,
                            WorkoutCommand::Resistance(p) => g.set_resistance(p).await,
                            WorkoutCommand::SimGrade(grade) => {
                                g.set_indoor_bike_simulation(
                                    0.0,
                                    grade,
                                    ftms::DEFAULT_SIM_CRR,
                                    ftms::DEFAULT_SIM_CW,
                                )
                                .await
                            }
                        };
                        match r {
                            Err(e) if g.link_down() => {
                                log::warn!("Workout command deferred — link down ({e})");
                                Ok(())
                            }
                            r => r,
                        }
                    }
                })
                .await;
        }));
        Ok(())
    }

    pub fn route_status(&self) -> RouteStatus {
        self.route_status.clone()
    }

    pub fn set_erg_from_grade(&mut self, enabled: bool) {
        self.erg_from_grade = enabled;
    }

    pub fn set_rider_mass_kg(&mut self, kg: f64) {
        self.rider_mass_kg = kg.clamp(40.0, 120.0);
    }

    pub fn stop_gpx_route(&mut self) {
        if let Some(h) = self.route_handle.take() {
            h.abort();
        }
        self.route_profile = None;
        self.route_grade = 0.0;
        self.route_status = RouteStatus::default();
    }

    pub async fn start_gpx_route(&mut self, profile: GpxProfileInfo) -> Result<(), String> {
        self.stop_gpx_route();
        self.stop_workout();
        self.stop_interval();
        if !self.demo_mode && !self.snapshot.supports_simulation {
            return Err(
                "GPX simulation needs trainer sim support — use an ERG workout instead".into(),
            );
        }
        let name = profile.name.clone();
        let total = profile.distance_m;
        self.route_profile = Some(profile.clone());
        self.route_status = RouteStatus {
            running: true,
            route_name: name.clone(),
            distance_m: total,
            progress_m: 0.0,
            grade_pct: 0.0,
            complete: false,
            status_text: format!("{name} · starting…"),
        };
        self.route_grade = 0.0;
        let ctrl = controller();
        self.route_handle = Some(tokio::spawn(async move {
            let mut last = Instant::now();
            let start_dist = {
                let s = ride::stats();
                s.distance_km * 1000.0
            };
            loop {
                tokio::time::sleep(Duration::from_millis(250)).await;
                let dt = last.elapsed().as_secs_f64();
                last = Instant::now();
                let mut g = ctrl.lock().await;
                let Some(profile) = g.route_profile.clone() else {
                    break;
                };
                if !g.route_status.running {
                    break;
                }
                let stats = ride::stats();
                let progress = (stats.distance_km * 1000.0 - start_dist).max(0.0);
                // Demo / no-speed fallback: creep ~5 m/s so routes still complete.
                if progress < 0.5 && g.demo_mode {
                    // Advance synthetic progress via wall time from route start stored in status.
                    // Use grade driver elapsed approximation: accumulate in progress_m field.
                    let prev = g.route_status.progress_m;
                    let creep = prev + 5.0 * dt; // ~18 km/h
                    let progress = creep;
                    if progress >= profile.distance_m {
                        g.route_grade = 0.0;
                        let _ = g
                            .set_indoor_bike_simulation(
                                0.0,
                                0.0,
                                ftms::DEFAULT_SIM_CRR,
                                ftms::DEFAULT_SIM_CW,
                            )
                            .await;
                        g.route_status.running = false;
                        g.route_status.complete = true;
                        g.route_status.grade_pct = 0.0;
                        g.route_status.progress_m = profile.distance_m;
                        g.route_status.status_text =
                            format!("{} · Route complete", profile.name);
                        break;
                    }
                    let target = grade_at_distance(&profile, progress, 25.0);
                    let grade = slew_grade(g.route_grade, target, dt, 2.0);
                    g.route_grade = grade;
                    g.route_status.progress_m = progress;
                    g.route_status.grade_pct = grade;
                    g.route_status.status_text = format!(
                        "{} · {:.1}/{:.1} km · {grade:.1}%",
                        profile.name,
                        progress / 1000.0,
                        profile.distance_m / 1000.0
                    );
                    if g.erg_from_grade {
                        let speed = 5.0;
                        let w = gpx::watts_from_grade(grade, speed, g.rider_mass_kg);
                        let _ = g.set_target_power(w).await;
                    } else {
                        let _ = g
                            .set_indoor_bike_simulation(
                                0.0,
                                grade,
                                ftms::DEFAULT_SIM_CRR,
                                ftms::DEFAULT_SIM_CW,
                            )
                            .await;
                    }
                    continue;
                }
                if progress >= profile.distance_m {
                    g.route_grade = 0.0;
                    let _ = g
                        .set_indoor_bike_simulation(
                            0.0,
                            0.0,
                            ftms::DEFAULT_SIM_CRR,
                            ftms::DEFAULT_SIM_CW,
                        )
                        .await;
                    g.route_status.running = false;
                    g.route_status.complete = true;
                    g.route_status.grade_pct = 0.0;
                    g.route_status.progress_m = profile.distance_m;
                    g.route_status.status_text = format!("{} · Route complete", profile.name);
                    break;
                }
                let target = grade_at_distance(&profile, progress, 25.0);
                let grade = slew_grade(g.route_grade, target, dt, 2.0);
                g.route_grade = grade;
                g.route_status.progress_m = progress;
                g.route_status.grade_pct = grade;
                g.route_status.status_text = format!(
                    "{} · {:.1}/{:.1} km · {grade:.1}%",
                    profile.name,
                    progress / 1000.0,
                    profile.distance_m / 1000.0
                );
                if g.erg_from_grade {
                    let speed = (stats.distance_km.max(0.001) / (stats.elapsed_s.max(1) as f64 / 3600.0))
                        / 3.6;
                    let speed = if speed.is_finite() && speed > 0.5 {
                        speed
                    } else {
                        5.0
                    };
                    let w = gpx::watts_from_grade(grade, speed, g.rider_mass_kg);
                    let _ = g.set_target_power(w).await;
                } else {
                    let _ = g
                        .set_indoor_bike_simulation(
                            0.0,
                            grade,
                            ftms::DEFAULT_SIM_CRR,
                            ftms::DEFAULT_SIM_CW,
                        )
                        .await;
                }
            }
        }));
        Ok(())
    }
}

/// Scan without holding the controller mutex during BlueZ discovery (UI stays
/// responsive; sync FRB polls use [`try_snapshot`]).
pub async fn scan_trainers_unlocked(timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String> {
    let ctrl = controller();
    let demo = {
        let mut g = ctrl.lock().await;
        if g.demo_mode {
            g.backend = Backend::Demo(DemoTrainer::new());
            if let Backend::Demo(d) = &g.backend {
                return Ok(d.scan().await);
            }
        }
        g.snapshot.state = ConnectionState::Scanning;
        g.snapshot.detail = "Scanning for FTMS / Kickr / Tacx FE-C…".into();
        publish_snapshot(&g.snapshot);
        false
    };
    let _ = demo;
    let result = scan_ble(timeout_ms).await;
    let mut g = ctrl.lock().await;
    match result {
        Ok(v) => {
            // Never surface stub DEMO:* ids in a live BLE list.
            let v: Vec<_> = v
                .into_iter()
                .filter(|d| !d.id.starts_with("DEMO:"))
                .collect();
            g.snapshot.state = ConnectionState::Disconnected;
            g.snapshot.detail = format!("Found {} device(s)", v.len());
            publish_snapshot(&g.snapshot);
            Ok(v)
        }
        Err(e) => {
            let msg = friendly_ble_error(&e);
            g.snapshot.state = ConnectionState::Error;
            g.snapshot.detail = msg.clone();
            publish_snapshot(&g.snapshot);
            Err(msg)
        }
    }
}

/// Connect without holding the controller mutex during BlueZ GATT handshake.
/// Fixes Manual Connect freezing the Flutter UI on Linux (poll timer blocked
/// on sync `get_connection_snapshot` while the async mutex was held).
pub async fn connect_trainer_unlocked(device_id: Option<String>) -> Result<(), String> {
    let ctrl = controller();
    let prep = {
        let mut g = ctrl.lock().await;
        g.prepare_connect(device_id, false).await?
    };
    match prep {
        ConnectPrep::Done => Ok(()),
        ConnectPrep::Ble(id) => {
            let result = connect_ble(&id).await;
            let mut g = ctrl.lock().await;
            match result {
                Ok(session) => {
                    g.install_ble_session(session, id);
                    Ok(())
                }
                Err(e) => Err(g.fail_connect(e)),
            }
        }
    }
}

/// Manual Reconnect with the same unlocked BlueZ pattern as connect.
pub async fn reconnect_trainer_unlocked() -> Result<(), String> {
    let ctrl = controller();
    let (id, resume, preserve) = {
        let mut g = ctrl.lock().await;
        g.prepare_manual_reconnect().await?
    };
    let prep = {
        let mut g = ctrl.lock().await;
        // prepare_connect after tear-down; preserve intervals when needed.
        g.prepare_connect(Some(id), preserve).await?
    };
    match prep {
        ConnectPrep::Done => Ok(()),
        ConnectPrep::Ble(id) => {
            let result = connect_ble(&id).await;
            let mut g = ctrl.lock().await;
            match result {
                Ok(session) => {
                    g.install_ble_session(session, id);
                    if let Some(t) = resume {
                        g.apply_resume_target(t).await?;
                    }
                    Ok(())
                }
                Err(e) => Err(g.fail_connect(e)),
            }
        }
    }
}

fn friendly_ble_error(err: &str) -> String {
    let lower = err.to_lowercase();
    if lower.contains("busy") || lower.contains("in use") || lower.contains("already") {
        return format!(
            "Trainer busy or already connected elsewhere. Quit Zwift / Wahoo app / Tacx Training / MyWhoosh / TrainerRoad / Rouvy and retry. ({err})"
        );
    }
    if lower.contains("permission")
        || lower.contains("not authorized")
        || lower.contains("tcc")
        || lower.contains("denied")
        || lower.contains("org.bluez")
        || lower.contains("access denied")
    {
        #[cfg(target_os = "linux")]
        {
            return format!(
                "Bluetooth access denied. Garuda/Arch: install bluez bluez-utils; `systemctl enable --now bluetooth`; add yourself to the `bluetooth` group (then log out/in); ensure a D-Bus user session (Plasma login, never sudo the app); check polkit if prompted. ({err})"
            );
        }
        #[cfg(target_os = "macos")]
        {
            return format!(
                "Bluetooth permission denied. System Settings → Privacy & Security → Bluetooth → allow Tacx Desktop (TCC). ({err})"
            );
        }
        #[cfg(target_os = "windows")]
        {
            return format!(
                "Bluetooth permission denied. Settings → Bluetooth & devices: turn Bluetooth on and allow app access. ({err})"
            );
        }
        #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
        {
            return format!("Bluetooth permission denied. ({err})");
        }
    }
    if lower.contains("adapter")
        || lower.contains("no bluetooth")
        || lower.contains("powered off")
        || lower.contains("rfkill")
    {
        #[cfg(target_os = "linux")]
        {
            return format!(
                "Bluetooth adapter off or blocked. `rfkill unblock bluetooth`; `bluetoothctl power on`; Plasma tray Bluetooth On; `systemctl is-active bluetooth` should be active. Never run the app with sudo. ({err})"
            );
        }
        #[cfg(not(target_os = "linux"))]
        {
            return format!(
                "No Bluetooth adapter / radio off. Enable Bluetooth (Windows Settings → Bluetooth; macOS menu bar Bluetooth; Linux: bluetoothctl power on / rfkill). ({err})"
            );
        }
    }
    if lower.contains("control") || lower.contains("noctrl") {
        #[cfg(target_os = "linux")]
        {
            return format!(
                "Could not take exclusive control (NOCTRL). Quit Zwift / Wahoo app / other FTMS clients. In KDE/Plasma Bluetooth settings, remove/forget the trainer — do not OS-pair; connect only from Tacx Desktop. ({err})"
            );
        }
        #[cfg(not(target_os = "linux"))]
        {
            return format!(
                "Could not take exclusive control (NOCTRL). Quit Zwift / Wahoo app / other FTMS clients and retry. Do NOT OS-pair the trainer — leave it unpaired and connect only from this app. ({err})"
            );
        }
    }
    if lower.contains("paired") || lower.contains("bonding") || lower.contains("bond") {
        #[cfg(target_os = "linux")]
        {
            return format!(
                "OS Bluetooth pairing can break FTMS/FE-C control. Forget the trainer in KDE Bluetooth settings (unpaired), then Connect only from Tacx Desktop — never pair in the OS. ({err})"
            );
        }
        #[cfg(not(target_os = "linux"))]
        {
            return format!(
                "OS Bluetooth pairing can break FTMS control. Windows: remove/forget the trainer in Settings → Bluetooth. macOS: Forget This Device. Then Connect from Tacx Desktop only. ({err})"
            );
        }
    }
    if lower.contains("timed out") || lower.contains("timeout") {
        return format!(
            "Connect timed out. Wake the trainer (pedal), stand nearby, quit other apps, then Scan → Connect again. ({err})"
        );
    }
    err.to_string()
}

/// Shared adapter lookup (trainer + heart-rate strap).
pub(crate) async fn ble_adapter() -> Result<Adapter, String> {
    adapter().await
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
        let has_ftms = props.services.iter().any(|u| *u == ftms_uuid);
        let mfg: Vec<u16> = props.manufacturer_data.keys().copied().collect();
        // Empty ScanFilter + post-filter: Kickr FTMS, Tacx FE-C, generic FTMS.
        let Some(hint) = scan::advertise_protocol_hint(&name, has_ftms, &mfg) else {
            continue;
        };
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
    /// BlueZ/GATT handshakes can hang; never block the UI forever.
    const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
    const SESSION_TIMEOUT: Duration = Duration::from_secs(25);

    let central = adapter().await?;
    if let Ok(CentralState::PoweredOff) = central.adapter_state().await {
        return Err(BluetoothStatus::from_radio(BluetoothRadio::Off, None).hint);
    }
    // Empty ScanFilter (post-filter in scan_ble) — required so FE-C-only Tacx stay visible.
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

    // Stop discovery before connect — BlueZ is happier; keeps ads from racing GATT.
    central.stop_scan().await.ok();

    tokio::time::timeout(CONNECT_TIMEOUT, peripheral.connect())
        .await
        .map_err(|_| {
            "Connect timed out (BlueZ) — wake the trainer, quit other apps, Scan again".to_string()
        })?
        .map_err(|e| format!("Connect failed (busy trainer?): {e}"))?;

    match tokio::time::timeout(SESSION_TIMEOUT, open_session(&central, peripheral.clone(), device_id))
        .await
    {
        Ok(Ok(session)) => Ok(session),
        Ok(Err(e)) => {
            let _ = peripheral.disconnect().await;
            Err(e)
        }
        Err(_) => {
            let _ = peripheral.disconnect().await;
            Err(
                "GATT setup timed out — forget OS pairing (KDE Bluetooth), power-cycle trainer, retry"
                    .into(),
            )
        }
    }
}

/// GATT discovery, subscriptions and control handshake on a connected peripheral.
async fn open_session(
    central: &Adapter,
    peripheral: Peripheral,
    device_id: &str,
) -> Result<BleSession, String> {
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
    let link_lost = Arc::new(Notify::new());
    let mut simulation_supported = false;

    if has_ftms {
        // Prefer FTMS (even on Dual — FE-C UART stays unused while FTMS works).
        let mut resistance_range = ResistanceRange::default();
        let mut power_range = PowerRange::default();
        let mut max_resistance_raw: i16 = 1000;
        let mut resistance_char_present = false;
        let mut target_resistance_feature = false;

        if let Some(ch) = chars.iter().find(|c| c.uuid == ftms_res) {
            resistance_char_present = true;
            if let Ok(raw) = peripheral.read(ch).await {
                let (rr, max_raw) = ftms::parse_resistance_range(&raw);
                resistance_range = rr;
                max_resistance_raw = max_raw;
                log::info!(
                    "FTMS Supported Resistance Range (0x2AD6): max_raw={max_resistance_raw} → {resistance_range:?}"
                );
            } else {
                log::warn!("FTMS 0x2AD6 present but read failed");
            }
        } else {
            log::info!(
                "FTMS Supported Resistance Range (0x2AD6) absent — Resistance % may be unsupported (common on Kickr Bike)"
            );
        }
        if let Some(ch) = chars.iter().find(|c| c.uuid == ftms_pwr) {
            if let Ok(raw) = peripheral.read(ch).await {
                power_range = ftms::parse_power_range(&raw);
                log::info!("FTMS Supported Power Range (0x2AD8): {power_range:?}");
            }
        }
        let ftms_feature = uuid_from_u16(ftms::FEATURE);
        if let Some(ch) = chars.iter().find(|c| c.uuid == ftms_feature) {
            if let Ok(raw) = peripheral.read(ch).await {
                simulation_supported = ftms::features_support_simulation(&raw);
                target_resistance_feature = ftms::features_support_target_resistance(&raw);
                log::info!(
                    "FTMS Feature (0x2ACC): simulation(bit13)={simulation_supported} target_resistance(bit3)={target_resistance_feature} (public FTMS only — ignoring Wahoo proprietary a026*)"
                );
            }
        } else {
            log::info!("FTMS Feature (0x2ACC) absent — simulation gated off");
        }

        // Gate Resistance: need 0x2AD6 and/or Target Resistance feature bit.
        // Kickr Bike typically has neither — do not pretend default 0–100% works.
        let name_l = name.to_lowercase();
        let looks_kickr_bike = name_l.contains("kickr bike");
        let resistance_supported = if looks_kickr_bike && !resistance_char_present {
            false
        } else {
            resistance_char_present || target_resistance_feature
        };
        if !resistance_supported {
            resistance_range = ftms::unsupported_resistance_range();
            log::info!("Resistance % disabled for this trainer (no 0x2AD6 / target-resistance feature)");
        } else if !resistance_char_present {
            // Feature says resistance OK but range char missing — keep Tacx-tuned default encode.
            log::warn!(
                "Target Resistance advertised without 0x2AD6 — using default max_raw={max_resistance_raw}; verify % vs Wahoo app on hardware"
            );
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
        let lost_tx = link_lost.clone();
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
            lost_tx.notify_one();
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
                    "Request Control rejected: {e}. Quit Zwift / Wahoo app / MyWhoosh; leave trainer unpaired in OS Bluetooth."
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
            resistance_supported,
            link_lost,
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
        let lost_tx = link_lost.clone();
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
                            if let Some(hr) = fec::parse_general_fe_heart_rate(&msg) {
                                m.heart_rate_bpm = hr;
                            }
                        }
                    }
                    if !peri_n.is_connected().await.unwrap_or(true) {
                        break;
                    }
                }
            }
            alive_n.store(false, Ordering::SeqCst);
            lost_tx.notify_one();
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
            resistance_supported: true, // Tacx FE-C basic resistance always available
            link_lost,
        });
    }

    let _ = peripheral.disconnect().await;
    Err(format!(
        "Trainer has neither FTMS (0x1826) nor Tacx FE-C UART. Unsupported device. GATT: {gatt_summary}"
    ))
}

/// Automatic disconnect recovery (P0-UX-4 / P1-BLE-4): bounded backoff from
/// [`BackoffPolicy`]; stops on a stale token (user Disconnect / demo / manual
/// connect), on NOCTRL, or when the schedule is exhausted.
async fn auto_reconnect_loop(token: u64) {
    let ctrl = controller();
    let (id, policy, mut attempt) = {
        let mut g = ctrl.lock().await;
        let (alive, control_lost, old) = match &g.backend {
            Backend::Ble(b) => (
                b.alive.load(Ordering::SeqCst),
                b.control_lost.load(Ordering::SeqCst),
                Some(b.peripheral.clone()),
            ),
            Backend::Demo(_) => (true, false, None),
        };
        match reconnect::on_link_lost(
            g.reconnect_gate.is_current(token),
            g.demo_mode,
            alive,
            control_lost,
            g.last_device_id.is_some(),
        ) {
            LossDecision::Ignore => return,
            LossDecision::Blocked => {
                g.auto_reconnect = AutoReconnect::Blocked {
                    message: CONTROL_LOST_AT_DROP.into(),
                };
                return;
            }
            LossDecision::Retry => {}
        }
        // Release the stale link so the OS stack can reconnect cleanly.
        if let Some(p) = old {
            let _ = p.disconnect().await;
        }
        let policy = g.backoff.clone();
        let since = g
            .last_auto_success
            .map(|(at, n)| (at.elapsed(), n));
        let first = reconnect::starting_attempt(since);
        match policy.delay_before(first) {
            Some(d) => {
                g.auto_reconnect = AutoReconnect::Waiting {
                    attempt: first,
                    max: policy.max_attempts(),
                    next_at: Instant::now() + d,
                };
            }
            None => {
                g.auto_reconnect = AutoReconnect::GaveUp {
                    attempts: policy.max_attempts(),
                    last_error: "link keeps dropping right after reconnect".into(),
                };
                return;
            }
        }
        (g.last_device_id.clone().unwrap_or_default(), policy, first)
    };
    let max = policy.max_attempts();
    log::warn!("Trainer link lost — auto-reconnect to {id} (attempt {attempt}/{max})");
    let mut delay = policy.delay_before(attempt).unwrap_or_default();
    loop {
        tokio::time::sleep(delay).await;
        {
            let mut g = ctrl.lock().await;
            if !g.reconnect_gate.is_current(token) {
                return;
            }
            g.auto_reconnect = AutoReconnect::Attempting { attempt, max };
        }
        // BLE connect runs without the controller lock so the UI keeps
        // polling the snapshot ("reconnecting (n/m)…").
        let res = connect_ble(&id).await;
        let mut g = ctrl.lock().await;
        if !g.reconnect_gate.is_current(token) {
            // Cancelled mid-attempt: release the link unless the rider's own
            // connect already uses the same trainer.
            if let Ok(s) = res {
                let in_use = matches!(&g.backend, Backend::Ble(b)
                    if b.peripheral.id() == s.peripheral.id() && b.alive.load(Ordering::SeqCst));
                if !in_use {
                    let _ = s.peripheral.disconnect().await;
                }
            }
            return;
        }
        match res {
            Ok(session) => {
                g.finish_auto_reconnect(session, attempt).await;
                return;
            }
            Err(e) => {
                log::warn!("Auto-reconnect attempt {attempt}/{max} failed: {e}");
                match policy.after_failure(attempt, reconnect::classify_failure(&e)) {
                    NextStep::Retry {
                        attempt: next,
                        delay: d,
                    } => {
                        g.auto_reconnect = AutoReconnect::Waiting {
                            attempt: next,
                            max,
                            next_at: Instant::now() + d,
                        };
                        attempt = next;
                        delay = d;
                    }
                    NextStep::GiveUp => {
                        g.auto_reconnect = AutoReconnect::GaveUp {
                            attempts: attempt,
                            last_error: e,
                        };
                        return;
                    }
                    NextStep::Blocked => {
                        g.auto_reconnect = AutoReconnect::Blocked {
                            message: friendly_ble_error(&e),
                        };
                        return;
                    }
                }
            }
        }
    }
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
    if flags & 0x0200 != 0 {
        m.heart_rate_bpm = parsed.heart_rate_bpm;
    }
}

#[cfg(test)]
mod auto_reconnect_tests {
    use super::*;
    use tokio::sync::oneshot;

    /// Fake pending auto-reconnect task; the receiver errors once it is aborted.
    fn pending_task(c: &mut TrainerController, state: AutoReconnect) -> oneshot::Receiver<()> {
        let (tx, rx) = oneshot::channel::<()>();
        c.auto_reconnect = state;
        c.link_watch_handle = Some(tokio::spawn(async move {
            let _tx = tx;
            tokio::time::sleep(Duration::from_secs(60)).await;
        }));
        rx
    }

    fn waiting() -> AutoReconnect {
        AutoReconnect::Waiting {
            attempt: 2,
            max: 4,
            next_at: Instant::now() + Duration::from_secs(3),
        }
    }

    #[tokio::test]
    async fn user_disconnect_cancels_pending_retry() {
        let mut c = TrainerController::new();
        let token = c.reconnect_gate.token();
        let rx = pending_task(&mut c, waiting());
        c.disconnect().await.unwrap();
        assert!(!c.reconnect_gate.is_current(token));
        assert_eq!(c.auto_reconnect, AutoReconnect::Inactive);
        let r = tokio::time::timeout(Duration::from_secs(1), rx).await.unwrap();
        assert!(r.is_err(), "backoff sleep must be aborted");
    }

    #[tokio::test]
    async fn demo_switch_and_manual_connect_cancel() {
        let mut c = TrainerController::new();
        let t0 = c.reconnect_gate.token();
        let rx = pending_task(&mut c, waiting());
        c.set_demo_mode(true).await;
        assert!(!c.reconnect_gate.is_current(t0));
        assert!(tokio::time::timeout(Duration::from_secs(1), rx).await.unwrap().is_err());

        let t1 = c.reconnect_gate.token();
        let rx = pending_task(&mut c, waiting());
        c.connect(Some("demo".into())).await.unwrap();
        assert!(!c.reconnect_gate.is_current(t1));
        assert_eq!(c.auto_reconnect, AutoReconnect::Inactive);
        assert!(tokio::time::timeout(Duration::from_secs(1), rx).await.unwrap().is_err());
        c.disconnect().await.ok();
    }

    #[tokio::test]
    async fn cancel_mid_attempt_invalidates_token_without_abort() {
        let mut c = TrainerController::new();
        let token = c.reconnect_gate.token();
        let mut rx = pending_task(&mut c, AutoReconnect::Attempting { attempt: 1, max: 4 });
        c.disconnect().await.unwrap();
        tokio::task::yield_now().await;
        // Not aborted (could orphan a half-open BLE link) — it will see the
        // stale token and clean up itself.
        assert!(matches!(rx.try_recv(), Err(oneshot::error::TryRecvError::Empty)));
        assert!(!c.reconnect_gate.is_current(token));
        assert_eq!(c.auto_reconnect, AutoReconnect::Inactive);
    }

    #[test]
    fn demo_snapshot_never_reports_reconnecting() {
        let mut c = TrainerController::new();
        c.auto_reconnect = waiting();
        let s = c.snapshot();
        assert_ne!(s.state, ConnectionState::Reconnecting);
        assert_eq!(s.reconnect_attempt, 0);
    }
}


#[cfg(test)]
mod ui_poll_freeze_tests {
    use super::*;
    use std::time::Duration;

    #[tokio::test]
    async fn try_snapshot_works_while_controller_locked() {
        ensure_runtime();
        let ctrl = controller();
        {
            let mut g = ctrl.lock().await;
            g.snapshot.state = ConnectionState::Connecting;
            g.snapshot.detail = "Connecting to test…".into();
            publish_snapshot(&g.snapshot);
            // Hold the async mutex like a buggy locked connect would.
            let snap = try_snapshot();
            assert_eq!(snap.state, ConnectionState::Connecting);
            assert!(snap.detail.contains("Connecting"));
            // Keep lock for a beat — try_snapshot must not await the mutex.
            tokio::time::sleep(Duration::from_millis(50)).await;
            let snap2 = try_snapshot();
            assert_eq!(snap2.state, ConnectionState::Connecting);
        }
        // Unlocked again — live snapshot still readable.
        let _ = try_snapshot();
    }

    #[test]
    fn scratch_controller_does_not_publish() {
        let c = TrainerController::new();
        assert!(!c.publishes);
        assert!(TrainerController::new_global().publishes);
    }

    #[tokio::test]
    async fn set_demo_mode_off_keeps_is_demo_false_in_snapshot() {
        let mut c = TrainerController::new();
        assert!(!c.is_demo(), "default must be live BLE (demo off)");
        assert!(!c.snapshot().is_demo);
        c.set_demo_mode(true).await;
        assert!(c.is_demo());
        assert!(c.snapshot().is_demo);
        assert_eq!(c.snapshot().protocol, ProtocolKind::Demo);
        c.set_demo_mode(false).await;
        assert!(!c.is_demo());
        let s = c.snapshot();
        assert!(!s.is_demo, "toggle off must stick; was forced true by Demo backend");
        assert_ne!(s.protocol, ProtocolKind::Demo);
    }

    #[tokio::test]
    async fn unlocked_demo_connect_publishes_connected() {
        ensure_runtime();
        let ctrl = controller();
        {
            let mut g = ctrl.lock().await;
            g.set_demo_mode(true).await;
        }
        connect_trainer_unlocked(Some("DEMO:00:11:22:33:44:55".into()))
            .await
            .expect("demo connect");
        let snap = try_snapshot();
        assert_eq!(snap.state, ConnectionState::Connected);
        assert!(snap.is_demo);
    }
}

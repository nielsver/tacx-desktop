//! Global trainer controller: demo by default; live BLE via btleplug (FTMS → FE-C fallback).

use crate::trainer::demo::DemoTrainer;
use crate::trainer::fec;
use crate::trainer::ftms;
use crate::trainer::intervals::IntervalEngine;
use crate::trainer::types::*;
use btleplug::api::{
    bleuuid::uuid_from_u16, Central, Characteristic, Manager as _, Peripheral as _, ScanFilter,
    WriteType,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use once_cell::sync::OnceCell;
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::Duration;
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
}

pub struct TrainerController {
    demo_mode: bool,
    backend: Backend,
    snapshot: ConnectionSnapshot,
    intervals: IntervalEngine,
    interval_handle: Option<tokio::task::JoinHandle<()>>,
    demo_tick_handle: Option<tokio::task::JoinHandle<()>>,
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
                s
            }
            Backend::Ble(b) => ConnectionSnapshot {
                state: ConnectionState::Connected,
                detail: b.device_name.clone(),
                protocol: b.protocol.clone(),
                is_demo: false,
                mode: b.mode.lock().clone(),
                device_name: b.device_name.clone(),
            },
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
        self.stop_interval();
        if let Some(h) = self.demo_tick_handle.take() {
            h.abort();
        }

        if self.demo_mode {
            self.backend = Backend::Demo(DemoTrainer::new());
            if let Backend::Demo(d) = &self.backend {
                d.connect(device_id).await?;
                self.snapshot = d.snapshot.lock().clone();
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
                self.snapshot.protocol = session.protocol.clone();
                self.snapshot.mode = ControlMode::Idle;
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
                let w = watts.clamp(b.power_range.min_w, b.power_range.max_w);
                match b.protocol {
                    ProtocolKind::Ftms => {
                        let ch = b
                            .control_char
                            .as_ref()
                            .ok_or_else(|| "FTMS Control Point missing".to_string())?;
                        let payload = ftms::encode_set_target_power(w as i16);
                        b.peripheral
                            .write(ch, &payload, WriteType::WithResponse)
                            .await
                            .map_err(|e| format!("FTMS set power failed: {e}"))?;
                    }
                    ProtocolKind::TacxFecBle => {
                        let ch = b
                            .fec_rx
                            .as_ref()
                            .ok_or_else(|| "Tacx FE-C RX characteristic missing".to_string())?;
                        let payload = fec::encode_target_power(w);
                        b.peripheral
                            .write(ch, &payload, WriteType::WithoutResponse)
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
                let p = percent.clamp(b.resistance_range.min_pct, b.resistance_range.max_pct);
                match b.protocol {
                    ProtocolKind::Ftms => {
                        let ch = b
                            .control_char
                            .as_ref()
                            .ok_or_else(|| "FTMS Control Point missing".to_string())?;
                        let payload = ftms::encode_set_resistance(p, b.max_resistance_raw);
                        b.peripheral
                            .write(ch, &payload, WriteType::WithResponse)
                            .await
                            .map_err(|e| format!("FTMS set resistance failed: {e}"))?;
                    }
                    ProtocolKind::TacxFecBle => {
                        let ch = b
                            .fec_rx
                            .as_ref()
                            .ok_or_else(|| "Tacx FE-C RX characteristic missing".to_string())?;
                        let payload =
                            fec::encode_basic_resistance_newtons(fec::percent_to_newtons(p));
                        b.peripheral
                            .write(ch, &payload, WriteType::WithoutResponse)
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
    if lower.contains("permission") || lower.contains("not authorized") {
        return format!(
            "Bluetooth permission denied. On macOS enable Bluetooth for the app; on Linux ensure BlueZ + user in `bluetooth` group. ({err})"
        );
    }
    if lower.contains("adapter") || lower.contains("no bluetooth") {
        return format!(
            "No Bluetooth adapter found. Enable Bluetooth (BlueZ on Linux). ({err})"
        );
    }
    if lower.contains("control") || lower.contains("noctrl") {
        return format!(
            "Could not take exclusive control (NOCTRL). Disconnect other FTMS clients and retry. ({err})"
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

async fn scan_ble(timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String> {
    let central = adapter().await?;
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
    let ftms_bike = uuid_from_u16(ftms::INDOOR_BIKE_DATA);
    let ftms_cp = uuid_from_u16(ftms::CONTROL_POINT);
    let ftms_res = uuid_from_u16(ftms::SUPPORTED_RESISTANCE_RANGE);
    let ftms_pwr = uuid_from_u16(ftms::SUPPORTED_POWER_RANGE);
    let fec_rx = fec::tacx_uart_rx();
    let fec_tx = fec::tacx_uart_tx();

    let has_ftms = chars.iter().any(|c| c.uuid == ftms_bike || c.uuid == ftms_cp);
    let has_fec = chars.iter().any(|c| c.uuid == fec_rx || c.uuid == fec_tx);

    let name = peripheral
        .properties()
        .await
        .ok()
        .flatten()
        .and_then(|p| p.local_name)
        .unwrap_or_else(|| device_id.to_string());

    let metrics = Arc::new(Mutex::new(TrainerMetrics::default()));
    let mode = Arc::new(Mutex::new(ControlMode::Idle));

    if has_ftms {
        // Prefer FTMS
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

        peripheral
            .subscribe(&bike_ch)
            .await
            .map_err(|e| format!("Subscribe Indoor Bike Data failed: {e}"))?;
        let _ = peripheral.subscribe(&cp_ch).await;

        // Request control + start/resume
        peripheral
            .write(
                &cp_ch,
                &ftms::encode_request_control(),
                WriteType::WithResponse,
            )
            .await
            .map_err(|e| format!("Request Control failed (NOCTRL?): {e}"))?;
        let _ = peripheral
            .write(
                &cp_ch,
                &ftms::encode_start_resume(),
                WriteType::WithResponse,
            )
            .await;

        // Notification pump
        let metrics_n = metrics.clone();
        let peri_n = peripheral.clone();
        tokio::spawn(async move {
            if let Ok(mut stream) = peri_n.notifications().await {
                while let Some(n) = stream.next().await {
                    if n.uuid == ftms_bike {
                        let parsed = ftms::parse_indoor_bike_data(&n.value);
                        let mut m = metrics_n.lock();
                        if parsed.power_w != 0.0 || m.power_w == 0.0 {
                            // always apply parsed fields that were present — parser zeros missing
                            // Better: merge non-default. For simplicity overwrite when flags had data.
                        }
                        // Merge carefully: parser returns 0 for missing; use bit presence via re-parse flags
                        merge_ftms_metrics(&mut m, &n.value);
                    }
                }
            }
        });

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
                }
            }
        });

        central.stop_scan().await.ok();
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
        });
    }

    let _ = peripheral.disconnect().await;
    Err(
        "Trainer has neither FTMS (0x1826) nor Tacx FE-C UART. Unsupported device.".into(),
    )
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

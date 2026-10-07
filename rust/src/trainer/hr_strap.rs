//! Separate Bluetooth heart-rate strap (Heart Rate Service 0x180D,
//! Heart Rate Measurement 0x2A37) — Garmin HRM-Dual/Pro, Polar H9/H10,
//! Wahoo TICKR, Coospo, … over BLE.
//!
//! Runs next to the trainer link: its own peripheral, its own notification
//! pump and its own state, so a strap dropout never touches trainer control.
//! While a fresh strap reading exists it overrides any HR the trainer relays
//! (see [`overlay`]), so the live card, ride avg/max and the TCX export all use
//! the chest strap.

use crate::trainer::types::{DiscoveredDevice, HrStrapState, HrStrapStatus};
use btleplug::api::{
    bleuuid::uuid_from_u16, Central, CentralState, Peripheral as _, ScanFilter,
};
use btleplug::platform::Peripheral;
use futures::StreamExt;
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::time::{Duration, Instant};

pub const HEART_RATE_SERVICE: u16 = 0x180D;
pub const HEART_RATE_MEASUREMENT: u16 = 0x2A37;

/// A reading older than this is treated as "no heart rate" (strap off the
/// chest, out of range or link stalling) so the trainer's HR can show again.
pub const STALE_AFTER: Duration = Duration::from_secs(5);

/// Parse a Heart Rate Measurement (0x2A37) notification → bpm.
///
/// Flags bit 0 selects a UINT8 or UINT16 value; bits 1–2 are sensor contact
/// (a strap that reports "supported but no contact" yields `None`); the
/// energy-expended and RR-interval fields that may follow are ignored.
pub fn parse_heart_rate_measurement(data: &[u8]) -> Option<u32> {
    let flags = *data.first()?;
    let bpm = if flags & 0x01 != 0 {
        u16::from_le_bytes([*data.get(1)?, *data.get(2)?]) as u32
    } else {
        *data.get(1)? as u32
    };
    let contact_supported = flags & 0x04 != 0;
    let contact_detected = flags & 0x02 != 0;
    if contact_supported && !contact_detected {
        return None;
    }
    // 0 = no reading; >250 is noise from a strap still settling.
    (1..=250).contains(&bpm).then_some(bpm)
}

struct StrapInner {
    state: HrStrapState,
    device_id: String,
    device_name: String,
    detail: String,
    last: Option<(u32, Instant)>,
    peripheral: Option<Peripheral>,
    /// Bumped on every connect/disconnect so an old pump can't overwrite a
    /// newer session's state when its stream ends.
    generation: u64,
}

static STRAP: Lazy<Mutex<StrapInner>> = Lazy::new(|| {
    Mutex::new(StrapInner {
        state: HrStrapState::Disconnected,
        device_id: String::new(),
        device_name: String::new(),
        detail: String::new(),
        last: None,
        peripheral: None,
        generation: 0,
    })
});

fn fresh_bpm(inner: &StrapInner, now: Instant) -> Option<u32> {
    match inner.last {
        Some((bpm, at)) if inner.state == HrStrapState::Connected
            && now.saturating_duration_since(at) <= STALE_AFTER =>
        {
            Some(bpm)
        }
        _ => None,
    }
}

/// Current strap heart rate, if connected and fresh.
pub fn current_bpm() -> Option<u32> {
    fresh_bpm(&STRAP.lock(), Instant::now())
}

/// Replace the trainer-relayed HR with the strap's when one is fresh.
pub fn overlay(m: &mut crate::trainer::types::TrainerMetrics) {
    if let Some(bpm) = current_bpm() {
        m.heart_rate_bpm = Some(bpm);
    }
}

/// UI status (sync, never blocks on BLE).
pub fn status() -> HrStrapStatus {
    let g = STRAP.lock();
    HrStrapStatus {
        state: g.state,
        device_id: g.device_id.clone(),
        device_name: g.device_name.clone(),
        detail: g.detail.clone(),
        heart_rate_bpm: fresh_bpm(&g, Instant::now()),
    }
}

fn set_state(generation: u64, state: HrStrapState, detail: impl Into<String>) {
    let mut g = STRAP.lock();
    if g.generation != generation {
        return;
    }
    g.state = state;
    g.detail = detail.into();
    if state != HrStrapState::Connected {
        g.last = None;
        g.peripheral = None;
    }
}

fn record(generation: u64, bpm: Option<u32>) {
    let mut g = STRAP.lock();
    if g.generation != generation {
        return;
    }
    g.last = bpm.map(|b| (b, Instant::now()));
}

/// Scan for devices advertising the Heart Rate Service (0x180D).
pub async fn scan(timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String> {
    let central = crate::trainer::controller::ble_adapter().await?;
    if let Ok(CentralState::PoweredOff) = central.adapter_state().await {
        return Err("Bluetooth is off — turn it on, then search for the strap again".into());
    }
    let hr_uuid = uuid_from_u16(HEART_RATE_SERVICE);
    central
        .start_scan(ScanFilter::default())
        .await
        .map_err(|e| format!("Scan failed: {e}"))?;
    tokio::time::sleep(Duration::from_millis(timeout_ms.max(1000) as u64)).await;
    let peripherals = central
        .peripherals()
        .await
        .map_err(|e| format!("List peripherals failed: {e}"))?;
    let mut out = Vec::new();
    for p in peripherals {
        let Ok(Some(props)) = p.properties().await else {
            continue;
        };
        let name = props.local_name.clone().unwrap_or_else(|| "(unknown)".into());
        let name_l = name.to_lowercase();
        let has_hr = props.services.iter().any(|u| *u == hr_uuid);
        let looks_hr = ["hrm", "polar h", "tickr", "heart"].iter().any(|k| name_l.contains(k));
        if !(has_hr || looks_hr) {
            continue;
        }
        out.push(DiscoveredDevice {
            id: p.id().to_string(),
            name,
            rssi: props.rssi.map(|v| v as i32),
            protocol_hint: "heart_rate".into(),
        });
    }
    central.stop_scan().await.ok();
    out.sort_by(|a, b| b.rssi.unwrap_or(-999).cmp(&a.rssi.unwrap_or(-999)));
    Ok(out)
}

/// Connect to a strap and start streaming HR. Replaces any current strap.
pub async fn connect(device_id: String) -> Result<(), String> {
    disconnect().await;
    let generation = {
        let mut g = STRAP.lock();
        g.generation += 1;
        g.state = HrStrapState::Connecting;
        g.device_id = device_id.clone();
        g.detail = "Connecting to heart-rate strap…".into();
        g.generation
    };
    match tokio::time::timeout(Duration::from_secs(20), open(&device_id)).await {
        Ok(Ok((peripheral, name))) => {
            let cancelled = {
                let mut g = STRAP.lock();
                if g.generation != generation {
                    true
                } else {
                    g.state = HrStrapState::Connected;
                    g.device_name = name.clone();
                    g.detail = format!("{name} connected");
                    g.peripheral = Some(peripheral.clone());
                    false
                }
            };
            if cancelled {
                let _ = peripheral.disconnect().await;
                return Err("Strap connect was cancelled".into());
            }
            spawn_pump(generation, peripheral);
            Ok(())
        }
        Ok(Err(e)) => {
            set_state(generation, HrStrapState::Error, e.clone());
            Err(e)
        }
        Err(_) => {
            let e = "Strap connect timed out — wet the strap contacts, wear it, then search again"
                .to_string();
            set_state(generation, HrStrapState::Error, e.clone());
            Err(e)
        }
    }
}

async fn open(device_id: &str) -> Result<(Peripheral, String), String> {
    let central = crate::trainer::controller::ble_adapter().await?;
    central
        .start_scan(ScanFilter::default())
        .await
        .map_err(|e| format!("Scan before connect failed: {e}"))?;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let peripheral = central
        .peripherals()
        .await
        .map_err(|e| format!("List peripherals failed: {e}"))?
        .into_iter()
        .find(|p| p.id().to_string() == device_id)
        .ok_or_else(|| "Strap not found — wear it (it sleeps when dry), then search again".to_string())?;
    central.stop_scan().await.ok();
    let name = peripheral
        .properties()
        .await
        .ok()
        .flatten()
        .and_then(|p| p.local_name)
        .unwrap_or_else(|| "Heart-rate strap".into());
    peripheral
        .connect()
        .await
        .map_err(|e| format!("Strap connect failed: {e}"))?;
    let setup = async {
        peripheral
            .discover_services()
            .await
            .map_err(|e| format!("Strap GATT discovery failed: {e}"))?;
        let hrm = uuid_from_u16(HEART_RATE_MEASUREMENT);
        let ch = peripheral
            .characteristics()
            .into_iter()
            .find(|c| c.uuid == hrm)
            .ok_or("Device has no Heart Rate Measurement (0x2A37) — not an HR strap?")?;
        peripheral
            .subscribe(&ch)
            .await
            .map_err(|e| format!("Subscribe Heart Rate Measurement failed: {e}"))
    };
    if let Err(e) = setup.await {
        let _ = peripheral.disconnect().await;
        return Err(e);
    }
    Ok((peripheral, name))
}

fn spawn_pump(generation: u64, peripheral: Peripheral) {
    let hrm = uuid_from_u16(HEART_RATE_MEASUREMENT);
    crate::trainer::controller::runtime().spawn(async move {
        if let Ok(mut stream) = peripheral.notifications().await {
            while let Some(n) = stream.next().await {
                if n.uuid == hrm {
                    record(generation, parse_heart_rate_measurement(&n.value));
                }
            }
        }
        set_state(
            generation,
            HrStrapState::Disconnected,
            "Heart-rate strap disconnected — search again to reconnect",
        );
    });
}

/// Drop the strap (no-op when none). Trainer HR, if any, shows again.
pub async fn disconnect() {
    let peripheral = {
        let mut g = STRAP.lock();
        g.generation += 1;
        g.state = HrStrapState::Disconnected;
        g.detail.clear();
        g.last = None;
        g.peripheral.take()
    };
    if let Some(p) = peripheral {
        let _ = p.disconnect().await;
    }
}

#[cfg(test)]
pub(crate) fn inject_for_test(bpm: Option<u32>, age: Duration) {
    let mut g = STRAP.lock();
    g.generation += 1;
    g.state = if bpm.is_some() { HrStrapState::Connected } else { HrStrapState::Disconnected };
    g.device_name = "Test HRM".into();
    g.last = bpm.map(|b| (b, Instant::now() - age));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trainer::types::TrainerMetrics;

    #[test]
    fn uint8_value() {
        // flags 0x00: UINT8, contact not supported.
        assert_eq!(parse_heart_rate_measurement(&[0x00, 72]), Some(72));
    }

    #[test]
    fn uint16_value_with_rr_intervals() {
        // flags 0x11: UINT16 + RR present; 0x009C = 156 bpm, then RR 0x0300.
        assert_eq!(parse_heart_rate_measurement(&[0x11, 0x9C, 0x00, 0x00, 0x03]), Some(156));
    }

    #[test]
    fn energy_expended_is_skipped() {
        // flags 0x08: UINT8 + energy expended (2 bytes) follows the value.
        assert_eq!(parse_heart_rate_measurement(&[0x08, 130, 0x10, 0x00]), Some(130));
    }

    #[test]
    fn contact_supported_but_lost_is_none() {
        assert_eq!(parse_heart_rate_measurement(&[0x04, 90]), None);
        assert_eq!(parse_heart_rate_measurement(&[0x06, 90]), Some(90));
    }

    #[test]
    fn zero_short_and_noise_are_none() {
        assert_eq!(parse_heart_rate_measurement(&[0x00, 0]), None);
        assert_eq!(parse_heart_rate_measurement(&[0x01, 0x10]), None);
        assert_eq!(parse_heart_rate_measurement(&[]), None);
        assert_eq!(parse_heart_rate_measurement(&[0x01, 0x2C, 0x01]), None); // 300
    }

    // One test owns the global strap state so parallel tests can't race it.
    #[test]
    fn overlay_prefers_fresh_strap_and_falls_back_when_stale() {
        let trainer = TrainerMetrics { heart_rate_bpm: Some(120), ..Default::default() };

        inject_for_test(Some(141), Duration::from_secs(1));
        let mut m = trainer.clone();
        overlay(&mut m);
        assert_eq!(m.heart_rate_bpm, Some(141));
        assert_eq!(status().heart_rate_bpm, Some(141));
        assert_eq!(status().state, HrStrapState::Connected);

        inject_for_test(Some(141), STALE_AFTER + Duration::from_secs(1));
        let mut m = trainer.clone();
        overlay(&mut m);
        assert_eq!(m.heart_rate_bpm, Some(120), "stale strap must not mask trainer HR");

        inject_for_test(None, Duration::ZERO);
        let mut m = TrainerMetrics::default();
        overlay(&mut m);
        assert_eq!(m.heart_rate_bpm, None);

        // A pump from an older session can't resurrect state.
        inject_for_test(Some(100), Duration::ZERO);
        let old = STRAP.lock().generation - 1;
        record(old, Some(180));
        set_state(old, HrStrapState::Disconnected, "old");
        assert_eq!(current_bpm(), Some(100));
        inject_for_test(None, Duration::ZERO);
    }
}

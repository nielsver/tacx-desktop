//! Flutter-facing trainer API (flutter_rust_bridge).

use crate::trainer::controller::{controller, ensure_runtime, runtime};
use crate::trainer::intervals;
use crate::trainer::types::*;

fn block_on<F, T>(fut: F) -> T
where
    F: std::future::Future<Output = T>,
{
    ensure_runtime();
    runtime().block_on(fut)
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_demo_mode(enabled: bool) {
    block_on(async {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.set_demo_mode(enabled).await;
    });
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_demo_mode() -> bool {
    block_on(async {
        let ctrl = controller();
        let g = ctrl.lock().await;
        g.is_demo()
    })
}

/// Host Bluetooth radio state for the empty-state banner (demo → NotNeeded).
pub async fn bluetooth_status() -> BluetoothStatus {
    let demo = {
        let ctrl = controller();
        let g = ctrl.lock().await;
        g.is_demo()
    };
    if demo {
        return BluetoothStatus::from_radio(BluetoothRadio::NotNeeded, None);
    }
    crate::trainer::controller::probe_bluetooth().await
}

pub async fn scan_trainers(timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String> {
    // Unlocked: BlueZ scan must not hold the controller mutex (UI poll freeze).
    crate::trainer::controller::scan_trainers_unlocked(timeout_ms).await
}

pub async fn connect_trainer(device_id: Option<String>) -> Result<(), String> {
    // Unlocked: BlueZ connect/GATT outside the mutex so Flutter stays responsive.
    crate::trainer::controller::connect_trainer_unlocked(device_id).await
}

pub async fn reconnect_trainer() -> Result<(), String> {
    crate::trainer::controller::reconnect_trainer_unlocked().await
}

pub async fn disconnect_trainer() -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.disconnect().await
}

pub async fn set_target_power(watts: u32) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.set_target_power(watts).await
}

pub async fn set_resistance_percent(percent: f64) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.set_resistance(percent).await
}

/// Track/grade simulation: FE-C page 0x33 or FTMS Indoor Bike Simulation (0x11).
pub async fn set_track_resistance(grade_pct: f64, crr: f64) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.set_track_resistance(grade_pct, crr).await
}

/// FE-C Wind Resistance (page 0x32).
pub async fn set_wind_resistance(
    wind_resistance_coefficient: f64,
    wind_speed_kmh: f64,
    drafting_factor: f64,
) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.set_wind_resistance(wind_resistance_coefficient, wind_speed_kmh, drafting_factor)
        .await
}

/// FE-C User Configuration (page 0x37).
pub async fn set_user_configuration(
    user_weight_kg: f64,
    bicycle_weight_kg: f64,
    wheel_diameter_m: f64,
    gear_ratio: f64,
) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.set_user_configuration(
        user_weight_kg,
        bicycle_weight_kg,
        wheel_diameter_m,
        gear_ratio,
    )
    .await
}

/// FTMS `0x11` or FE-C Track+Wind simulation parameters.
pub async fn set_indoor_bike_simulation(
    wind_speed_mps: f64,
    grade_pct: f64,
    crr: f64,
    cw: f64,
) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.set_indoor_bike_simulation(wind_speed_mps, grade_pct, crr, cw)
        .await
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_metrics() -> TrainerMetrics {
    // Non-blocking: never stall the Flutter UI isolate behind BlueZ connect.
    crate::trainer::controller::try_metrics()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_connection_snapshot() -> ConnectionSnapshot {
    crate::trainer::controller::try_snapshot()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_resistance_range() -> ResistanceRange {
    crate::trainer::controller::try_resistance_range()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_power_range() -> PowerRange {
    crate::trainer::controller::try_power_range()
}

#[flutter_rust_bridge::frb(sync)]
pub fn list_interval_presets() -> Vec<IntervalPresetInfo> {
    intervals::presets()
}

pub async fn start_interval(key: String) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.start_interval(key).await
}

#[flutter_rust_bridge::frb(sync)]
pub fn stop_interval() {
    block_on(async {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.stop_interval();
    });
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_interval_status() -> IntervalStatus {
    crate::trainer::controller::try_interval_status()
}

/// Ride totals since connect / last reset (1 Hz sampler in Rust).
#[flutter_rust_bridge::frb(sync)]
pub fn get_ride_stats() -> RideStats {
    ensure_runtime();
    crate::trainer::ride::stats()
}

/// Zero the ride totals (keeps recording if a trainer is connected).
#[flutter_rust_bridge::frb(sync)]
pub fn reset_ride_stats() {
    crate::trainer::ride::reset();
}

/// Headless smoke test used by CI / README.
pub async fn run_headless_demo_smoke() -> Result<String, String> {
    {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.set_demo_mode(true).await;
        let devices = g.scan(500).await?;
        if devices.is_empty() {
            return Err("demo scan empty".into());
        }
        g.connect(Some(devices[0].id.clone())).await?;
        g.set_target_power(200).await?;
    }
    tokio::time::sleep(std::time::Duration::from_millis(600)).await;
    {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        let m = g.metrics();
        if m.target_power_w != Some(200.0) {
            return Err(format!("expected target 200, got {:?}", m.target_power_w));
        }
        g.set_resistance(40.0).await?;
        if g.metrics().resistance_pct != Some(40.0) {
            return Err("resistance not set".into());
        }
        g.start_interval("10x30_30".into()).await?;
    }
    tokio::time::sleep(std::time::Duration::from_millis(800)).await;
    {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.stop_interval();
        g.disconnect().await?;
    }
    Ok("HEADLESS DEMO OK".into())
}

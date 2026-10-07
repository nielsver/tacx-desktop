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

pub async fn scan_trainers(timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.scan(timeout_ms).await
}

pub async fn connect_trainer(device_id: Option<String>) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.connect(device_id).await
}

pub async fn reconnect_trainer() -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    g.reconnect().await
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

#[flutter_rust_bridge::frb(sync)]
pub fn get_metrics() -> TrainerMetrics {
    block_on(async {
        let ctrl = controller();
        let g = ctrl.lock().await;
        g.metrics()
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_connection_snapshot() -> ConnectionSnapshot {
    block_on(async {
        let ctrl = controller();
        let g = ctrl.lock().await;
        g.snapshot()
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_resistance_range() -> ResistanceRange {
    block_on(async {
        let ctrl = controller();
        let g = ctrl.lock().await;
        g.resistance_range()
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_power_range() -> PowerRange {
    block_on(async {
        let ctrl = controller();
        let g = ctrl.lock().await;
        g.power_range()
    })
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
    block_on(async {
        let ctrl = controller();
        let g = ctrl.lock().await;
        g.interval_status()
    })
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

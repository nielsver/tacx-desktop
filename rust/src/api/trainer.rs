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

/// Trainer data-link health: packets/s over 5 s, last-packet age and a
/// Good (< 1.5 s) / Stale (< 4 s) / Lost level. Lock-free, cheap at 4 Hz.
#[flutter_rust_bridge::frb(sync)]
pub fn get_link_health() -> LinkHealth {
    crate::trainer::link_health::trainer_link_health()
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

/// Post-ride analysis of the current recording: NP / IF / TSS, mean-max
/// power (5 s, 1 min, 5 min, 20 min), time in zone and chart series.
/// Pass `ftp_w = 0` when FTP is unknown (IF, TSS and zones stay empty).
#[flutter_rust_bridge::frb(sync)]
pub fn get_ride_summary(ftp_w: u32) -> RideSummary {
    ensure_runtime();
    crate::trainer::ride::summary(ftp_w)
}

// ---- Ride efforts (QA c4 P1-1; ride-boundary checklist option a) ----

/// Open an effort. Same kind → same id; a different kind supersedes the
/// open one. `demo` is captured here and never changes.
#[flutter_rust_bridge::frb(sync)]
pub fn begin_effort(kind: EffortKind, demo: bool) -> u32 {
    crate::trainer::ride::begin_effort(kind, demo)
}

/// Close the open effort and emit one `RideEnded`. Idempotent: with none
/// open, returns the last closed slice and emits nothing.
#[flutter_rust_bridge::frb(sync)]
pub fn end_effort(completed: bool) -> Option<RideSlice> {
    crate::trainer::ride::end_effort(completed)
}

#[flutter_rust_bridge::frb(sync)]
pub fn current_effort() -> Option<RideSlice> {
    crate::trainer::ride::current_effort()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_effort(id: u32) -> Option<RideSlice> {
    crate::trainer::ride::effort(id)
}

/// Efforts of this session, oldest first.
#[flutter_rust_bridge::frb(sync)]
pub fn list_efforts() -> Vec<RideSlice> {
    crate::trainer::ride::list_efforts()
}

#[flutter_rust_bridge::frb(sync)]
pub fn effort_summary(id: u32, ftp_w: u32) -> Option<RideSummary> {
    crate::trainer::ride::effort_summary(id, ftp_w)
}

/// Lap totals of effort `id` (what its TCX lap reports).
#[flutter_rust_bridge::frb(sync)]
pub fn effort_stats(id: u32) -> Option<RideStats> {
    crate::trainer::ride::effort_stats(id)
}

/// Save effort `id` as TCX (`tacx-ride-<UTC>[-demo].tcx`).
pub fn export_effort_tcx(id: u32, dir: Option<String>) -> Result<String, String> {
    let dir = dir.filter(|d| !d.trim().is_empty()).map(std::path::PathBuf::from);
    crate::trainer::ride::export_effort_tcx(id, dir.as_deref()).map(|p| p.display().to_string())
}

/// Step-5 pause: no points, no moving time while paused.
#[flutter_rust_bridge::frb(sync)]
pub fn set_ride_paused(paused: bool) {
    crate::trainer::ride::set_paused(paused);
}

/// Recorder events (`RideEnded { slice_id }`), the hook step 5's remote
/// End & Save will reuse.
pub fn ride_events(sink: crate::frb_generated::StreamSink<RideEvent>) {
    crate::trainer::ride::on_ride_event(move |e| {
        let _ = sink.add(e.clone());
    });
}

/// Zero the ride totals (keeps recording if a trainer is connected).
#[flutter_rust_bridge::frb(sync)]
pub fn reset_ride_stats() {
    crate::trainer::ride::reset();
}

/// Save the current ride as a Garmin TCX file (Garmin Connect / Strava /
/// intervals.icu upload). `dir = None` writes to `~/Documents/Tacx Desktop`.
/// Returns the full path of the written file.
pub fn export_ride_tcx(dir: Option<String>) -> Result<String, String> {
    let dir = dir.filter(|d| !d.trim().is_empty()).map(std::path::PathBuf::from);
    crate::trainer::ride::export_tcx(dir.as_deref()).map(|p| p.display().to_string())
}

/// Folder [`export_ride_tcx`] uses when no directory is given.
#[flutter_rust_bridge::frb(sync)]
pub fn default_ride_export_dir() -> String {
    crate::trainer::ride::default_export_dir().display().to_string()
}

/// Scan for Bluetooth heart-rate straps (Heart Rate Service 0x180D).
/// Independent of the trainer link and of demo mode.
pub async fn scan_heart_rate_straps(timeout_ms: u32) -> Result<Vec<DiscoveredDevice>, String> {
    ensure_runtime();
    crate::trainer::hr_strap::scan(timeout_ms).await
}

/// Connect a heart-rate strap; while it streams, its bpm replaces any HR the
/// trainer relays (live card, ride avg/max, TCX export).
pub async fn connect_heart_rate_strap(device_id: String) -> Result<(), String> {
    ensure_runtime();
    crate::trainer::hr_strap::connect(device_id).await
}

pub async fn disconnect_heart_rate_strap() {
    ensure_runtime();
    crate::trainer::hr_strap::disconnect().await
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_heart_rate_strap_status() -> HrStrapStatus {
    crate::trainer::hr_strap::status()
}


#[flutter_rust_bridge::frb(sync)]
pub fn list_workouts() -> Result<Vec<WorkoutInfo>, String> {
    crate::trainer::workouts::list_workouts()
}

#[flutter_rust_bridge::frb(sync)]
pub fn load_workout_json(id: String) -> Result<String, String> {
    let w = crate::trainer::workouts::load_workout(&id)?;
    crate::trainer::workouts::workout_to_json(&w)
}

#[flutter_rust_bridge::frb(sync)]
pub fn save_workout_json(json: String) -> Result<String, String> {
    let w = crate::trainer::workouts::workout_from_json(&json)?;
    crate::trainer::workouts::save_workout(w)
}

#[flutter_rust_bridge::frb(sync)]
pub fn delete_workout(id: String) -> Result<(), String> {
    crate::trainer::workouts::delete_workout(&id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn workouts_dir() -> String {
    let _ = crate::trainer::workouts::ensure_dirs();
    crate::trainer::workouts::workouts_dir().display().to_string()
}

pub async fn start_workout(id: String) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    let r = g.start_workout(id.clone()).await;
    if r.is_ok() {
        // A new effort: summary / TCX cover only what follows.
        crate::trainer::ride::begin_effort(EffortKind::workout(id), g.is_demo());
    }
    r
}

#[flutter_rust_bridge::frb(sync)]
pub fn stop_workout() {
    block_on(async {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.stop_workout();
    });
    // User Stop: close the effort (route completion closes it as Completed).
    crate::trainer::ride::end_effort(false);
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_workout_status() -> WorkoutStatus {
    crate::trainer::controller::try_workout_status()
}

#[flutter_rust_bridge::frb(sync)]
pub fn parse_gpx_xml(xml: String) -> Result<GpxProfileInfo, String> {
    crate::trainer::gpx::parse_gpx(&xml)
}

#[flutter_rust_bridge::frb(sync)]
pub fn import_gpx_file(path: String) -> Result<GpxProfileInfo, String> {
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| format!("Could not read GPX: {e}"))?;
    let profile = crate::trainer::gpx::parse_gpx(&raw)?;
    let _ = crate::trainer::workouts::ensure_dirs();
    let dest = crate::trainer::workouts::routes_dir().join(
        std::path::Path::new(&path)
            .file_name()
            .unwrap_or_default(),
    );
    let _ = std::fs::copy(&path, &dest);
    Ok(profile)
}

pub async fn start_gpx_route(profile: GpxProfileInfo) -> Result<(), String> {
    let ctrl = controller();
    let mut g = ctrl.lock().await;
    let route_key = profile.route_key.clone();
    let r = g.start_gpx_route(profile).await;
    if r.is_ok() {
        // A new effort: summary / TCX cover only what follows.
        crate::trainer::ride::begin_effort(EffortKind::route(route_key), g.is_demo());
    }
    r
}

#[flutter_rust_bridge::frb(sync)]
pub fn stop_gpx_route() {
    block_on(async {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.stop_gpx_route();
    });
    // User Stop: close the effort (route completion closes it as Completed).
    crate::trainer::ride::end_effort(false);
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_route_status() -> RouteStatus {
    crate::trainer::controller::try_route_status()
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_erg_from_grade(enabled: bool) {
    block_on(async {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.set_erg_from_grade(enabled);
    });
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_workout_rider_mass_kg(kg: f64) {
    block_on(async {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.set_rider_mass_kg(kg);
    });
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

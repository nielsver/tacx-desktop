//! Shared trainer types exposed to Flutter via flutter_rust_bridge.

#[derive(Clone, Debug, Default)]
pub struct TrainerMetrics {
    pub power_w: f64,
    pub cadence_rpm: f64,
    pub speed_kmh: f64,
    pub target_power_w: Option<f64>,
    pub resistance_pct: Option<f64>,
    /// Heart rate relayed by the trainer (FTMS Indoor Bike Data bit 9 or FE-C
    /// page 16 byte 6), bpm. `None` when the trainer has no HR source.
    pub heart_rate_bpm: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct ResistanceRange {
    pub min_pct: f64,
    pub max_pct: f64,
    pub step_pct: f64,
}

impl Default for ResistanceRange {
    fn default() -> Self {
        Self {
            min_pct: 0.0,
            max_pct: 100.0,
            step_pct: 1.0,
        }
    }
}

#[derive(Clone, Debug)]
pub struct PowerRange {
    pub min_w: u32,
    pub max_w: u32,
    pub step_w: u32,
}

impl Default for PowerRange {
    fn default() -> Self {
        Self {
            min_w: 0,
            max_w: 1000,
            step_w: 1,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[derive(Default)]
pub enum ConnectionState {
    #[default]
    Disconnected,
    Scanning,
    Connecting,
    Connected,
    Error,
    /// Link lost unexpectedly; automatic reconnect with backoff in progress.
    Reconnecting,
}


#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[derive(Default)]
pub enum ControlMode {
    #[default]
    Idle,
    Erg,
    Resistance,
    /// Indoor bike simulation (FTMS 0x11 or FE-C Track/Wind).
    Simulation,
}


#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[derive(Default)]
pub enum ProtocolKind {
    #[default]
    Demo,
    Ftms,
    TacxFecBle,
}


/// Separate BLE heart-rate strap link (Heart Rate Service 0x180D).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[derive(Default)]
pub enum HrStrapState {
    #[default]
    Disconnected,
    Connecting,
    Connected,
    Error,
}


#[derive(Clone, Debug, Default)]
pub struct HrStrapStatus {
    pub state: HrStrapState,
    pub device_id: String,
    pub device_name: String,
    /// Short English status / error line for the UI.
    pub detail: String,
    /// Latest strap reading, `None` when disconnected or stale (> 5 s).
    pub heart_rate_bpm: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct DiscoveredDevice {
    pub id: String,
    pub name: String,
    pub rssi: Option<i32>,
    /// Hint from advertisement / name: "ftms", "kickr_ftms", "tacx_fec", "demo", …
    pub protocol_hint: String,
}

#[derive(Clone, Debug)]
pub struct ConnectionSnapshot {
    pub state: ConnectionState,
    pub detail: String,
    pub protocol: ProtocolKind,
    pub is_demo: bool,
    pub mode: ControlMode,
    pub device_name: String,
    /// True when FTMS Feature bit / FE-C / demo can accept simulation (grade/wind).
    pub supports_simulation: bool,
    /// Auto-reconnect attempt (1-based) while reconnecting / after giving up; 0 otherwise.
    pub reconnect_attempt: u32,
    /// Attempts in the backoff schedule (0 when no auto-reconnect is active).
    pub reconnect_max_attempts: u32,
    /// Seconds until the next automatic attempt (0 while an attempt is running).
    pub reconnect_in_s: u32,
    /// Auto-reconnect exhausted its schedule — only manual Reconnect remains.
    pub reconnect_gave_up: bool,
}

impl Default for ConnectionSnapshot {
    fn default() -> Self {
        Self {
            state: ConnectionState::Disconnected,
            detail: String::new(),
            protocol: ProtocolKind::Demo,
            is_demo: true,
            mode: ControlMode::Idle,
            device_name: String::new(),
            supports_simulation: true,
            reconnect_attempt: 0,
            reconnect_max_attempts: 0,
            reconnect_in_s: 0,
            reconnect_gave_up: false,
        }
    }
}

#[derive(Clone, Debug)]
pub struct IntervalPresetInfo {
    pub key: String,
    pub label: String,
    pub description: String,
    pub repeats: u32,
    pub work_s: u32,
    pub rest_s: u32,
    pub work_watts: u32,
    pub rest_watts: u32,
}

#[derive(Clone, Debug, Default)]
pub struct IntervalStatus {
    pub running: bool,
    pub phase: String,
    pub status_text: String,
    pub repeat_index: u32,
    pub remaining_s: f64,
}

/// Host Bluetooth radio state, checked before scanning so the UI can show an
/// empty state instead of a cryptic scan error.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BluetoothRadio {
    /// Demo mode: no radio needed.
    NotNeeded,
    /// Adapter present and powered on.
    On,
    /// Adapter present but powered off (Windows Settings / macOS menu bar / bluetoothctl).
    Off,
    /// No adapter found (no dongle, driver missing, BlueZ not running).
    NoAdapter,
    /// Adapter present but the OS did not report a state (common on BlueZ / older WinRT).
    Unknown,
}

#[derive(Clone, Debug)]
pub struct BluetoothStatus {
    pub radio: BluetoothRadio,
    /// Human-readable hint for the empty-state banner (English, short).
    pub hint: String,
    /// Whether the Scan button should be enabled (false when off / no adapter).
    pub can_scan: bool,
}

impl BluetoothStatus {
    pub fn from_radio(radio: BluetoothRadio, detail: Option<String>) -> Self {
        let hint = match radio {
            BluetoothRadio::NotNeeded => "Demo mode — no Bluetooth needed.".to_string(),
            BluetoothRadio::On => "Bluetooth is on.".to_string(),
            BluetoothRadio::Off => {
                #[cfg(target_os = "linux")]
                {
                    "Bluetooth is off. Garuda/Arch: `rfkill unblock bluetooth`; `bluetoothctl power on`; Plasma tray On; then Check again. Never sudo the app.".to_string()
                }
                #[cfg(not(target_os = "linux"))]
                {
                    "Bluetooth is off. Turn it on (Windows: Settings → Bluetooth & devices; macOS: menu bar Bluetooth; Linux: `bluetoothctl power on` / rfkill), then check again.".to_string()
                }
            }
            BluetoothRadio::NoAdapter => {
                #[cfg(target_os = "linux")]
                let base = "No Bluetooth adapter / BlueZ not ready. `sudo pacman -S bluez bluez-utils`; `sudo systemctl enable --now bluetooth`; plug in a BLE dongle if needed; then Check again.";
                #[cfg(not(target_os = "linux"))]
                let base = "No Bluetooth adapter found. Plug in a BLE 4.0+ dongle or enable the adapter/driver (Linux: start bluetooth), then check again.";
                match detail {
                    Some(d) if !d.is_empty() => format!("{base} ({d})"),
                    _ => base.to_string(),
                }
            }
            BluetoothRadio::Unknown => {
                #[cfg(target_os = "linux")]
                {
                    "Bluetooth state unknown (common on BlueZ). Ensure `bluetooth` group + powered adapter; scanning may still work.".to_string()
                }
                #[cfg(not(target_os = "linux"))]
                {
                    "Bluetooth state unknown — scanning anyway may still work.".to_string()
                }
            }
        };
        let can_scan = !matches!(radio, BluetoothRadio::Off | BluetoothRadio::NoAdapter);
        Self { radio, hint, can_scan }
    }
}

#[cfg(test)]
mod bluetooth_status_tests {
    use super::*;

    #[test]
    fn off_and_missing_block_scan() {
        assert!(!BluetoothStatus::from_radio(BluetoothRadio::Off, None).can_scan);
        assert!(!BluetoothStatus::from_radio(BluetoothRadio::NoAdapter, None).can_scan);
    }

    #[test]
    fn on_unknown_demo_allow_scan() {
        for r in [BluetoothRadio::On, BluetoothRadio::Unknown, BluetoothRadio::NotNeeded] {
            assert!(BluetoothStatus::from_radio(r, None).can_scan, "{r:?}");
        }
    }

    #[test]
    fn no_adapter_hint_includes_detail() {
        let s = BluetoothStatus::from_radio(BluetoothRadio::NoAdapter, Some("No Bluetooth adapter found".into()));
        assert!(s.hint.contains("dongle"));
        assert!(s.hint.contains("No Bluetooth adapter found"));
    }
}

/// Trainer data-link health level for the status bar.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LinkLevel {
    /// No packet since connect.
    #[default]
    NoData,
    /// Last packet under 1.5 s old.
    Good,
    /// 1.5–4 s since the last packet.
    Stale,
    /// 4 s or more: the trainer (or BLE) has stopped sending.
    Lost,
}

/// Trainer packets per second and last-packet age (see `trainer::link_health`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LinkHealth {
    pub packets_per_s: f64,
    pub last_packet_age_ms: Option<u32>,
    pub level: LinkLevel,
}

/// Best average power over one duration (mean-max point).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PowerBest {
    pub duration_s: u32,
    /// `None` when no unbroken stretch of the ride is that long.
    pub watts: Option<f64>,
}

/// Post-ride analysis of the 1 Hz track (see `trainer::summary`).
///
/// FTP-dependent fields (`intensity_factor`, `tss`, `time_in_zone_s`) are
/// empty when `ftp_w` is 0; `np_w` is `None` under 30 s of riding.
#[derive(Clone, Debug, Default)]
pub struct RideSummary {
    /// Seconds of recorded 1 Hz samples (pauses / reconnect gaps excluded).
    pub recorded_s: u32,
    pub ftp_w: u32,
    pub avg_power_w: f64,
    pub max_power_w: f64,
    /// Normalized Power: 4th root of the mean of (30 s rolling average)^4.
    pub np_w: Option<f64>,
    /// NP / FTP.
    pub intensity_factor: Option<f64>,
    /// Training Stress Score: hours × IF² × 100.
    pub tss: Option<f64>,
    pub avg_cadence_rpm: f64,
    pub max_cadence_rpm: f64,
    pub avg_heart_rate_bpm: f64,
    pub max_heart_rate_bpm: u32,
    /// Seconds in Coggan zones Z1..Z7 (7 entries), empty without FTP.
    pub time_in_zone_s: Vec<u32>,
    /// Mean-max power at 5 s, 1 min, 5 min and 20 min.
    pub best_power: Vec<PowerBest>,
    /// Best 20 min average power (input for a step-4 FTP estimate).
    pub best_20min_w: Option<f64>,
    /// Power downsampled to at most [`SUMMARY_SERIES_MAX`] bucket means, W.
    pub power_series: Vec<f64>,
    /// Heart rate on the same buckets, bpm (0 = no reading in the bucket).
    pub heart_rate_series: Vec<f64>,
    /// The ride segment came from the Demo trainer (synthetic data).
    pub is_demo: bool,
}

/// Upper bound on `RideSummary` chart series length.
pub const SUMMARY_SERIES_MAX: usize = 600;

/// Running totals for the current ride (since connect or the last Reset).
/// Time only accumulates while a trainer is connected; reconnect gaps pause it.
#[derive(Clone, Debug, Default)]
pub struct RideStats {
    /// Connected time, seconds.
    pub elapsed_s: u32,
    /// Seconds with power or cadence above zero.
    pub moving_s: u32,
    /// Time-weighted average power over moving time, W.
    pub avg_power_w: f64,
    pub max_power_w: f64,
    /// Time-weighted average cadence while pedalling, rpm.
    pub avg_cadence_rpm: f64,
    /// Mechanical work, kJ (≈ kcal burned for a typical rider).
    pub energy_kj: f64,
    /// Integrated from trainer speed, km.
    pub distance_km: f64,
    /// Time-weighted average heart rate over seconds with a reading, bpm (0 = none).
    pub avg_heart_rate_bpm: f64,
    /// Highest heart rate seen, bpm (0 = none).
    pub max_heart_rate_bpm: u32,
    /// True while samples are being added (trainer connected).
    pub recording: bool,
}


#[derive(Clone, Debug)]
pub struct WorkoutInfo {
    pub id: String,
    pub name: String,
    pub description: String,
    pub builtin: bool,
    pub step_count: u32,
    pub total_duration_s: u32,
}

#[derive(Clone, Debug, Default)]
pub struct WorkoutStatus {
    pub running: bool,
    pub workout_id: String,
    pub workout_name: String,
    pub step_index: u32,
    pub step_count: u32,
    pub remaining_s: f64,
    pub target_watts: Option<u32>,
    pub target_grade_pct: Option<f64>,
    pub status_text: String,
    pub done: bool,
    /// Why the last run stopped early (command rejected, link lost…).
    pub error: Option<String>,
}

#[derive(Clone, Debug)]
pub struct ElevSample {
    pub distance_m: f64,
    pub elev_m: f64,
    pub grade_pct: f64,
    /// WGS84 position of this sample (for the route map / route identity).
    pub lat: f64,
    pub lon: f64,
}

#[derive(Clone, Debug)]
pub struct GpxProfileInfo {
    pub name: String,
    pub distance_m: f64,
    pub elev_gain_m: f64,
    pub samples: Vec<ElevSample>,
    /// Stable route identity, `v2-<16 hex>` (see `gpx::route_key_v2`).
    pub route_key: String,
    /// Auto-detected climbs (`climbs::detect_climbs`), by start.
    pub climbs: Vec<Climb>,
}

/// Strava-style climb category from score = length (m) × grade (%).
/// `Climb` = 1 500–8 000 (uncategorised, still gets PRs).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClimbCat {
    Climb,
    Cat4,
    Cat3,
    Cat2,
    Cat1,
    Hc,
    /// Short steep wall (≥ 250 m, ≥ 8 %, ≥ 25 m gain), under 500 m.
    Wall,
}

/// One detected climb on a route (detector v1).
#[derive(Clone, Debug, PartialEq)]
pub struct Climb {
    /// `{routeKey}:{start10}-{end10}`; loop repeats get separate ids.
    pub id: String,
    pub start_m: f64,
    pub end_m: f64,
    pub gain_m: f64,
    pub avg_grade: f64,
    pub max_grade_100m: f64,
    pub score: f64,
    pub category: ClimbCat,
}

#[derive(Clone, Debug, Default)]
pub struct RouteStatus {
    pub running: bool,
    pub route_name: String,
    pub distance_m: f64,
    pub progress_m: f64,
    pub grade_pct: f64,
    pub complete: bool,
    pub status_text: String,
}

/// Kind of ride effort (QA c4 P1-1, ride-boundary checklist option a).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EffortType {
    /// Auto-begun on the first pedal stroke with nothing started.
    FreeRide,
    Route,
    Workout,
}

/// What a ride effort is: `key` is the route key (Route), the workout id
/// (Workout) or empty (FreeRide). A flat struct so the Dart side needs no
/// code generator for sealed classes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EffortKind {
    pub kind: EffortType,
    pub key: String,
}

impl EffortKind {
    pub fn free_ride() -> Self {
        Self { kind: EffortType::FreeRide, key: String::new() }
    }
    pub fn route(route_key: impl Into<String>) -> Self {
        Self { kind: EffortType::Route, key: route_key.into() }
    }
    pub fn workout(id: impl Into<String>) -> Self {
        Self { kind: EffortType::Workout, key: id.into() }
    }
}

/// Why an effort closed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndReason {
    Stopped,
    Completed,
    /// Trainer idle (disconnected) for more than 60 s.
    DisconnectTimeout,
    /// Another effort began while this one was open.
    Superseded,
    /// Route / workout without a trainer for 30 min (LinkLost safety net).
    Abandoned,
}

/// One effort inside the session: `points[first..end]` of the recorder.
#[derive(Clone, Debug)]
pub struct RideSlice {
    pub id: u32,
    pub kind: EffortKind,
    /// Captured at begin; never changes.
    pub demo: bool,
    pub start_ms: i64,
    /// Last update (live) or close time, ms since epoch.
    pub end_ms: i64,
    pub first: u32,
    pub end: u32,
    pub moving_s: u32,
    pub paused_s: u32,
    pub completed: bool,
    /// `None` while the effort is open.
    pub end_reason: Option<EndReason>,
}

/// Recorder event kinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RideEventKind {
    RideEnded,
    /// Progress applied for a closed effort: `earned` is set.
    Earned,
    /// A route / workout lost the trainer for > 60 s: paused, NOT ended
    /// (QA c8 P1-C). The ride only ends via `end_effort` (`RideEnded`).
    LinkLost,
    /// The trainer is back after `LinkLost`; the same effort continues.
    LinkRestored,
}

/// "What you earned" for one effort (post-ride summary row; also carried
/// on the `Earned` ride event for step 5's remote).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct EarnedPayload {
    pub xp_gained: u32,
    pub xp_total: u64,
    pub level: u32,
    pub streak_weeks: u32,
    pub week_days: u32,
    pub weekly_target: u32,
    pub new_badges: Vec<String>,
    /// e.g. "Climb 1.0–3.0 km (+100 m) 6:41 (−0:12)".
    pub pr_lines: Vec<String>,
    pub ctl: f64,
    pub atl: f64,
    /// CTL − ATL.
    pub form: f64,
}

/// Recorder events (`ride_events` stream). Step 5's remote End & Save
/// listens to the same stream.
#[derive(Clone, Debug, PartialEq)]
pub struct RideEvent {
    pub kind: RideEventKind,
    pub slice_id: u32,
    /// Stable across restarts: "{start_ms}-{freeRide|route|workout}-{key}"
    /// (same as the progress uid). Empty when the effort is unknown.
    pub uid: String,
    pub effort_kind: Option<EffortKind>,
    pub demo: bool,
    pub end_reason: Option<EndReason>,
    pub start_ms: i64,
    pub end_ms: i64,
    pub earned: Option<EarnedPayload>,
}

impl RideEvent {
    fn base(kind: RideEventKind, slice_id: u32, s: Option<&RideSlice>) -> Self {
        Self {
            kind,
            slice_id,
            uid: s.map(|s| s.uid()).unwrap_or_default(),
            effort_kind: s.map(|s| s.kind.clone()),
            demo: s.is_some_and(|s| s.demo),
            end_reason: s.and_then(|s| s.end_reason),
            start_ms: s.map_or(0, |s| s.start_ms),
            end_ms: s.map_or(0, |s| s.end_ms),
            earned: None,
        }
    }
    pub fn ride_ended(s: &RideSlice) -> Self {
        Self::base(RideEventKind::RideEnded, s.id, Some(s))
    }
    pub fn link(kind: RideEventKind, s: &RideSlice) -> Self {
        Self::base(kind, s.id, Some(s))
    }
    pub fn earned(slice_id: u32, s: Option<&RideSlice>, e: EarnedPayload) -> Self {
        Self { earned: Some(e), ..Self::base(RideEventKind::Earned, slice_id, s) }
    }
}

impl RideSlice {
    /// "{start_ms}-{kind}-{key}", kind in Dart enum names (progress uid).
    pub fn uid(&self) -> String {
        let k = match self.kind.kind {
            EffortType::FreeRide => "freeRide",
            EffortType::Route => "route",
            EffortType::Workout => "workout",
        };
        format!("{}-{}-{}", self.start_ms, k, self.kind.key)
    }
}

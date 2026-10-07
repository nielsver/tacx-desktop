//! Shared trainer types exposed to Flutter via flutter_rust_bridge.

#[derive(Clone, Debug, Default)]
pub struct TrainerMetrics {
    pub power_w: f64,
    pub cadence_rpm: f64,
    pub speed_kmh: f64,
    pub target_power_w: Option<f64>,
    pub resistance_pct: Option<f64>,
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
pub enum ConnectionState {
    Disconnected,
    Scanning,
    Connecting,
    Connected,
    Error,
}

impl Default for ConnectionState {
    fn default() -> Self {
        Self::Disconnected
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlMode {
    Idle,
    Erg,
    Resistance,
}

impl Default for ControlMode {
    fn default() -> Self {
        Self::Idle
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProtocolKind {
    Demo,
    Ftms,
    TacxFecBle,
}

impl Default for ProtocolKind {
    fn default() -> Self {
        Self::Demo
    }
}

#[derive(Clone, Debug)]
pub struct DiscoveredDevice {
    pub id: String,
    pub name: String,
    pub rssi: Option<i32>,
    /// Hint from advertisement / name: "ftms", "tacx_fec", or "unknown".
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

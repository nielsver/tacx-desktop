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
    /// Link lost unexpectedly; automatic reconnect with backoff in progress.
    Reconnecting,
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
    /// Indoor bike simulation (FTMS 0x11 or FE-C Track/Wind).
    Simulation,
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

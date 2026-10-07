//! FTMS Indoor Bike parsing and control helpers (public GATT 0x1826).

use crate::trainer::types::{PowerRange, ResistanceRange, TrainerMetrics};

pub const FTMS_SERVICE: u16 = 0x1826;
pub const INDOOR_BIKE_DATA: u16 = 0x2AD2;
pub const CONTROL_POINT: u16 = 0x2AD9;
pub const SUPPORTED_RESISTANCE_RANGE: u16 = 0x2AD6;
pub const SUPPORTED_POWER_RANGE: u16 = 0x2AD8;
pub const MACHINE_STATUS: u16 = 0x2ADA;
pub const FEATURE: u16 = 0x2ACC;

pub const OP_SET_INDOOR_BIKE_SIMULATION: u8 = 0x11;

/// Fitness Machine Features bit 13 — Indoor Bike Simulation Parameters Supported (FTMS 1.0.1).
pub const FEATURE_BIT_INDOOR_BIKE_SIMULATION: u32 = 1 << 13;

/// Target Setting Features bit 3 — Target Resistance Level Supported (FTMS 1.0.1).
pub const TARGET_FEATURE_BIT_RESISTANCE_LEVEL: u32 = 1 << 3;

/// Fitness Machine Status is optional — connect/control must work when absent.
pub fn machine_status_is_optional() -> bool {
    true
}


pub const OP_REQUEST_CONTROL: u8 = 0x00;
pub const OP_SET_TARGET_RESISTANCE: u8 = 0x04;
pub const OP_SET_TARGET_POWER: u8 = 0x05;
pub const OP_START_RESUME: u8 = 0x07;
pub const OP_RESPONSE: u8 = 0x80;
pub const RESULT_SUCCESS: u8 = 0x01;

pub fn parse_indoor_bike_data(data: &[u8]) -> TrainerMetrics {
    let mut m = TrainerMetrics::default();
    if data.len() < 2 {
        return m;
    }
    let flags = u16::from_le_bytes([data[0], data[1]]);
    let mut offset = 2usize;

    let more_data = flags & 0x0001 != 0;
    let average_speed = flags & 0x0002 != 0;
    let instantaneous_cadence = flags & 0x0004 != 0;
    let average_cadence = flags & 0x0008 != 0;
    let total_distance = flags & 0x0010 != 0;
    let resistance_level = flags & 0x0020 != 0;
    let instantaneous_power = flags & 0x0040 != 0;

    if !more_data {
        if offset + 2 > data.len() {
            return m;
        }
        m.speed_kmh = u16::from_le_bytes([data[offset], data[offset + 1]]) as f64 / 100.0;
        offset += 2;
    }
    if average_speed {
        offset += 2;
    }
    if instantaneous_cadence {
        if offset + 2 > data.len() {
            return m;
        }
        m.cadence_rpm = u16::from_le_bytes([data[offset], data[offset + 1]]) as f64 / 2.0;
        offset += 2;
    }
    if average_cadence {
        offset += 2;
    }
    if total_distance {
        offset += 3;
    }
    if resistance_level {
        offset += 2;
    }
    if instantaneous_power {
        if offset + 2 > data.len() {
            return m;
        }
        let raw = i16::from_le_bytes([data[offset], data[offset + 1]]);
        m.power_w = raw as f64;
        offset += 2;
    }
    if flags & 0x0080 != 0 {
        // Average Power (sint16)
        offset += 2;
    }
    if flags & 0x0100 != 0 {
        // Expended Energy: total uint16 + per hour uint16 + per minute uint8
        offset += 5;
    }
    if flags & 0x0200 != 0 {
        m.heart_rate_bpm = data.get(offset).copied().and_then(valid_heart_rate);
    }
    m
}

/// 0 means "no reading" on both FTMS and FE-C; 0xFF is FE-C "invalid".
pub fn valid_heart_rate(raw: u8) -> Option<u32> {
    match raw {
        0 | 0xFF => None,
        bpm => Some(bpm as u32),
    }
}

pub fn parse_resistance_range(data: &[u8]) -> (ResistanceRange, i16) {
    if data.len() < 6 {
        return (ResistanceRange::default(), 1000);
    }
    let min_raw = i16::from_le_bytes([data[0], data[1]]);
    let max_raw = i16::from_le_bytes([data[2], data[3]]);
    let step_raw = i16::from_le_bytes([data[4], data[5]]);
    if max_raw > 0 {
        let rr = ResistanceRange {
            min_pct: ((min_raw as f64 / max_raw as f64) * 100.0).max(0.0),
            max_pct: 100.0,
            step_pct: if step_raw != 0 {
                ((step_raw as f64 / max_raw as f64) * 100.0).max(0.1)
            } else {
                1.0
            },
        };
        (rr, max_raw)
    } else {
        (
            ResistanceRange {
                min_pct: min_raw as f64 * 0.1,
                max_pct: if max_raw != 0 {
                    max_raw as f64 * 0.1
                } else {
                    100.0
                },
                step_pct: if step_raw != 0 {
                    step_raw as f64 * 0.1
                } else {
                    1.0
                },
            },
            1000,
        )
    }
}

pub fn parse_power_range(data: &[u8]) -> PowerRange {
    if data.len() < 6 {
        return PowerRange::default();
    }
    let min_w = i16::from_le_bytes([data[0], data[1]]) as i32;
    let max_w = i16::from_le_bytes([data[2], data[3]]) as i32;
    let step_w = i16::from_le_bytes([data[4], data[5]]) as i32;
    PowerRange {
        min_w: min_w.max(0) as u32,
        max_w: if max_w > 0 { max_w as u32 } else { 1000 },
        step_w: if step_w > 0 { step_w as u32 } else { 1 },
    }
}



/// Fitness Machine Status (0x2ADA) op codes we care about for UX.
pub const STATUS_RESET: u8 = 0x01;
pub const STATUS_STOPPED_OR_PAUSED_BY_USER: u8 = 0x02;
pub const STATUS_STOPPED_BY_SAFETY_KEY: u8 = 0x03;
pub const STATUS_STARTED_OR_RESUMED_BY_USER: u8 = 0x04;
pub const STATUS_TARGET_POWER_CHANGED: u8 = 0x08;
pub const STATUS_TARGET_RESISTANCE_CHANGED: u8 = 0x07;
pub const STATUS_CONTROL_PERMISSION_LOST: u8 = 0xFF;

/// Stop/Pause parameter for STATUS_STOPPED_OR_PAUSED_BY_USER.
pub const STOP_PARAM_STOP: u8 = 0x01;
pub const STOP_PARAM_PAUSE: u8 = 0x02;

/// Parsed Fitness Machine Status notification.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MachineStatusEvent {
    Reset,
    StoppedByUser,
    PausedByUser,
    StoppedBySafetyKey,
    StartedOrResumedByUser,
    TargetPowerChanged,
    TargetResistanceChanged,
    ControlPermissionLost,
    Other(u8),
}

impl MachineStatusEvent {
    pub fn as_ux_message(&self) -> &'static str {
        match self {
            Self::Reset => "Trainer reset",
            Self::StoppedByUser => "Trainer stopped",
            Self::PausedByUser => "Trainer paused",
            Self::StoppedBySafetyKey => "Trainer stopped (safety key)",
            Self::StartedOrResumedByUser => "Trainer started/resumed",
            Self::TargetPowerChanged => "Target power changed (external)",
            Self::TargetResistanceChanged => "Target resistance changed (external)",
            Self::ControlPermissionLost => {
                "Control lost — another app took the trainer (NOCTRL). Close other apps and Reconnect."
            }
            Self::Other(_) => "Fitness Machine Status update",
        }
    }

    /// Whether UX should treat this as a hard control/link problem.
    pub fn is_control_lost(&self) -> bool {
        matches!(self, Self::ControlPermissionLost)
    }

    /// Whether the machine reported stop/pause (rider or safety).
    pub fn is_stop_or_pause(&self) -> bool {
        matches!(
            self,
            Self::StoppedByUser
                | Self::PausedByUser
                | Self::StoppedBySafetyKey
                | Self::Reset
        )
    }
}

/// Parse Fitness Machine Status characteristic notification.
pub fn parse_machine_status(data: &[u8]) -> Option<MachineStatusEvent> {
    if data.is_empty() {
        return None;
    }
    let op = data[0];
    Some(match op {
        STATUS_RESET => MachineStatusEvent::Reset,
        STATUS_STOPPED_OR_PAUSED_BY_USER => {
            let param = data.get(1).copied().unwrap_or(STOP_PARAM_STOP);
            if param == STOP_PARAM_PAUSE {
                MachineStatusEvent::PausedByUser
            } else {
                MachineStatusEvent::StoppedByUser
            }
        }
        STATUS_STOPPED_BY_SAFETY_KEY => MachineStatusEvent::StoppedBySafetyKey,
        STATUS_STARTED_OR_RESUMED_BY_USER => MachineStatusEvent::StartedOrResumedByUser,
        STATUS_TARGET_POWER_CHANGED => MachineStatusEvent::TargetPowerChanged,
        STATUS_TARGET_RESISTANCE_CHANGED => MachineStatusEvent::TargetResistanceChanged,
        STATUS_CONTROL_PERMISSION_LOST => MachineStatusEvent::ControlPermissionLost,
        other => MachineStatusEvent::Other(other),
    })
}

pub fn describe_cp_result(result: u8) -> &'static str {
    match result {
        0x01 => "success",
        0x02 => "op-code not supported",
        0x03 => "invalid parameter",
        0x04 => "operation failed",
        0x05 => "control not permitted (NOCTRL) — another app holds the trainer",
        _ => "unknown control-point result",
    }
}

/// Parse FTMS Control Point indication/notification.
/// Layout: `[0x80, request_op, result, ...optional params]`.
pub fn parse_cp_indication(data: &[u8]) -> Option<(u8, u8)> {
    if data.len() < 3 || data[0] != OP_RESPONSE {
        return None;
    }
    Some((data[1], data[2]))
}

/// Human-readable CP response for logs / UI errors.
pub fn format_cp_response(request_op: u8, result: u8) -> String {
    let op_name = match request_op {
        OP_REQUEST_CONTROL => "Request Control",
        OP_SET_TARGET_RESISTANCE => "Set Target Resistance",
        OP_SET_TARGET_POWER => "Set Target Power",
        OP_START_RESUME => "Start/Resume",
        OP_SET_INDOOR_BIKE_SIMULATION => "Indoor Bike Simulation",
        _ => "Control Point op",
    };
    format!("{op_name} → {}", describe_cp_result(result))
}

/// Clamp target watts to Supported Power Range (min/max/step).
pub fn clamp_target_power(watts: u32, range: &PowerRange) -> u32 {
    let w = watts.clamp(range.min_w, range.max_w);
    if range.step_w <= 1 {
        return w;
    }
    let base = range.min_w;
    let steps = (w.saturating_sub(base) + range.step_w / 2) / range.step_w;
    (base + steps * range.step_w).clamp(range.min_w, range.max_w)
}

/// Clamp resistance percent to Supported Resistance Range.
pub fn clamp_resistance_percent(percent: f64, range: &ResistanceRange) -> f64 {
    let p = percent.clamp(range.min_pct, range.max_pct);
    if range.step_pct <= 0.0 {
        return p;
    }
    let base = range.min_pct;
    let steps = ((p - base) / range.step_pct).round();
    (base + steps * range.step_pct).clamp(range.min_pct, range.max_pct)
}

/// True when CP result means the write was accepted.
pub fn cp_success(result: u8) -> bool {
    result == RESULT_SUCCESS
}


pub fn encode_request_control() -> Vec<u8> {
    vec![OP_REQUEST_CONTROL]
}

pub fn encode_start_resume() -> Vec<u8> {
    vec![OP_START_RESUME]
}

pub fn encode_set_target_power(watts: i16) -> Vec<u8> {
    let mut v = vec![OP_SET_TARGET_POWER];
    v.extend_from_slice(&watts.to_le_bytes());
    v
}

/// FTMS Set Target Resistance Level: uint8, unit 0.1 of resistance.
pub fn encode_set_resistance(percent: f64, max_raw: i16) -> Vec<u8> {
    let raw = ((percent / 100.0) * (max_raw as f64) / 10.0).round() as i32;
    let raw = raw.clamp(0, 255) as u8;
    vec![OP_SET_TARGET_RESISTANCE, raw]
}

/// FTMS Set Indoor Bike Simulation Parameters (`0x11`).
/// - `wind_speed_mps`: m/s (encoded as 0.001 m/s)
/// - `grade_pct`: % grade (encoded as 0.01 %)
/// - `crr`: rolling resistance coefficient (encoded as 0.0001)
/// - `cw`: wind resistance coefficient kg/m (encoded as 0.01 kg/m)
pub fn encode_indoor_bike_simulation(
    wind_speed_mps: f64,
    grade_pct: f64,
    crr: f64,
    cw: f64,
) -> Vec<u8> {
    let wind = (wind_speed_mps * 1000.0).round().clamp(i16::MIN as f64, i16::MAX as f64) as i16;
    let grade = (grade_pct * 100.0).round().clamp(i16::MIN as f64, i16::MAX as f64) as i16;
    let crr_u = (clamp_simulation_crr(crr) / 0.0001).round().clamp(0.0, 255.0) as u8;
    let cw_u = (clamp_simulation_cw(cw) / 0.01).round().clamp(0.0, 255.0) as u8;
    let mut v = vec![OP_SET_INDOOR_BIKE_SIMULATION];
    v.extend_from_slice(&wind.to_le_bytes());
    v.extend_from_slice(&grade.to_le_bytes());
    v.push(crr_u);
    v.push(cw_u);
    v
}

/// Defaults commonly used by open FTMS / FE-C clients.
pub const DEFAULT_SIM_CRR: f64 = 0.004;
pub const DEFAULT_SIM_CW: f64 = 0.51;

/// FE-C Track Crr max is 0.0127; FTMS uint8×0.0001 allows up to 0.0255 — clamp to FE-C-safe.
pub fn clamp_simulation_crr(crr: f64) -> f64 {
    crr.clamp(0.0, 0.0127)
}

/// FE-C wind resistance coeff max 1.86; FTMS uint8×0.01 allows 2.55 — clamp to FE-C-safe.
pub fn clamp_simulation_cw(cw: f64) -> f64 {
    cw.clamp(0.0, 1.86)
}

/// Grade-only simulation helper (zero wind, default Crr/Cw).
pub fn encode_simulation_grade(grade_pct: f64) -> Vec<u8> {
    encode_indoor_bike_simulation(0.0, grade_pct, DEFAULT_SIM_CRR, DEFAULT_SIM_CW)
}

/// Parse Fitness Machine Feature (0x2ACC) for Indoor Bike Simulation support.
pub fn features_support_simulation(data: &[u8]) -> bool {
    if data.len() < 4 {
        return false;
    }
    let features = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    features & FEATURE_BIT_INDOOR_BIKE_SIMULATION != 0
}

/// Target Setting Features (bytes 4–7 of 0x2ACC) — Target Resistance Level.
pub fn features_support_target_resistance(data: &[u8]) -> bool {
    if data.len() < 8 {
        return false;
    }
    let target = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    target & TARGET_FEATURE_BIT_RESISTANCE_LEVEL != 0
}

/// Unsupported Resistance UI sentinel (`max_pct <= 0`).
pub fn unsupported_resistance_range() -> ResistanceRange {
    ResistanceRange {
        min_pct: 0.0,
        max_pct: 0.0,
        step_pct: 0.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_speed_cadence_power() {
        let flags: u16 = 0x0004 | 0x0040;
        let mut payload = Vec::new();
        payload.extend_from_slice(&flags.to_le_bytes());
        payload.extend_from_slice(&3000u16.to_le_bytes());
        payload.extend_from_slice(&180u16.to_le_bytes());
        payload.extend_from_slice(&200i16.to_le_bytes());
        let m = parse_indoor_bike_data(&payload);
        assert!((m.speed_kmh - 30.0).abs() < 0.01);
        assert!((m.cadence_rpm - 90.0).abs() < 0.01);
        assert!((m.power_w - 200.0).abs() < 0.01);
    }

    #[test]
    fn parse_heart_rate_after_power_avg_and_energy() {
        // speed, cadence, power, avg power, expended energy, heart rate
        let flags: u16 = 0x0004 | 0x0040 | 0x0080 | 0x0100 | 0x0200;
        let mut payload = Vec::new();
        payload.extend_from_slice(&flags.to_le_bytes());
        payload.extend_from_slice(&3000u16.to_le_bytes());
        payload.extend_from_slice(&180u16.to_le_bytes());
        payload.extend_from_slice(&210i16.to_le_bytes());
        payload.extend_from_slice(&190i16.to_le_bytes()); // avg power
        payload.extend_from_slice(&[0x2C, 0x01, 0xFF, 0xFF, 0xFF]); // energy
        payload.push(148);
        let m = parse_indoor_bike_data(&payload);
        assert!((m.power_w - 210.0).abs() < 0.01);
        assert_eq!(m.heart_rate_bpm, Some(148));

        // HR flag without energy fields; 0 = no reading; truncated = None.
        let flags: u16 = 0x0040 | 0x0200;
        let mut p2 = Vec::new();
        p2.extend_from_slice(&flags.to_le_bytes());
        p2.extend_from_slice(&1000u16.to_le_bytes());
        p2.extend_from_slice(&150i16.to_le_bytes());
        let truncated = p2.clone();
        p2.push(0);
        assert_eq!(parse_indoor_bike_data(&p2).heart_rate_bpm, None);
        assert_eq!(parse_indoor_bike_data(&truncated).heart_rate_bpm, None);
        p2.pop();
        p2.push(97);
        assert_eq!(parse_indoor_bike_data(&p2).heart_rate_bpm, Some(97));
    }

    #[test]
    fn feature_bits_sim_and_resistance() {
        let mut raw = vec![0u8; 8];
        // machine features bit 13
        let feat = FEATURE_BIT_INDOOR_BIKE_SIMULATION.to_le_bytes();
        raw[0..4].copy_from_slice(&feat);
        assert!(features_support_simulation(&raw));
        assert!(!features_support_target_resistance(&raw));
        let tgt = TARGET_FEATURE_BIT_RESISTANCE_LEVEL.to_le_bytes();
        raw[4..8].copy_from_slice(&tgt);
        assert!(features_support_target_resistance(&raw));
    }

    #[test]
    fn resistance_range_percent() {
        let mut raw = Vec::new();
        raw.extend_from_slice(&0i16.to_le_bytes());
        raw.extend_from_slice(&1000i16.to_le_bytes());
        raw.extend_from_slice(&10i16.to_le_bytes());
        let (rr, max_raw) = parse_resistance_range(&raw);
        assert_eq!(max_raw, 1000);
        assert!((rr.min_pct - 0.0).abs() < 0.01);
        assert!((rr.max_pct - 100.0).abs() < 0.01);
        assert!((rr.step_pct - 1.0).abs() < 0.01);
    }

    #[test]
    fn describe_noctrl() {
        assert!(describe_cp_result(0x05).contains("NOCTRL"));
    }

    #[test]
    fn encode_power_and_resistance() {
        let p = encode_set_target_power(200);
        assert_eq!(p[0], OP_SET_TARGET_POWER);
        assert_eq!(i16::from_le_bytes([p[1], p[2]]), 200);
        let r = encode_set_resistance(50.0, 1000);
        assert_eq!(r[0], OP_SET_TARGET_RESISTANCE);
        assert_eq!(r[1], 50); // 50% of 1000 / 10 = 50
    }

    #[test]
    fn power_only_more_data() {
        let flags: u16 = 0x0001 | 0x0040;
        let mut payload = Vec::new();
        payload.extend_from_slice(&flags.to_le_bytes());
        payload.extend_from_slice(&185i16.to_le_bytes());
        let m = parse_indoor_bike_data(&payload);
        assert!((m.power_w - 185.0).abs() < 0.01);
        assert_eq!(m.speed_kmh, 0.0);
    }

    #[test]
    fn parse_cp_success_and_noctrl() {
        assert_eq!(parse_cp_indication(&[0x80, 0x00, 0x01]), Some((0x00, 0x01)));
        assert_eq!(parse_cp_indication(&[0x80, 0x05, 0x05]), Some((0x05, 0x05)));
        assert!(parse_cp_indication(&[0x00, 0x01]).is_none());
        assert!(parse_cp_indication(&[]).is_none());
        let msg = format_cp_response(0x05, 0x05);
        assert!(msg.contains("Set Target Power"));
        assert!(msg.contains("NOCTRL"));
        assert!(cp_success(0x01));
        assert!(!cp_success(0x05));
    }

    #[test]
    fn clamp_power_to_step() {
        let range = PowerRange {
            min_w: 0,
            max_w: 1000,
            step_w: 5,
        };
        assert_eq!(clamp_target_power(152, &range), 150);
        assert_eq!(clamp_target_power(153, &range), 155);
        assert_eq!(clamp_target_power(5000, &range), 1000);
    }

    #[test]
    fn encode_simulation_flat_grade() {
        let frame = encode_simulation_grade(0.0);
        assert_eq!(frame[0], OP_SET_INDOOR_BIKE_SIMULATION);
        assert_eq!(frame.len(), 7);
        // wind 0
        assert_eq!(i16::from_le_bytes([frame[1], frame[2]]), 0);
        // grade 0
        assert_eq!(i16::from_le_bytes([frame[3], frame[4]]), 0);
        // crr 0.004 → 40; cw 0.51 → 51
        assert_eq!(frame[5], 40);
        assert_eq!(frame[6], 51);
        let uphill = encode_indoor_bike_simulation(0.0, 5.0, 0.004, 0.51);
        assert_eq!(i16::from_le_bytes([uphill[3], uphill[4]]), 500); // 5.00%
    }

    #[test]
    fn encode_simulation_custom_crr_cw() {
        // Crr 0.0035 → 35; Cw 0.40 → 40
        let frame = encode_indoor_bike_simulation(1.5, -2.5, 0.0035, 0.40);
        assert_eq!(frame[0], OP_SET_INDOOR_BIKE_SIMULATION);
        assert_eq!(i16::from_le_bytes([frame[1], frame[2]]), 1500); // 1.5 m/s
        assert_eq!(i16::from_le_bytes([frame[3], frame[4]]), -250); // -2.50%
        assert_eq!(frame[5], 35);
        assert_eq!(frame[6], 40);
        assert!((clamp_simulation_crr(0.05) - 0.0127).abs() < 1e-9);
        assert!((clamp_simulation_cw(3.0) - 1.86).abs() < 1e-9);
    }

    #[test]
    fn feature_bit_simulation() {
        let mut raw = vec![0u8; 8];
        // set bit 13 in features
        let features: u32 = FEATURE_BIT_INDOOR_BIKE_SIMULATION;
        raw[0..4].copy_from_slice(&features.to_le_bytes());
        assert!(features_support_simulation(&raw));
        assert!(!features_support_simulation(&[0, 0, 0, 0]));
        assert!(!features_support_simulation(&[]));
    }

    #[test]
    fn clamp_resistance_to_range() {
        let range = ResistanceRange {
            min_pct: 0.0,
            max_pct: 100.0,
            step_pct: 1.0,
        };
        assert!((clamp_resistance_percent(40.4, &range) - 40.0).abs() < 0.01);
        assert!((clamp_resistance_percent(200.0, &range) - 100.0).abs() < 0.01);
    }

    #[test]
    fn machine_status_optional_flag() {
        assert!(machine_status_is_optional());
    }

    #[test]
    fn parse_status_control_lost() {
        let ev = parse_machine_status(&[0xFF]).unwrap();
        assert_eq!(ev, MachineStatusEvent::ControlPermissionLost);
        assert!(ev.is_control_lost());
        assert!(ev.as_ux_message().contains("Control lost"));
    }

    #[test]
    fn parse_status_stop_and_pause() {
        assert_eq!(
            parse_machine_status(&[0x02, 0x01]),
            Some(MachineStatusEvent::StoppedByUser)
        );
        assert_eq!(
            parse_machine_status(&[0x02, 0x02]),
            Some(MachineStatusEvent::PausedByUser)
        );
        assert_eq!(
            parse_machine_status(&[0x03]),
            Some(MachineStatusEvent::StoppedBySafetyKey)
        );
        assert!(parse_machine_status(&[0x02, 0x01]).unwrap().is_stop_or_pause());
        assert_eq!(
            parse_machine_status(&[0x04]),
            Some(MachineStatusEvent::StartedOrResumedByUser)
        );
        assert_eq!(
            parse_machine_status(&[0x08]),
            Some(MachineStatusEvent::TargetPowerChanged)
        );
        assert!(parse_machine_status(&[]).is_none());
    }

}

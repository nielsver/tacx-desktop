//! FTMS Indoor Bike parsing and control helpers (public GATT 0x1826).

use crate::trainer::types::{PowerRange, ResistanceRange, TrainerMetrics};

pub const FTMS_SERVICE: u16 = 0x1826;
pub const INDOOR_BIKE_DATA: u16 = 0x2AD2;
pub const CONTROL_POINT: u16 = 0x2AD9;
pub const SUPPORTED_RESISTANCE_RANGE: u16 = 0x2AD6;
pub const SUPPORTED_POWER_RANGE: u16 = 0x2AD8;
pub const MACHINE_STATUS: u16 = 0x2ADA;

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
    }
    m
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
}

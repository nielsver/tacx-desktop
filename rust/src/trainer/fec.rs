//! Tacx FE-C-over-BLE (pre-FTMS trainers) — UART GATT + ANT+ FE-C framing.
//!
//! Characteristic UUIDs match pycycling.tacx_trainer_control.

use uuid::Uuid;

/// GATT Characteristic: FE-C commands to trainer (RX on device).
pub fn tacx_uart_rx() -> Uuid {
    Uuid::parse_str("6e40fec3-b5a3-f393-e0a9-e50e24dcca9e").unwrap()
}

/// GATT Characteristic: FE-C notifications from trainer (TX on device).
pub fn tacx_uart_tx() -> Uuid {
    Uuid::parse_str("6e40fec2-b5a3-f393-e0a9-e50e24dcca9e").unwrap()
}

fn checksum(bytes: &[u8]) -> u8 {
    bytes.iter().skip(1).fold(0u8, |a, b| a.wrapping_add(*b))
}

fn with_checksum(mut frame: Vec<u8>) -> Vec<u8> {
    let cs = checksum(&frame);
    frame.push(cs);
    frame
}

/// Basic resistance mode: 0–200 N. Maps UI percent → newtons.
pub fn encode_basic_resistance_newtons(newtons: f64) -> Vec<u8> {
    let n = newtons.clamp(0.0, 200.0);
    let mut frame = vec![0xA4, 0x09, 0x4F, 0x05, 0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    frame.push(((n / 200.0) * 200.0).round() as u8);
    with_checksum(frame)
}

pub fn percent_to_newtons(percent: f64) -> f64 {
    (percent.clamp(0.0, 100.0) / 100.0) * 200.0
}

/// Target power (ERG), watts 0–4000.
pub fn encode_target_power(watts: u32) -> Vec<u8> {
    let w = watts.min(4000);
    let raw = ((w as f64) / 0.25) as u16;
    let mut frame = vec![0xA4, 0x09, 0x4F, 0x05, 0x31, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];
    frame.extend_from_slice(&raw.to_le_bytes());
    with_checksum(frame)
}


/// Wind Resistance (page 50 / 0x32) — simulation mode.
/// `wind_resistance_coefficient` kg/m (0–1.86), `wind_speed_kmh` (−127..=127),
/// `drafting_factor` 0–1.
pub fn encode_wind_resistance(
    wind_resistance_coefficient: f64,
    wind_speed_kmh: f64,
    drafting_factor: f64,
) -> Result<Vec<u8>, String> {
    if !(0.0..=1.86).contains(&wind_resistance_coefficient) {
        return Err("wind_resistance_coefficient must be 0..=1.86".into());
    }
    if !(-127.0..=127.0).contains(&wind_speed_kmh) {
        return Err("wind_speed_kmh must be -127..=127".into());
    }
    if !(0.0..=1.0).contains(&drafting_factor) {
        return Err("drafting_factor must be 0..=1".into());
    }
    let mut frame = vec![0xA4, 0x09, 0x4F, 0x05, 0x32, 0xFF, 0xFF, 0xFF, 0xFF];
    frame.push((wind_resistance_coefficient / 0.01).round() as u8);
    frame.push((wind_speed_kmh + 127.0).round() as u8);
    frame.push((drafting_factor / 0.01).round() as u8);
    Ok(with_checksum(frame))
}

/// Track Resistance (page 51 / 0x33) — simulation grade + Crr.
/// `grade_pct` −200..=200, `crr` 0..=0.0127.
pub fn encode_track_resistance(grade_pct: f64, crr: f64) -> Result<Vec<u8>, String> {
    if !(-200.0..=200.0).contains(&grade_pct) {
        return Err("grade_pct must be -200..=200".into());
    }
    if !(0.0..=0.0127).contains(&crr) {
        return Err("crr must be 0..=0.0127".into());
    }
    let mut frame = vec![0xA4, 0x09, 0x4F, 0x05, 0x33, 0xFF, 0xFF, 0xFF, 0xFF];
    let grade_raw = ((grade_pct + 200.0) / 0.01).round() as u16;
    frame.extend_from_slice(&grade_raw.to_le_bytes());
    frame.push((crr / 5e-5).round() as u8);
    Ok(with_checksum(frame))
}

/// User Configuration (page 55 / 0x37) — rider/bike mass + wheel for simulation.
/// Weights in kg; `wheel_diameter_m` metres; `gear_ratio` front:rear.
pub fn encode_user_configuration(
    user_weight_kg: f64,
    bicycle_weight_kg: f64,
    wheel_diameter_m: f64,
    gear_ratio: f64,
) -> Result<Vec<u8>, String> {
    if !(0.0..=655.34).contains(&user_weight_kg) {
        return Err("user_weight_kg must be 0..=655.34".into());
    }
    if !(0.0..=50.0).contains(&bicycle_weight_kg) {
        return Err("bicycle_weight_kg must be 0..=50".into());
    }
    if !(0.0..=2.54).contains(&wheel_diameter_m) {
        return Err("wheel_diameter_m must be 0..=2.54".into());
    }
    if !(0.03..=7.65).contains(&gear_ratio) {
        return Err("gear_ratio must be 0.03..=7.65".into());
    }
    let mut frame = vec![0xA4, 0x09, 0x4F, 0x05, 0x37];
    let uw = ((user_weight_kg / 0.01).round() as u16).to_le_bytes();
    frame.extend_from_slice(&uw);
    frame.push(0xFF);
    // Match pycycling: diameter offset from hundredths + bicycle weight in 0.05 kg units.
    let diam_hundredths = (wheel_diameter_m * 100.0).round() / 100.0;
    let offset = ((wheel_diameter_m - diam_hundredths) / 0.001).round() as i32;
    let offset = offset.clamp(0, 10) as u8;
    let bw_raw = (bicycle_weight_kg / 0.05).round() as u16;
    let bw_lo = (bw_raw & 0xFF) as u8;
    let bw_hi = ((bw_raw >> 8) & 0xFF) as u8;
    frame.push(offset.wrapping_add((bw_lo << 4) & 0xFF));
    frame.push((bw_lo >> 4).wrapping_add(bw_hi << 4));
    frame.push((diam_hundredths / 0.01).round() as u8);
    frame.push((gear_ratio / 0.03).round() as u8);
    Ok(with_checksum(frame))
}

/// Parse Tacx FE-C page 25 (specific trainer data) for power/cadence.
pub fn parse_specific_trainer_page(message_data: &[u8]) -> Option<(Option<f64>, Option<f64>)> {
    // message_data starts at data page number
    if message_data.is_empty() || message_data[0] != 25 || message_data.len() < 8 {
        return None;
    }
    let cadence = if message_data[2] == 255 {
        None
    } else {
        Some(message_data[2] as f64)
    };
    let power_lsb = message_data[5] as u16;
    let power_msb = message_data[6] as u16;
    let instantaneous_power = power_lsb + ((power_msb & 0xf) << 8);
    let power = if instantaneous_power == 4095 {
        None
    } else {
        Some(instantaneous_power as f64)
    };
    Some((power, cadence))
}

/// Parse page 16 general FE data for speed (m/s → km/h).
pub fn parse_general_fe_speed(message_data: &[u8]) -> Option<f64> {
    if message_data.is_empty() || message_data[0] != 16 || message_data.len() < 7 {
        return None;
    }
    let speed_raw = u16::from_le_bytes([message_data[4], message_data[5]]);
    if speed_raw == 65535 {
        return None;
    }
    // FE-C speed is m/s * 0.001 → convert to km/h
    let mps = speed_raw as f64 * 0.001;
    Some(mps * 3.6)
}

/// Parse page 16 general FE data for heart rate (byte 6). Outer `None` = not
/// page 16; inner `None` = trainer reports no HR (0xFF / 0).
pub fn parse_general_fe_heart_rate(message_data: &[u8]) -> Option<Option<u32>> {
    if message_data.is_empty() || message_data[0] != 16 || message_data.len() < 7 {
        return None;
    }
    Some(crate::trainer::ftms::valid_heart_rate(message_data[6]))
}

/// Extract FE-C payload from Tacx UART notification (ANT+ serial frame).
pub fn extract_fec_message_data(packet: &[u8]) -> Option<Vec<u8>> {
    if packet.len() < 5 {
        return None;
    }
    let message_length = packet[1] as usize;
    if message_length < 1 || packet.len() < 4 + message_length {
        return None;
    }
    Some(packet[4..4 + message_length - 1].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resistance_frame_checksum() {
        let frame = encode_basic_resistance_newtons(40.0);
        assert_eq!(frame[0], 0xA4);
        assert_eq!(frame[4], 0x30);
        let cs = checksum(&frame[..frame.len() - 1]);
        assert_eq!(*frame.last().unwrap(), cs);
    }

    #[test]
    fn target_power_frame() {
        let frame = encode_target_power(200);
        assert_eq!(frame[4], 0x31);
        // 200 / 0.25 = 800
        assert_eq!(u16::from_le_bytes([frame[10], frame[11]]), 800);
    }

    #[test]
    fn percent_maps_to_newtons() {
        assert!((percent_to_newtons(50.0) - 100.0).abs() < 0.01);
        assert!((percent_to_newtons(100.0) - 200.0).abs() < 0.01);
    }

    #[test]
    fn parse_trainer_page_power_cadence() {
        let mut msg = vec![25u8, 1, 90, 0, 0];
        // power 250: lsb=250, msb low nibble
        msg.push(250);
        msg.push(0); // msb nibble 0
        msg.push(0);
        let (power, cad) = parse_specific_trainer_page(&msg).unwrap();
        assert_eq!(power, Some(250.0));
        assert_eq!(cad, Some(90.0));
    }

    #[test]
    fn extract_and_speed() {
        // synthetic ANT+ frame: sync, len, type, channel, page16...
        // page 16 with speed 10.000 m/s = 10000 raw → 36 km/h
        let speed: u16 = 10000;
        let mut packet = vec![0xA4, 0x09, 0x4E, 0x00, 16, 25, 0, 0];
        packet.extend_from_slice(&speed.to_le_bytes());
        packet.push(0xFF); // HR
        packet.push(0x20); // flags
        packet.push(0); // checksum placeholder
        let msg = extract_fec_message_data(&packet).unwrap();
        assert_eq!(msg[0], 16);
        let spd = parse_general_fe_speed(&msg).unwrap();
        assert!((spd - 36.0).abs() < 0.05);
        assert_eq!(parse_general_fe_heart_rate(&msg), Some(None), "0xFF = no HR");
    }

    #[test]
    fn general_fe_heart_rate() {
        let msg = [16u8, 25, 0, 0, 0x10, 0x27, 142, 0x20];
        assert_eq!(parse_general_fe_heart_rate(&msg), Some(Some(142)));
        let zero = [16u8, 25, 0, 0, 0x10, 0x27, 0, 0x20];
        assert_eq!(parse_general_fe_heart_rate(&zero), Some(None));
        let page25 = [25u8, 1, 90, 0, 0, 250, 0, 0];
        assert_eq!(parse_general_fe_heart_rate(&page25), None);
    }

    #[test]
    fn track_resistance_golden_flat() {
        // pycycling-compatible: grade 0%, Crr 0.004
        let frame = encode_track_resistance(0.0, 0.004).unwrap();
        assert_eq!(frame[4], 0x33);
        assert_eq!(
            frame,
            vec![0xA4, 0x09, 0x4F, 0x05, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0x20, 0x4E, 0x50, 0x4A]
        );
    }

    #[test]
    fn track_resistance_plus_five() {
        let frame = encode_track_resistance(5.0, 0.004).unwrap();
        assert_eq!(
            frame,
            vec![0xA4, 0x09, 0x4F, 0x05, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0x14, 0x50, 0x50, 0x40]
        );
    }

    #[test]
    fn wind_resistance_golden() {
        let frame = encode_wind_resistance(0.51, 0.0, 1.0).unwrap();
        assert_eq!(frame[4], 0x32);
        assert_eq!(
            frame,
            vec![0xA4, 0x09, 0x4F, 0x05, 0x32, 0xFF, 0xFF, 0xFF, 0xFF, 51, 127, 100, 161]
        );
    }

    #[test]
    fn user_configuration_golden() {
        let frame = encode_user_configuration(75.0, 8.0, 0.7, 3.0).unwrap();
        assert_eq!(frame[4], 0x37);
        assert_eq!(
            frame,
            vec![0xA4, 0x09, 0x4F, 0x05, 0x37, 76, 29, 0xFF, 0, 10, 70, 100, 176]
        );
    }

    #[test]
    fn sim_pages_reject_out_of_range() {
        assert!(encode_track_resistance(201.0, 0.004).is_err());
        assert!(encode_wind_resistance(2.0, 0.0, 1.0).is_err());
        assert!(encode_user_configuration(75.0, 8.0, 0.7, 0.01).is_err());
    }

}

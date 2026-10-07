//! GATT inventory helpers — dump UUID / property table after discover_services.
//! Used to classify FTMS vs FE-C-only trainers (hardware inventory readiness).

use btleplug::api::{bleuuid::uuid_from_u16, CharPropFlags, Characteristic};
use uuid::Uuid;

use crate::trainer::fec;
use crate::trainer::ftms;

/// One discovered characteristic row for logging / diagnostics.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GattRow {
    pub uuid: String,
    pub name: String,
    pub properties: String,
}

/// Trainer GATT class after service discovery.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrainerGattClass {
    /// FTMS Indoor Bike + Control Point present (may also have FE-C UART).
    Ftms,
    /// Tacx FE-C UART only (no FTMS control path).
    FecOnly,
    /// Both FTMS and Tacx UART present.
    Dual,
    /// Neither path available.
    Unsupported,
}

impl TrainerGattClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ftms => "ftms",
            Self::FecOnly => "fec_only",
            Self::Dual => "dual_ftms_fec",
            Self::Unsupported => "unsupported",
        }
    }
}

fn short_uuid(u: &Uuid) -> String {
    let s = u.to_string();
    // Compact 16-bit Bluetooth UUIDs: 0000xxxx-0000-1000-8000-00805f9b34fb
    if s.starts_with("0000") && s.ends_with("-0000-1000-8000-00805f9b34fb") {
        format!("0x{}", &s[4..8])
    } else {
        s
    }
}

fn props_label(flags: CharPropFlags) -> String {
    let mut parts = Vec::new();
    if flags.contains(CharPropFlags::BROADCAST) {
        parts.push("broadcast");
    }
    if flags.contains(CharPropFlags::READ) {
        parts.push("read");
    }
    if flags.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE) {
        parts.push("write-cmd");
    }
    if flags.contains(CharPropFlags::WRITE) {
        parts.push("write");
    }
    if flags.contains(CharPropFlags::NOTIFY) {
        parts.push("notify");
    }
    if flags.contains(CharPropFlags::INDICATE) {
        parts.push("indicate");
    }
    if parts.is_empty() {
        "none".into()
    } else {
        parts.join("|")
    }
}

fn known_name(u: &Uuid) -> String {
    let ftms = uuid_from_u16(ftms::FTMS_SERVICE);
    let bike = uuid_from_u16(ftms::INDOOR_BIKE_DATA);
    let cp = uuid_from_u16(ftms::CONTROL_POINT);
    let res = uuid_from_u16(ftms::SUPPORTED_RESISTANCE_RANGE);
    let pwr = uuid_from_u16(ftms::SUPPORTED_POWER_RANGE);
    let status = uuid_from_u16(ftms::MACHINE_STATUS);
    let feature = uuid_from_u16(0x2ACC);
    if *u == bike {
        "Indoor Bike Data".into()
    } else if *u == cp {
        "FTMS Control Point".into()
    } else if *u == res {
        "Supported Resistance Range".into()
    } else if *u == pwr {
        "Supported Power Range".into()
    } else if *u == status {
        "Fitness Machine Status".into()
    } else if *u == feature {
        "Fitness Machine Feature".into()
    } else if *u == ftms {
        "FTMS Service".into()
    } else if *u == fec::tacx_uart_rx() {
        "Tacx FE-C UART RX (write)".into()
    } else if *u == fec::tacx_uart_tx() {
        "Tacx FE-C UART TX (notify)".into()
    } else {
        "other".into()
    }
}

/// Build inventory rows from discovered characteristics.
pub fn inventory_rows(chars: &[Characteristic]) -> Vec<GattRow> {
    let mut rows: Vec<GattRow> = chars
        .iter()
        .map(|c| GattRow {
            uuid: short_uuid(&c.uuid),
            name: known_name(&c.uuid),
            properties: props_label(c.properties),
        })
        .collect();
    rows.sort_by(|a, b| a.uuid.cmp(&b.uuid));
    rows
}

/// Classify trainer from characteristic UUID set (no live hardware required for unit tests).
pub fn classify_uuids(uuids: &[Uuid]) -> TrainerGattClass {
    let bike = uuid_from_u16(ftms::INDOOR_BIKE_DATA);
    let cp = uuid_from_u16(ftms::CONTROL_POINT);
    let fec_rx = fec::tacx_uart_rx();
    let fec_tx = fec::tacx_uart_tx();
    let has_ftms = uuids.contains(&bike) && uuids.contains(&cp);
    let has_fec = uuids.contains(&fec_rx) && uuids.contains(&fec_tx);
    match (has_ftms, has_fec) {
        (true, true) => TrainerGattClass::Dual,
        (true, false) => TrainerGattClass::Ftms,
        (false, true) => TrainerGattClass::FecOnly,
        (false, false) => TrainerGattClass::Unsupported,
    }
}

pub fn classify_chars(chars: &[Characteristic]) -> TrainerGattClass {
    let uuids: Vec<Uuid> = chars.iter().map(|c| c.uuid).collect();
    classify_uuids(&uuids)
}

/// Multi-line table for logs / README inventory spikes.
pub fn format_inventory_table(chars: &[Characteristic]) -> String {
    let class = classify_chars(chars);
    let rows = inventory_rows(chars);
    let mut out = format!(
        "GATT inventory ({}) — class={}\nUUID\tName\tProperties\n",
        rows.len(),
        class.as_str()
    );
    for r in &rows {
        out.push_str(&format!("{}\t{}\t{}\n", r.uuid, r.name, r.properties));
    }
    out
}

/// One-line summary for ConnectionSnapshot.detail.
pub fn format_inventory_summary(chars: &[Characteristic]) -> String {
    let class = classify_chars(chars);
    let rows = inventory_rows(chars);
    let interesting: Vec<String> = rows
        .iter()
        .filter(|r| r.name != "other")
        .map(|r| format!("{}[{}]", r.uuid, r.properties))
        .collect();
    if interesting.is_empty() {
        format!("class={}", class.as_str())
    } else {
        format!("class={} · {}", class.as_str(), interesting.join(", "))
    }
}

/// Expected FTMS UUID checklist for inventory docs (present/absent after discover).
pub fn ftms_checklist(uuids: &[Uuid]) -> Vec<(&'static str, u16, bool)> {
    let wanted: [(&'static str, u16); 6] = [
        ("FTMS Service", ftms::FTMS_SERVICE),
        ("Indoor Bike Data", ftms::INDOOR_BIKE_DATA),
        ("Control Point", ftms::CONTROL_POINT),
        ("Supported Resistance Range", ftms::SUPPORTED_RESISTANCE_RANGE),
        ("Supported Power Range", ftms::SUPPORTED_POWER_RANGE),
        ("Fitness Machine Status", ftms::MACHINE_STATUS),
    ];
    wanted
        .into_iter()
        .map(|(name, u16v)| {
            let u = uuid_from_u16(u16v);
            (name, u16v, uuids.contains(&u))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use btleplug::api::bleuuid::uuid_from_u16;

    #[test]
    fn classify_ftms_only() {
        let uuids = vec![
            uuid_from_u16(ftms::INDOOR_BIKE_DATA),
            uuid_from_u16(ftms::CONTROL_POINT),
            uuid_from_u16(ftms::SUPPORTED_POWER_RANGE),
        ];
        assert_eq!(classify_uuids(&uuids), TrainerGattClass::Ftms);
    }

    #[test]
    fn classify_ftms_without_status_char() {
        // Soft-fail path: 0x2ADA absent must not change FTMS classification.
        let uuids = vec![
            uuid_from_u16(ftms::INDOOR_BIKE_DATA),
            uuid_from_u16(ftms::CONTROL_POINT),
        ];
        assert_eq!(classify_uuids(&uuids), TrainerGattClass::Ftms);
        assert!(!uuids.iter().any(|u| *u == uuid_from_u16(ftms::MACHINE_STATUS)));
        assert!(ftms::machine_status_is_optional());
    }

    #[test]
    fn classify_fec_only() {
        let uuids = vec![fec::tacx_uart_rx(), fec::tacx_uart_tx()];
        assert_eq!(classify_uuids(&uuids), TrainerGattClass::FecOnly);
    }

    #[test]
    fn classify_dual() {
        let uuids = vec![
            uuid_from_u16(ftms::INDOOR_BIKE_DATA),
            uuid_from_u16(ftms::CONTROL_POINT),
            fec::tacx_uart_rx(),
            fec::tacx_uart_tx(),
        ];
        assert_eq!(classify_uuids(&uuids), TrainerGattClass::Dual);
    }

    #[test]
    fn classify_unsupported() {
        assert_eq!(classify_uuids(&[]), TrainerGattClass::Unsupported);
    }

    #[test]
    fn checklist_marks_present() {
        let uuids = vec![
            uuid_from_u16(ftms::INDOOR_BIKE_DATA),
            uuid_from_u16(ftms::CONTROL_POINT),
        ];
        let c = ftms_checklist(&uuids);
        assert!(c.iter().any(|(n, _, p)| *n == "Indoor Bike Data" && *p));
        assert!(c.iter().any(|(n, _, p)| *n == "Control Point" && *p));
        assert!(c
            .iter()
            .any(|(n, _, p)| *n == "Fitness Machine Status" && !*p));
    }

    #[test]
    fn short_uuid_16bit() {
        let u = uuid_from_u16(0x2AD9);
        assert_eq!(short_uuid(&u), "0x2ad9");
    }
}

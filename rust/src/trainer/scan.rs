//! Advertisement post-filter for trainer discovery (empty BlueZ ScanFilter).
//!
//! FTMS UUID → always include. Otherwise name / manufacturer heuristics so
//! Kickr (FTMS) and legacy Tacx FE-C still appear when services are incomplete.

/// Wahoo Fitness Bluetooth company ID (Kickr / Kickr Core / Kickr Bike / …).
pub const WAHOO_COMPANY_ID: u16 = 0x0131;

/// Returns a short protocol hint for the scan list, or `None` to skip the device.
pub fn advertise_protocol_hint(
    name: &str,
    has_ftms_service: bool,
    manufacturer_ids: &[u16],
) -> Option<&'static str> {
    let name_l = name.to_lowercase();
    let looks_kickr = name_looks_kickr(&name_l)
        || manufacturer_ids.contains(&WAHOO_COMPANY_ID);
    let looks_tacx = name_looks_tacx(&name_l);

    if has_ftms_service {
        // Prefer Kickr label when we know it's Wahoo so the chip is clear.
        return Some(if looks_kickr { "kickr_ftms" } else { "ftms" });
    }
    if looks_kickr {
        // Kickr is FTMS-only; ads sometimes omit 0x1826 until connect.
        return Some("kickr_ftms");
    }
    if looks_tacx {
        // FE-C UART often missing from ads until GATT discovery.
        return Some("tacx_fec");
    }
    None
}

fn name_looks_kickr(name_l: &str) -> bool {
    // KICKR, KICKR CORE, KICKR BIKE, KICKR MOVE, KICKR SNAP, "Wahoo …"
    ["kickr", "wahoo"].iter().any(|k| name_l.contains(k))
}

fn name_looks_tacx(name_l: &str) -> bool {
    // Avoid matching generic "smart" alone — too many headphones / watches.
    ["tacx", "neo", "flux", "satori", "bushido", "vortex", "flow"]
        .iter()
        .any(|k| name_l.contains(k))
        || (name_l.contains("trainer") && (name_l.contains("tacx") || name_l.contains("garmin")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kickr_by_name_without_ftms_ads() {
        assert_eq!(
            advertise_protocol_hint("KICKR CORE", false, &[]),
            Some("kickr_ftms")
        );
        assert_eq!(
            advertise_protocol_hint("Wahoo KICKR", false, &[]),
            Some("kickr_ftms")
        );
        assert_eq!(
            advertise_protocol_hint("KICKR BIKE", false, &[]),
            Some("kickr_ftms")
        );
    }

    #[test]
    fn kickr_by_manufacturer_id() {
        assert_eq!(
            advertise_protocol_hint("(unknown)", false, &[WAHOO_COMPANY_ID]),
            Some("kickr_ftms")
        );
    }

    #[test]
    fn ftms_uuid_with_kickr_name() {
        assert_eq!(
            advertise_protocol_hint("KICKR CORE", true, &[]),
            Some("kickr_ftms")
        );
    }

    #[test]
    fn generic_ftms_still_ftms() {
        assert_eq!(
            advertise_protocol_hint("Smart Bike", true, &[]),
            Some("ftms")
        );
    }

    #[test]
    fn tacx_name_without_ftms_is_fec() {
        assert_eq!(
            advertise_protocol_hint("Tacx Neo 2T", false, &[]),
            Some("tacx_fec")
        );
        assert_eq!(
            advertise_protocol_hint("Flux 2", false, &[]),
            Some("tacx_fec")
        );
    }

    #[test]
    fn headphones_skipped() {
        assert_eq!(advertise_protocol_hint("AirPods Pro", false, &[]), None);
        assert_eq!(advertise_protocol_hint("smart watch", false, &[]), None);
    }
}

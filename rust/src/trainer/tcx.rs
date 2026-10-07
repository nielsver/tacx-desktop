//! Garmin TCX export of a recorded ride (indoor: no GPS position).
//!
//! TCX is accepted by Garmin Connect, Strava, TrainingPeaks and intervals.icu.
//! Power and speed travel in the ActivityExtension v2 namespace (`ns3:TPX`).
//! No external crates: timestamps use a civil-from-days UTC conversion.

/// One recorded second.
#[derive(Clone, Debug, PartialEq)]
pub struct TrackPoint {
    /// Wall clock, milliseconds since the Unix epoch (UTC).
    pub unix_ms: i64,
    pub power_w: f64,
    pub cadence_rpm: f64,
    pub speed_kmh: f64,
    /// Cumulative distance at this point, metres.
    pub distance_m: f64,
    /// Heart rate relayed by the trainer, bpm.
    pub heart_rate_bpm: Option<u32>,
}

/// Lap totals written into the TCX header.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LapSummary {
    pub total_time_s: f64,
    pub distance_m: f64,
    pub max_speed_kmh: f64,
    pub avg_power_w: f64,
    pub max_power_w: f64,
    pub avg_cadence_rpm: f64,
    pub energy_kj: f64,
    /// 0 = no heart-rate readings in this lap.
    pub avg_heart_rate_bpm: f64,
    pub max_heart_rate_bpm: u32,
}

/// Days since 1970-01-01 → (year, month, day). Howard Hinnant's algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn split(unix_ms: i64) -> (i64, u32, u32, i64, i64, i64) {
    let secs = unix_ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (y, mo, d) = civil_from_days(days);
    (y, mo, d, sod / 3600, (sod % 3600) / 60, sod % 60)
}

/// `2026-10-07T14:56:40Z` (whole seconds, UTC).
pub fn iso8601_utc(unix_ms: i64) -> String {
    let (y, mo, d, h, mi, s) = split(unix_ms);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// File-name safe stamp: `20261007-145640Z`.
pub fn file_stamp_utc(unix_ms: i64) -> String {
    let (y, mo, d, h, mi, s) = split(unix_ms);
    format!("{y:04}{mo:02}{d:02}-{h:02}{mi:02}{s:02}Z")
}

fn num(x: f64, max: f64) -> f64 {
    if x.is_finite() {
        x.clamp(0.0, max)
    } else {
        0.0
    }
}

/// Render a complete TCX document. Returns `None` when there are no points.
pub fn render(points: &[TrackPoint], lap: &LapSummary) -> Option<String> {
    let first = points.first()?;
    let start = iso8601_utc(first.unix_ms);
    let mut out = String::with_capacity(512 + points.len() * 260);
    out.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push_str(
        "<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\" \
xmlns:ns3=\"http://www.garmin.com/xmlschemas/ActivityExtension/v2\" \
xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" \
xsi:schemaLocation=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 \
http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd\">\n",
    );
    out.push_str("  <Activities>\n    <Activity Sport=\"Biking\">\n");
    out.push_str(&format!("      <Id>{start}</Id>\n"));
    out.push_str(&format!("      <Lap StartTime=\"{start}\">\n"));
    out.push_str(&format!(
        "        <TotalTimeSeconds>{:.1}</TotalTimeSeconds>\n",
        num(lap.total_time_s, 1e7)
    ));
    out.push_str(&format!(
        "        <DistanceMeters>{:.1}</DistanceMeters>\n",
        num(lap.distance_m, 1e8)
    ));
    out.push_str(&format!(
        "        <MaximumSpeed>{:.3}</MaximumSpeed>\n",
        num(lap.max_speed_kmh, 200.0) / 3.6
    ));
    // Mechanical kJ ≈ dietary kcal at ~24 % gross efficiency.
    out.push_str(&format!(
        "        <Calories>{}</Calories>\n",
        num(lap.energy_kj, 60_000.0).round() as u32
    ));
    // TCX HeartRateInBeatsPerMinute_t is an unsignedByte >= 1.
    let avg_hr = num(lap.avg_heart_rate_bpm, 255.0).round() as u32;
    if avg_hr >= 1 && lap.max_heart_rate_bpm >= 1 {
        out.push_str(&format!(
            "        <AverageHeartRateBpm>\n          <Value>{avg_hr}</Value>\n        </AverageHeartRateBpm>\n"
        ));
        out.push_str(&format!(
            "        <MaximumHeartRateBpm>\n          <Value>{}</Value>\n        </MaximumHeartRateBpm>\n",
            lap.max_heart_rate_bpm.min(255)
        ));
    }
    out.push_str("        <Intensity>Active</Intensity>\n");
    let avg_cad = num(lap.avg_cadence_rpm, 254.0).round() as u32;
    if avg_cad > 0 {
        out.push_str(&format!("        <Cadence>{avg_cad}</Cadence>\n"));
    }
    out.push_str("        <TriggerMethod>Manual</TriggerMethod>\n");
    out.push_str("        <Track>\n");
    for p in points {
        out.push_str("          <Trackpoint>\n");
        out.push_str(&format!("            <Time>{}</Time>\n", iso8601_utc(p.unix_ms)));
        out.push_str(&format!(
            "            <DistanceMeters>{:.1}</DistanceMeters>\n",
            num(p.distance_m, 1e8)
        ));
        if let Some(hr) = p.heart_rate_bpm.filter(|h| (1..=255).contains(h)) {
            out.push_str(&format!(
                "            <HeartRateBpm>\n              <Value>{hr}</Value>\n            </HeartRateBpm>\n"
            ));
        }
        out.push_str(&format!(
            "            <Cadence>{}</Cadence>\n",
            num(p.cadence_rpm, 254.0).round() as u32
        ));
        out.push_str("            <Extensions>\n              <ns3:TPX>\n");
        out.push_str(&format!(
            "                <ns3:Speed>{:.3}</ns3:Speed>\n",
            num(p.speed_kmh, 200.0) / 3.6
        ));
        out.push_str(&format!(
            "                <ns3:Watts>{}</ns3:Watts>\n",
            num(p.power_w, 3000.0).round() as u32
        ));
        out.push_str("              </ns3:TPX>\n            </Extensions>\n");
        out.push_str("          </Trackpoint>\n");
    }
    out.push_str("        </Track>\n");
    out.push_str("        <Extensions>\n          <ns3:LX>\n");
    let avg_speed = if lap.total_time_s > 0.0 {
        num(lap.distance_m, 1e8) / lap.total_time_s
    } else {
        0.0
    };
    out.push_str(&format!("            <ns3:AvgSpeed>{avg_speed:.3}</ns3:AvgSpeed>\n"));
    out.push_str(&format!(
        "            <ns3:AvgWatts>{}</ns3:AvgWatts>\n",
        num(lap.avg_power_w, 3000.0).round() as u32
    ));
    out.push_str(&format!(
        "            <ns3:MaxWatts>{}</ns3:MaxWatts>\n",
        num(lap.max_power_w, 3000.0).round() as u32
    ));
    out.push_str("          </ns3:LX>\n        </Extensions>\n");
    out.push_str("      </Lap>\n");
    out.push_str(&format!(
        "      <Creator xsi:type=\"Device_t\">\n        <Name>Tacx Desktop</Name>\n        <UnitId>0</UnitId>\n        <ProductID>0</ProductID>\n        <Version>\n          <VersionMajor>{}</VersionMajor>\n          <VersionMinor>{}</VersionMinor>\n        </Version>\n      </Creator>\n",
        env!("CARGO_PKG_VERSION_MAJOR"),
        env!("CARGO_PKG_VERSION_MINOR"),
    ));
    out.push_str("    </Activity>\n  </Activities>\n</TrainingCenterDatabase>\n");
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_formatting() {
        assert_eq!(iso8601_utc(0), "1970-01-01T00:00:00Z");
        // 2026-10-07T14:56:40Z
        assert_eq!(iso8601_utc(1_791_385_000_000), "2026-10-07T14:56:40Z");
        assert_eq!(file_stamp_utc(1_791_385_000_999), "20261007-145640Z");
        // Leap day.
        assert_eq!(iso8601_utc(951_782_400_000), "2000-02-29T00:00:00Z");
        assert_eq!(iso8601_utc(-1_000), "1969-12-31T23:59:59Z");
    }

    #[test]
    fn empty_ride_renders_nothing() {
        assert!(render(&[], &LapSummary::default()).is_none());
    }

    #[test]
    fn document_structure() {
        let pts: Vec<TrackPoint> = (0..3)
            .map(|i| TrackPoint {
                unix_ms: 1_791_385_000_000 + i * 1000,
                power_w: 200.4 + i as f64,
                cadence_rpm: 90.0,
                speed_kmh: 36.0,
                distance_m: 10.0 * i as f64,
                heart_rate_bpm: None,
            })
            .collect();
        let lap = LapSummary {
            total_time_s: 3.0,
            distance_m: 30.0,
            max_speed_kmh: 36.0,
            avg_power_w: 201.0,
            max_power_w: 202.0,
            avg_cadence_rpm: 90.0,
            energy_kj: 0.6,
            ..Default::default()
        };
        let x = render(&pts, &lap).unwrap();
        assert!(x.starts_with("<?xml"));
        assert!(x.contains("<Activity Sport=\"Biking\">"));
        assert!(x.contains("<Id>2026-10-07T14:56:40Z</Id>"));
        assert_eq!(x.matches("<Trackpoint>").count(), 3);
        assert!(x.contains("<Time>2026-10-07T14:56:42Z</Time>"));
        assert!(x.contains("<ns3:Watts>200</ns3:Watts>"));
        assert!(x.contains("<ns3:Speed>10.000</ns3:Speed>"));
        assert!(x.contains("<ns3:AvgSpeed>10.000</ns3:AvgSpeed>"));
        assert!(x.contains("<ns3:MaxWatts>202</ns3:MaxWatts>"));
        assert!(x.contains("<Cadence>90</Cadence>"));
        // Schema order inside Lap: Calories before Intensity before TriggerMethod before Track.
        let i = |s: &str| x.find(s).unwrap();
        assert!(i("<TotalTimeSeconds>") < i("<DistanceMeters>"));
        assert!(i("<Calories>") < i("<Intensity>"));
        assert!(i("<Intensity>") < i("<TriggerMethod>"));
        assert!(i("<TriggerMethod>") < i("<Track>"));
        assert!(x.trim_end().ends_with("</TrainingCenterDatabase>"));
        // Balanced tags for the elements we emit.
        for tag in ["Activity", "Lap", "Track", "Trackpoint", "Extensions", "ns3:TPX"] {
            let open = x.matches(&format!("<{tag}>")).count()
                + x.matches(&format!("<{tag} ")).count();
            assert_eq!(open, x.matches(&format!("</{tag}>")).count(), "{tag}");
        }
    }

    #[test]
    fn garbage_is_clamped() {
        let pts = [TrackPoint {
            unix_ms: 0,
            power_w: f64::NAN,
            cadence_rpm: 9999.0,
            speed_kmh: -3.0,
            distance_m: f64::INFINITY,
            heart_rate_bpm: Some(0),
        }];
        let x = render(&pts, &LapSummary::default()).unwrap();
        assert!(x.contains("<ns3:Watts>0</ns3:Watts>"));
        assert!(x.contains("<Cadence>254</Cadence>"));
        assert!(x.contains("<ns3:Speed>0.000</ns3:Speed>"));
        assert!(!x.contains("NaN") && !x.contains("inf"));
        assert!(!x.contains("HeartRateBpm"), "0 bpm is not a valid TCX value");
    }

    #[test]
    fn heart_rate_in_trackpoints_and_lap() {
        let pts: Vec<TrackPoint> = (0..2)
            .map(|i| TrackPoint {
                unix_ms: 1_791_385_000_000 + i * 1000,
                power_w: 200.0,
                cadence_rpm: 90.0,
                speed_kmh: 36.0,
                distance_m: 10.0 * i as f64,
                heart_rate_bpm: if i == 0 { None } else { Some(141) },
            })
            .collect();
        let lap = LapSummary {
            total_time_s: 2.0,
            avg_heart_rate_bpm: 140.6,
            max_heart_rate_bpm: 141,
            ..Default::default()
        };
        let x = render(&pts, &lap).unwrap();
        assert_eq!(x.matches("<HeartRateBpm>").count(), 1);
        assert!(x.contains("<HeartRateBpm>\n              <Value>141</Value>"));
        assert!(x.contains("<AverageHeartRateBpm>\n          <Value>141</Value>"));
        assert!(x.contains("<MaximumHeartRateBpm>\n          <Value>141</Value>"));
        // Schema order: Calories < AverageHR < MaximumHR < Intensity; DistanceMeters < HR < Cadence.
        let i = |s: &str| x.find(s).unwrap();
        assert!(i("<Calories>") < i("<AverageHeartRateBpm>"));
        assert!(i("<AverageHeartRateBpm>") < i("<MaximumHeartRateBpm>"));
        assert!(i("<MaximumHeartRateBpm>") < i("<Intensity>"));
        let tp = &x[x.rfind("<Trackpoint>").unwrap()..];
        assert!(tp.find("<DistanceMeters>").unwrap() < tp.find("<HeartRateBpm>").unwrap());
        assert!(tp.find("<HeartRateBpm>").unwrap() < tp.find("<Cadence>").unwrap());
    }
}


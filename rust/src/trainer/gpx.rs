//! GPX 1.0/1.1 track parse → distance + elevation profile → grade %.

use crate::trainer::types::{ElevSample, GpxProfileInfo};

#[derive(Clone, Debug)]
struct TrackPoint {
    lat: f64,
    lon: f64,
    ele: Option<f64>,
}

/// Haversine distance in metres.
pub fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let rlat1 = lat1.to_radians();
    let rlat2 = lat2.to_radians();
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2)
        + rlat1.cos() * rlat2.cos() * (dlon / 2.0).sin().powi(2);
    let c = 2.0 * a.sqrt().atan2((1.0 - a).sqrt());
    R * c
}

fn extract_attr<'a>(tag: &'a str, attr: &str) -> Option<&'a str> {
    let key = format!("{attr}=\"");
    let i = tag.find(&key)?;
    let rest = &tag[i + key.len()..];
    let end = rest.find('"')?;
    Some(&rest[..end])
}

fn extract_ele(chunk: &str) -> Option<f64> {
    let start = chunk.find("<ele>")? + 5;
    let end = chunk[start..].find("</ele>")? + start;
    chunk[start..end].trim().parse().ok()
}

fn extract_name(xml: &str) -> String {
    if let Some(i) = xml.find("<name>") {
        let start = i + 6;
        if let Some(rel) = xml[start..].find("</name>") {
            return xml[start..start + rel].trim().to_string();
        }
    }
    "GPX route".into()
}

/// Minimal GPX track parse (no external XML crate). Accepts GPX 1.0/1.1 `trkpt`.
pub fn parse_gpx(xml: &str) -> Result<GpxProfileInfo, String> {
    let name = extract_name(xml);
    let mut pts = Vec::new();
    let mut rest = xml;
    while let Some(i) = rest.find("<trkpt") {
        let after = &rest[i..];
        let tag_end = after.find('>').ok_or("Malformed <trkpt>")?;
        let open = &after[..=tag_end];
        let lat: f64 = extract_attr(open, "lat")
            .ok_or("trkpt missing lat")?
            .parse()
            .map_err(|_| "bad lat")?;
        let lon: f64 = extract_attr(open, "lon")
            .ok_or("trkpt missing lon")?
            .parse()
            .map_err(|_| "bad lon")?;
        let close_rel = after.find("</trkpt>").or_else(|| {
            // Self-closing already handled if open ends with />
            if open.trim_end().ends_with("/>") {
                Some(tag_end)
            } else {
                None
            }
        });
        let chunk = if open.trim_end().ends_with("/>") {
            open
        } else {
            let c = close_rel.ok_or("trkpt not closed")?;
            &after[..c + 8]
        };
        let ele = extract_ele(chunk);
        pts.push(TrackPoint { lat, lon, ele });
        rest = &after[tag_end + 1..];
    }
    if pts.len() < 2 {
        return Err("GPX has no usable track points".into());
    }
    if pts.iter().filter(|p| p.ele.is_some()).count() < 2 {
        return Err("GPX has no elevation — need <ele> on track points".into());
    }

    // Forward-fill missing elevation.
    let mut last_ele = pts.iter().find_map(|p| p.ele).unwrap();
    for p in &mut pts {
        if let Some(e) = p.ele {
            last_ele = e;
        } else {
            p.ele = Some(last_ele);
        }
    }

    let mut samples = Vec::with_capacity(pts.len());
    let mut dist = 0.0;
    let mut elev_gain = 0.0;
    let mut prev_ele = pts[0].ele.unwrap();
    samples.push(ElevSample {
        distance_m: 0.0,
        elev_m: prev_ele,
        grade_pct: 0.0,
    });

    for i in 1..pts.len() {
        let d = haversine_m(pts[i - 1].lat, pts[i - 1].lon, pts[i].lat, pts[i].lon);
        if d < 0.05 {
            continue; // skip GPS jitter duplicates
        }
        dist += d;
        let ele = pts[i].ele.unwrap();
        let de = ele - prev_ele;
        if de > 0.0 {
            elev_gain += de;
        }
        let grade = (de / d) * 100.0;
        samples.push(ElevSample {
            distance_m: dist,
            elev_m: ele,
            grade_pct: grade.clamp(-25.0, 25.0),
        });
        prev_ele = ele;
    }

    if samples.len() < 2 || dist < 1.0 {
        return Err("GPX track too short".into());
    }

    // Smooth grade with a small moving average.
    smooth_grades(&mut samples, 5);

    Ok(GpxProfileInfo {
        name,
        distance_m: dist,
        elev_gain_m: elev_gain,
        samples,
    })
}

fn smooth_grades(samples: &mut [ElevSample], window: usize) {
    if samples.len() < 3 || window < 2 {
        return;
    }
    let raw: Vec<f64> = samples.iter().map(|s| s.grade_pct).collect();
    let half = window / 2;
    for (i, s) in samples.iter_mut().enumerate() {
        let lo = i.saturating_sub(half);
        let hi = (i + half + 1).min(raw.len());
        let slice = &raw[lo..hi];
        let mean = slice.iter().sum::<f64>() / slice.len() as f64;
        s.grade_pct = mean.clamp(-20.0, 20.0);
    }
}

/// Interpolate grade at cumulative ride distance (metres), with look-ahead.
pub fn grade_at_distance(profile: &GpxProfileInfo, distance_m: f64, look_ahead_m: f64) -> f64 {
    if profile.samples.is_empty() {
        return 0.0;
    }
    if distance_m >= profile.distance_m {
        return 0.0;
    }
    let target = (distance_m + look_ahead_m * 0.5).min(profile.distance_m);
    // Find surrounding samples.
    let samples = &profile.samples;
    if target <= samples[0].distance_m {
        return samples[0].grade_pct;
    }
    for i in 1..samples.len() {
        if samples[i].distance_m >= target {
            let a = &samples[i - 1];
            let b = &samples[i];
            let span = (b.distance_m - a.distance_m).max(0.001);
            let t = ((target - a.distance_m) / span).clamp(0.0, 1.0);
            return a.grade_pct + (b.grade_pct - a.grade_pct) * t;
        }
    }
    samples.last().map(|s| s.grade_pct).unwrap_or(0.0)
}

/// Limit grade change rate (°% / s).
pub fn slew_grade(current: f64, target: f64, dt_s: f64, max_delta_per_s: f64) -> f64 {
    let max_step = max_delta_per_s * dt_s.max(0.001);
    let delta = (target - current).clamp(-max_step, max_step);
    (current + delta).clamp(-20.0, 20.0)
}

/// Simple physics: power to overcome grade (optional ERG warp). Default off in UI.
pub fn watts_from_grade(grade_pct: f64, speed_mps: f64, mass_kg: f64) -> u32 {
    let speed = speed_mps.max(1.0);
    let grade = grade_pct / 100.0;
    // P ≈ m g v * grade + rolling (~0.004) — coarse indoor estimate.
    let g = 9.81;
    let p_grade = mass_kg * g * speed * grade;
    let p_roll = mass_kg * g * speed * 0.004;
    let p = p_grade + p_roll;
    // clamp() would keep NaN (→ 0 W after the cast); fall back to the floor.
    if !p.is_finite() {
        return 80;
    }
    p.clamp(80.0, 1500.0).round() as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watts_from_grade_is_clamped_and_nan_safe() {
        assert_eq!(watts_from_grade(f64::NAN, 5.0, 75.0), 80);
        assert_eq!(watts_from_grade(0.0, f64::INFINITY, 75.0), 80);
        assert_eq!(watts_from_grade(-10.0, 8.0, 75.0), 80);
        assert_eq!(watts_from_grade(30.0, 10.0, 120.0), 1500);
        let w = watts_from_grade(5.0, 5.0, 75.0);
        assert!((150..250).contains(&w), "{w}");
    }

    const SAMPLE: &str = r#"<?xml version="1.0"?>
<gpx version="1.1"><trk><name>Test Climb</name><trkseg>
<trkpt lat="50.0" lon="4.0"><ele>100</ele></trkpt>
<trkpt lat="50.001" lon="4.0"><ele>110</ele></trkpt>
<trkpt lat="50.002" lon="4.0"><ele>125</ele></trkpt>
<trkpt lat="50.003" lon="4.0"><ele>120</ele></trkpt>
</trkseg></trk></gpx>"#;

    #[test]
    fn parse_elev_and_grade() {
        let p = parse_gpx(SAMPLE).unwrap();
        assert!(p.distance_m > 200.0, "dist={}", p.distance_m);
        assert!(p.elev_gain_m >= 20.0, "gain={}", p.elev_gain_m);
        assert!(p.samples.len() >= 3);
        let g = grade_at_distance(&p, 50.0, 20.0);
        assert!(g > 0.0, "expected climb grade, got {g}");
    }

    #[test]
    fn end_of_route_grade_zero() {
        let p = parse_gpx(SAMPLE).unwrap();
        assert_eq!(grade_at_distance(&p, p.distance_m + 10.0, 20.0), 0.0);
    }

    #[test]
    fn slew_limits_spike() {
        let next = slew_grade(0.0, 15.0, 0.25, 2.0);
        assert!(next <= 0.5 + 1e-6, "got {next}");
    }

    #[test]
    fn rejects_no_elevation() {
        let xml = r#"<gpx><trk><trkseg>
<trkpt lat="1" lon="2"></trkpt>
<trkpt lat="1.001" lon="2"></trkpt>
</trkseg></trk></gpx>"#;
        assert!(parse_gpx(xml).unwrap_err().contains("elevation"));
    }
}

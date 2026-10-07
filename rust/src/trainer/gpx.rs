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

/// Attribute value for `attr` in an opening tag; accepts `"…"` or `'…'` and
/// only matches whole attribute names (`lat` never matches `xlat`).
fn extract_attr<'a>(tag: &'a str, attr: &str) -> Option<&'a str> {
    let bytes = tag.as_bytes();
    let mut from = 0;
    while let Some(rel) = tag[from..].find(attr) {
        let i = from + rel;
        from = i + attr.len();
        let before_ok = i > 0 && bytes[i - 1].is_ascii_whitespace();
        if !before_ok {
            continue;
        }
        let rest = tag[i + attr.len()..].trim_start();
        let Some(rest) = rest.strip_prefix('=') else {
            continue;
        };
        let rest = rest.trim_start();
        let q = rest.chars().next()?;
        if q != '"' && q != '\'' {
            continue;
        }
        let body = &rest[1..];
        let end = body.find(q)?;
        return Some(&body[..end]);
    }
    None
}

fn extract_ele(chunk: &str) -> Option<f64> {
    let start = chunk.find("<ele>")? + 5;
    let end = chunk[start..].find("</ele>")? + start;
    let v: f64 = chunk[start..end].trim().parse().ok()?;
    // NaN / inf / absurd values count as "no elevation" for this point.
    (v.is_finite() && (-500.0..=9000.0).contains(&v)).then_some(v)
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

fn parse_coord(open: &str, attr: &str, limit: f64) -> Result<f64, String> {
    let raw = extract_attr(open, attr).ok_or_else(|| format!("point missing {attr}"))?;
    let v: f64 = raw.trim().parse().map_err(|_| format!("bad {attr}"))?;
    if !v.is_finite() || v.abs() > limit {
        return Err(format!("{attr} out of range: {raw}"));
    }
    Ok(v)
}

/// All `<tag …>` points (trkpt or rtept) in document order.
fn collect_points(xml: &str, tag: &str) -> Result<Vec<TrackPoint>, String> {
    let open_pat = format!("<{tag}");
    let close_pat = format!("</{tag}>");
    let mut pts = Vec::new();
    let mut rest = xml;
    while let Some(i) = rest.find(&open_pat) {
        let after = &rest[i..];
        // `<trkpt` must be followed by whitespace, `>` or `/` (not `<trkptx`).
        let next = after.as_bytes().get(open_pat.len()).copied().unwrap_or(b'>');
        if !(next.is_ascii_whitespace() || next == b'>' || next == b'/') {
            rest = &after[open_pat.len()..];
            continue;
        }
        let tag_end = after.find('>').ok_or_else(|| format!("Malformed <{tag}>"))?;
        let open = &after[..=tag_end];
        let lat = parse_coord(open, "lat", 90.0)?;
        let lon = parse_coord(open, "lon", 180.0)?;
        let self_closing = open.trim_end().ends_with("/>");
        let chunk = if self_closing {
            open
        } else {
            let c = after
                .find(&close_pat)
                .ok_or_else(|| format!("<{tag}> not closed"))?;
            &after[..c + close_pat.len()]
        };
        pts.push(TrackPoint {
            lat,
            lon,
            ele: extract_ele(chunk),
        });
        rest = &after[tag_end + 1..];
    }
    Ok(pts)
}

/// Climb threshold for elevation gain: GPS/DEM noise below this is ignored.
const GAIN_HYSTERESIS_M: f64 = 2.0;
/// Grade is computed over this distance window (centred), not per sample,
/// so dense or sparse point spacing gives the same grade.
const GRADE_WINDOW_M: f64 = 50.0;

/// Minimal GPX parse (no external XML crate). Accepts GPX 1.0/1.1 track
/// points (`<trkpt>`), falling back to route points (`<rtept>`).
pub fn parse_gpx(xml: &str) -> Result<GpxProfileInfo, String> {
    let name = extract_name(xml);
    let mut pts = collect_points(xml, "trkpt")?;
    if pts.is_empty() {
        pts = collect_points(xml, "rtept")?;
    }
    if pts.len() < 2 {
        return Err("GPX has no usable track points".into());
    }
    if pts.iter().filter(|p| p.ele.is_some()).count() < 2 {
        return Err("GPX has no elevation — need <ele> on track points".into());
    }

    // Forward-fill missing elevation (leading gaps take the first value).
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
    let mut kept = &pts[0];
    samples.push(ElevSample {
        distance_m: 0.0,
        elev_m: kept.ele.unwrap(),
        grade_pct: 0.0,
        lat: kept.lat,
        lon: kept.lon,
    });
    for p in &pts[1..] {
        // Distance from the last *kept* point, so skipped jitter isn't lost.
        let d = haversine_m(kept.lat, kept.lon, p.lat, p.lon);
        if !d.is_finite() || d < 0.05 {
            continue; // GPS jitter duplicates
        }
        dist += d;
        samples.push(ElevSample {
            distance_m: dist,
            elev_m: p.ele.unwrap(),
            grade_pct: 0.0,
            lat: p.lat,
            lon: p.lon,
        });
        kept = p;
    }

    if samples.len() < 2 || dist < 1.0 {
        return Err("GPX track too short".into());
    }

    let elev_gain = elevation_gain(&samples, GAIN_HYSTERESIS_M);
    grades_over_distance(&mut samples, GRADE_WINDOW_M);
    let route_key = route_key_v2(&samples);

    Ok(GpxProfileInfo {
        name,
        distance_m: dist,
        elev_gain_m: elev_gain,
        samples,
        route_key,
    })
}

/// Total climb with hysteresis: a rise only counts once it is at least
/// [threshold] above the last low point, so noise doesn't add up.
pub fn elevation_gain(samples: &[ElevSample], threshold: f64) -> f64 {
    let Some(first) = samples.first() else {
        return 0.0;
    };
    let mut gain = 0.0;
    let mut low = first.elev_m;
    let mut high = first.elev_m;
    let mut climbing = false;
    for s in &samples[1..] {
        let e = s.elev_m;
        if climbing {
            if e > high {
                gain += e - high;
                high = e;
            } else if high - e >= threshold {
                climbing = false;
                low = e;
            }
        } else if e < low {
            low = e;
        } else if e - low >= threshold {
            gain += e - low;
            high = e;
            climbing = true;
        }
    }
    gain
}

/// Elevation at distance [d] by linear interpolation (clamped to the ends).
fn elev_at(samples: &[ElevSample], d: f64) -> f64 {
    if d <= samples[0].distance_m {
        return samples[0].elev_m;
    }
    let last = samples.last().unwrap();
    if d >= last.distance_m {
        return last.elev_m;
    }
    let j = samples.partition_point(|s| s.distance_m <= d);
    let (a, b) = (&samples[j - 1], &samples[j]);
    let t = (d - a.distance_m) / (b.distance_m - a.distance_m).max(1e-9);
    a.elev_m + (b.elev_m - a.elev_m) * t
}

/// Grade at each sample from the elevation change across a centred
/// [window_m] distance window (shrunk at the route ends), clamped ±20 %.
fn grades_over_distance(samples: &mut [ElevSample], window_m: f64) {
    let total = samples.last().map(|s| s.distance_m).unwrap_or(0.0);
    let grades: Vec<f64> = samples
        .iter()
        .map(|s| {
            let a = (s.distance_m - window_m / 2.0).max(0.0);
            let b = (s.distance_m + window_m / 2.0).min(total);
            if b - a < 1.0 {
                return 0.0;
            }
            let g = (elev_at(samples, b) - elev_at(samples, a)) / (b - a) * 100.0;
            if g.is_finite() {
                g.clamp(-20.0, 20.0)
            } else {
                0.0
            }
        })
        .collect();
    for (s, g) in samples.iter_mut().zip(grades) {
        s.grade_pct = g;
    }
}

/// Stable route identity (v2): SHA-256 over the route resampled to 128
/// points by distance (lat/lon at 1e-4°, ~11 m) plus the total distance at
/// 10 m. Different places or the reverse direction give different keys;
/// a renamed track, a re-export with more/fewer points, or re-rounded
/// elevations keep the key.
///
/// Elevation is deliberately *not* hashed: any per-point elevation
/// quantisation flips on re-exported data (QA G5 Q4: elevations rounded to
/// 1 m changed the key), and lat/lon + distance already pin the road. Exact
/// hashing can't absorb every perturbation, so the ghost file also stores a
/// coarse signature (`route_signature`) for a tolerant fallback match.
pub fn route_key_v2(samples: &[ElevSample]) -> String {
    use sha2::{Digest, Sha256};
    const N: usize = 128;
    let mut h = Sha256::new();
    h.update(b"tacx-route-v2");
    let total = samples.last().map(|s| s.distance_m).unwrap_or(0.0);
    h.update(((total / 10.0).round() as i64).to_le_bytes());
    if samples.len() >= 2 {
        let mut j = 0;
        for i in 0..N {
            let d = total * i as f64 / (N - 1) as f64;
            while j + 2 < samples.len() && samples[j + 1].distance_m < d {
                j += 1;
            }
            let (a, b) = (&samples[j], &samples[j + 1]);
            let t = ((d - a.distance_m) / (b.distance_m - a.distance_m).max(1e-9)).clamp(0.0, 1.0);
            let l = |x: f64, y: f64| x + (y - x) * t;
            h.update(((l(a.lat, b.lat) * 1e4).round() as i32).to_le_bytes());
            h.update(((l(a.lon, b.lon) * 1e4).round() as i32).to_le_bytes());
        }
    }
    let hex: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
    format!("v2-{}", &hex[..16])
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

    /// Builds a GPX string from (lat, lon, ele) triples.
    fn gpx_of(name: &str, pts: &[(f64, f64, f64)]) -> String {
        let mut x = format!("<gpx version=\"1.1\"><trk><name>{name}</name><trkseg>\n");
        for (lat, lon, ele) in pts {
            x += &format!("<trkpt lat=\"{lat}\" lon=\"{lon}\"><ele>{ele}</ele></trkpt>\n");
        }
        x + "</trkseg></trk></gpx>"
    }

    /// A ~5 km northbound line starting at (lat0, lon0), 1 point / ~11 m.
    fn line(lat0: f64, lon0: f64, ele: impl Fn(usize) -> f64) -> Vec<(f64, f64, f64)> {
        (0..=450).map(|i| (lat0 + i as f64 * 1e-4, lon0, ele(i))).collect()
    }

    #[test]
    fn lat_lon_exposed_on_samples() {
        let p = parse_gpx(SAMPLE).unwrap();
        assert_eq!((p.samples[0].lat, p.samples[0].lon), (50.0, 4.0));
        let last = p.samples.last().unwrap();
        assert_eq!((last.lat, last.lon), (50.003, 4.0));
        assert!(p.route_key.starts_with("v2-") && p.route_key.len() == 19, "{}", p.route_key);
    }

    #[test]
    fn single_quotes_rtept_and_bad_numbers() {
        let sq = SAMPLE.replace('"', "'");
        let p = parse_gpx(&sq).unwrap();
        assert_eq!(p.samples.len(), 4);
        let rte = SAMPLE
            .replace("<trk>", "<rte>")
            .replace("</trk>", "</rte>")
            .replace("<trkseg>", "")
            .replace("</trkseg>", "")
            .replace("trkpt", "rtept");
        let r = parse_gpx(&rte).unwrap();
        assert_eq!(r.route_key, p.route_key);
        assert!(parse_gpx(&SAMPLE.replace("lat=\"50.002\"", "lat=\"NaN\"")).is_err());
        assert!(parse_gpx(&SAMPLE.replace("lon=\"4.0\"", "lon=\"inf\"")).is_err());
        assert!(parse_gpx(&SAMPLE.replace("lat=\"50.001\"", "lat=\"95\"")).is_err());
        // NaN elevation on one point = missing → forward-filled, still parses.
        let p = parse_gpx(&SAMPLE.replace("<ele>110</ele>", "<ele>NaN</ele>")).unwrap();
        assert!(p.samples.iter().all(|s| s.elev_m.is_finite()));
        // `xlat` must not be read as `lat`.
        let tricky = SAMPLE.replace("<trkpt lat=\"50.0\"", "<trkpt xlat=\"1\" lat=\"50.0\"");
        assert_eq!(parse_gpx(&tricky).unwrap().samples[0].lat, 50.0);
    }

    #[test]
    fn grade_is_per_distance_not_per_sample() {
        // Same 5 % climb, sampled every ~11 m vs every ~1.1 m.
        let sparse = line(50.0, 4.0, |i| 100.0 + i as f64 * 11.12 * 0.05);
        let dense: Vec<_> = (0..=4500)
            .map(|i| (50.0 + i as f64 * 1e-5, 4.0, 100.0 + i as f64 * 1.112 * 0.05))
            .collect();
        let a = parse_gpx(&gpx_of("a", &sparse)).unwrap();
        let b = parse_gpx(&gpx_of("b", &dense)).unwrap();
        let ga = grade_at_distance(&a, 2500.0, 0.0);
        let gb = grade_at_distance(&b, 2500.0, 0.0);
        assert!((ga - 5.0).abs() < 0.2 && (gb - 5.0).abs() < 0.2, "{ga} {gb}");
    }

    #[test]
    fn elevation_gain_ignores_noise() {
        // Flat route with ±0.5 m jitter: no gain. One real 30 m climb: ~30 m.
        let noisy = line(50.0, 4.0, |i| 100.0 + if i % 2 == 0 { 0.5 } else { -0.5 });
        assert!(parse_gpx(&gpx_of("n", &noisy)).unwrap().elev_gain_m < 1.0);
        let climb = line(50.0, 4.0, |i| 100.0 + (i.min(300) as f64) * 0.1);
        let g = parse_gpx(&gpx_of("c", &climb)).unwrap().elev_gain_m;
        assert!((g - 30.0).abs() < 0.5, "{g}");
    }

    #[test]
    fn route_key_v2_identity_rules() {
        let flat = |lat0, lon0| parse_gpx(&gpx_of("Flat", &line(lat0, lon0, |_| 10.0))).unwrap();
        // Two flat 5 km routes in different places → different keys.
        assert_ne!(flat(50.0, 4.0).route_key, flat(51.0, 5.0).route_key);
        // Same route, renamed → same key.
        let base = line(50.0, 4.0, |i| 100.0 + (i as f64 * 0.37).sin() * 20.0);
        let k = parse_gpx(&gpx_of("A", &base)).unwrap().route_key;
        assert_eq!(parse_gpx(&gpx_of("Renamed", &base)).unwrap().route_key, k);
        // Elevation re-exported rounded to 1 m → same key.
        let rounded: Vec<_> = base.iter().map(|&(a, b, e)| (a, b, e.round())).collect();
        assert_eq!(parse_gpx(&gpx_of("A", &rounded)).unwrap().route_key, k);
        // One extra (interpolated) point → same key.
        let mut extra = base.clone();
        let (a, b) = (extra[100], extra[101]);
        extra.insert(101, ((a.0 + b.0) / 2.0, a.1, (a.2 + b.2) / 2.0));
        assert_eq!(parse_gpx(&gpx_of("A", &extra)).unwrap().route_key, k);
        // Reversed → different key.
        let mut rev = base.clone();
        rev.reverse();
        assert_ne!(parse_gpx(&gpx_of("A", &rev)).unwrap().route_key, k);
        // A reversed *flat* route differs too (start point differs).
        let f = line(50.0, 4.0, |_| 10.0);
        let mut fr = f.clone();
        fr.reverse();
        assert_ne!(
            parse_gpx(&gpx_of("F", &f)).unwrap().route_key,
            parse_gpx(&gpx_of("F", &fr)).unwrap().route_key
        );
        // Same road with another elevation source (offset DEM) → same key.
        let higher: Vec<_> = base.iter().map(|&(a, b, e)| (a, b, e + 5.0)).collect();
        assert_eq!(parse_gpx(&gpx_of("A", &higher)).unwrap().route_key, k);
        // Same shape shifted ~1 km east → different key.
        let moved: Vec<_> = base.iter().map(|&(a, b, e)| (a, b + 0.014, e)).collect();
        assert_ne!(parse_gpx(&gpx_of("A", &moved)).unwrap().route_key, k);
    }
}


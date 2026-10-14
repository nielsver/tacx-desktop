//! Local streaks / XP / badges and a fitness model (step 4, S1–S3 +
//! CTL/ATL). Pure `apply`, stored in `Tacx Desktop/progress.json` v1
//! (tmp + rename). Timezone-free: Dart passes the local date, the local day
//! index and the ISO-week index, computed once and stored as given, so DST or
//! travel never moves a past day. Demo efforts never count.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const MIN_MOVING_S: u32 = 600;
pub const MIN_AVG_W: f64 = 40.0;
pub const XP_PER_EFFORT_CAP: u32 = 150;
pub const XP_COMPLETION_BONUS: u32 = 10;
pub const XP_DAILY_CAP: u32 = 300;
pub const CTL_DAYS: f64 = 42.0;
pub const ATL_DAYS: f64 = 7.0;
/// Processed uids and per-day bookkeeping older than this are pruned.
pub const KEEP_DAYS: i64 = 400;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Totals {
    pub km: f64,
    pub kj: f64,
    pub efforts: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Badge {
    pub id: String,
    pub date: String,
    pub effort: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RideDay {
    pub date: String,
    /// Local day index (days since 1970-01-01 local).
    pub day: i64,
    /// ISO week index (Monday-based, consecutive across years).
    pub week: i64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ProgressState {
    pub version: u32,
    /// Effort uids already applied, `"{start_ms}-{kind}-{key}"`, with their day.
    pub processed: BTreeMap<String, i64>,
    pub ride_days: Vec<RideDay>,
    pub xp: u64,
    pub xp_by_day: BTreeMap<String, u32>,
    pub totals: Totals,
    pub badges: Vec<Badge>,
    /// TSS per local day index (non-demo) for CTL / ATL.
    #[serde(default)]
    pub tss_by_day: BTreeMap<i64, f64>,
    #[serde(default)]
    pub rebuilt: bool,
}

impl Default for ProgressState {
    fn default() -> Self {
        Self {
            version: 1,
            processed: BTreeMap::new(),
            ride_days: Vec::new(),
            xp: 0,
            xp_by_day: BTreeMap::new(),
            totals: Totals::default(),
            badges: Vec::new(),
            tss_by_day: BTreeMap::new(),
            rebuilt: false,
        }
    }
}

/// What one finished effort contributes.
#[derive(Clone, Debug, Default)]
pub struct EffortInput {
    pub uid: String,
    pub demo: bool,
    /// "free" | "route" | "workout"
    pub kind: String,
    pub completed: bool,
    pub ftp_test: bool,
    pub moving_s: u32,
    pub energy_kj: f64,
    pub distance_km: f64,
    pub tss: Option<f64>,
    pub local_date: String,
    pub day: i64,
    pub week: i64,
    /// Beat an existing ghost best on this route.
    pub ghost_beat: bool,
    /// Set at least one climb PR.
    pub climb_pr: bool,
    /// The rider accepted an FTP from a test on this effort.
    pub ftp_accepted: bool,
    /// …and it was higher than the previous accepted FTP.
    pub ftp_up: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ApplyResult {
    pub xp_gained: u32,
    pub new_badges: Vec<String>,
    pub counted: bool,
}

pub fn qualifies(e: &EffortInput) -> bool {
    !e.demo
        && e.moving_s >= MIN_MOVING_S
        && e.energy_kj * 1000.0 / f64::from(e.moving_s.max(1)) >= MIN_AVG_W
}

/// XP before the daily cap.
pub fn xp_for(e: &EffortInput) -> u32 {
    if !qualifies(e) {
        return 0;
    }
    let base = ((e.energy_kj / 10.0).round() as u32).min(XP_PER_EFFORT_CAP);
    let bonus = if e.completed && (e.kind == "route" || e.kind == "workout") {
        XP_COMPLETION_BONUS
    } else {
        0
    };
    base + bonus
}

/// Level shown in the UI (not stored): 100, 400, 900 XP …
pub fn level(xp: u64) -> u32 {
    ((xp as f64 / 100.0).sqrt().floor() as u32) + 1
}

fn award(st: &mut ProgressState, out: &mut Vec<String>, id: &str, e: &EffortInput) {
    if st.badges.iter().any(|b| b.id == id) {
        return;
    }
    st.badges.push(Badge { id: id.into(), date: e.local_date.clone(), effort: e.uid.clone() });
    out.push(id.into());
}

/// Ride days in ISO week `week`.
pub fn days_in_week(st: &ProgressState, week: i64) -> u32 {
    st.ride_days.iter().filter(|d| d.week == week).count() as u32
}

/// Consecutive ISO weeks with ≥ `target` ride days, ending at `current_week`.
/// An unfinished current week below target doesn't break the streak.
pub fn streak_weeks(st: &ProgressState, current_week: i64, target: u32) -> u32 {
    let target = target.clamp(1, 7);
    let mut w = current_week;
    let mut n = 0;
    if days_in_week(st, w) >= target {
        n += 1;
    }
    w -= 1;
    while days_in_week(st, w) >= target {
        n += 1;
        w -= 1;
    }
    n
}

/// Apply one effort (idempotent by uid). `target` = weekly ride-day goal.
pub fn apply(st: &mut ProgressState, e: &EffortInput, target: u32) -> ApplyResult {
    let mut r = ApplyResult::default();
    if e.demo || e.uid.is_empty() || st.processed.contains_key(&e.uid) {
        return r;
    }
    st.processed.insert(e.uid.clone(), e.day);
    if !qualifies(e) {
        return r;
    }
    r.counted = true;
    let used = st.xp_by_day.get(&e.local_date).copied().unwrap_or(0);
    let gained = xp_for(e).min(XP_DAILY_CAP.saturating_sub(used));
    st.xp_by_day.insert(e.local_date.clone(), used + gained);
    st.xp += u64::from(gained);
    r.xp_gained = gained;
    if !st.ride_days.iter().any(|d| d.date == e.local_date) {
        st.ride_days.push(RideDay { date: e.local_date.clone(), day: e.day, week: e.week });
        st.ride_days.sort_by_key(|d| d.day);
    }
    let km_before = st.totals.km;
    st.totals.km += e.distance_km.max(0.0);
    st.totals.kj += e.energy_kj.max(0.0);
    st.totals.efforts += 1;
    if let Some(t) = e.tss.filter(|t| t.is_finite() && *t > 0.0) {
        *st.tss_by_day.entry(e.day).or_insert(0.0) += t;
    }

    let b = &mut r.new_badges;
    award(st, b, "first_ride", e);
    if e.completed && e.kind == "route" {
        award(st, b, "first_route", e);
    }
    if e.completed && e.kind == "workout" && !e.ftp_test {
        award(st, b, "first_workout", e);
    }
    if e.ftp_accepted {
        award(st, b, "first_ftp_test", e);
    }
    if e.ftp_up {
        award(st, b, "ftp_up", e);
    }
    if e.moving_s >= 3600 {
        award(st, b, "hour_ride", e);
    }
    for (km, id) in [(100.0, "km_100"), (500.0, "km_500"), (1000.0, "km_1000")] {
        if km_before < km && st.totals.km >= km {
            award(st, b, id, e);
        }
    }
    if e.ghost_beat {
        award(st, b, "ghost_beat", e);
    }
    if e.climb_pr {
        award(st, b, "climb_pr", e);
    }
    if streak_weeks(st, e.week, target) >= 4 {
        award(st, b, "streak_4w", e);
    }
    prune(st, e.day);
    r
}

fn prune(st: &mut ProgressState, today: i64) {
    let cut = today - KEEP_DAYS;
    st.processed.retain(|_, d| *d >= cut);
    let keep: std::collections::BTreeSet<String> =
        st.ride_days.iter().filter(|d| d.day >= today - 14).map(|d| d.date.clone()).collect();
    st.xp_by_day.retain(|k, _| keep.contains(k));
}

/// Fitness (CTL, 42-day), fatigue (ATL, 7-day) and form = CTL − ATL at
/// local day `today`, from daily TSS. EWMA: x += (tss − x) / N per day.
pub fn fitness(tss_by_day: &BTreeMap<i64, f64>, today: i64) -> (f64, f64, f64) {
    let Some((&first, _)) = tss_by_day.iter().next() else {
        return (0.0, 0.0, 0.0);
    };
    let (mut ctl, mut atl) = (0.0f64, 0.0f64);
    for d in first..=today {
        let t = tss_by_day.get(&d).copied().unwrap_or(0.0);
        ctl += (t - ctl) / CTL_DAYS;
        atl += (t - atl) / ATL_DAYS;
    }
    (ctl, atl, ctl - atl)
}

pub fn progress_path() -> PathBuf {
    crate::trainer::ride::default_export_dir().join("progress.json")
}

/// Load; a corrupt file is moved to `.bad` and an empty state returned
/// (the caller can rebuild from TCX).
pub fn load(path: &Path) -> ProgressState {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return ProgressState::default();
    };
    match serde_json::from_str::<ProgressState>(&raw) {
        Ok(s) if s.version == 1 => s,
        _ => {
            let _ = std::fs::rename(path, path.with_extension("json.bad"));
            ProgressState::default()
        }
    }
}

pub fn save(path: &Path, st: &ProgressState) -> Result<(), String> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string(st).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn eff(uid: &str, date: &str, day: i64, week: i64, kj: f64, moving: u32) -> EffortInput {
        EffortInput {
            uid: uid.into(),
            kind: "free".into(),
            moving_s: moving,
            energy_kj: kj,
            distance_km: 30.0,
            local_date: date.into(),
            day,
            week,
            ..Default::default()
        }
    }

    #[test]
    fn same_uid_twice_counts_once() {
        let mut s = ProgressState::default();
        let e = eff("1-free-", "2026-10-14", 100, 14, 540.0, 3600);
        assert_eq!(apply(&mut s, &e, 2).xp_gained, 54);
        let snap = s.clone();
        assert_eq!(apply(&mut s, &e, 2), ApplyResult::default());
        assert_eq!(s, snap);
    }

    #[test]
    fn demo_gives_nothing() {
        let mut s = ProgressState::default();
        let mut e = eff("1-free-", "2026-10-14", 100, 14, 540.0, 3600);
        e.demo = true;
        e.tss = Some(50.0);
        assert_eq!(apply(&mut s, &e, 2), ApplyResult::default());
        assert!(s.ride_days.is_empty() && s.badges.is_empty() && s.tss_by_day.is_empty());
        assert!(s.processed.is_empty());
    }

    #[test]
    fn idle_effort_is_zero_xp_and_not_qualifying() {
        let mut s = ProgressState::default();
        let e = eff("1-free-", "2026-10-14", 100, 14, 0.0, 1800); // 30 min at 0 W
        assert!(!qualifies(&e));
        let r = apply(&mut s, &e, 2);
        assert_eq!(r.xp_gained, 0);
        assert!(!r.counted && s.ride_days.is_empty());
        // 10-min floor and 40 W floor.
        assert!(!qualifies(&eff("x", "d", 0, 0, 100.0, 599)));
        assert!(!qualifies(&eff("x", "d", 0, 0, 23.0, 600))); // 38 W
        assert!(qualifies(&eff("x", "d", 0, 0, 24.0, 600))); // 40 W
    }

    #[test]
    fn xp_rules_and_daily_cap() {
        let mut w = eff("a", "d", 0, 0, 540.0, 3600);
        w.kind = "workout".into();
        w.completed = true;
        assert_eq!(xp_for(&w), 64);
        assert_eq!(xp_for(&eff("b", "d", 0, 0, 2700.0, 10800)), 150);
        let mut s = ProgressState::default();
        let total: u32 = (0..3)
            .map(|i| apply(&mut s, &eff(&format!("{i}-free-"), "2026-10-14", 100, 14, 1500.0, 3600), 2).xp_gained)
            .sum();
        assert_eq!(total, 300);
        assert_eq!(s.xp, 300);
        assert_eq!(level(300), 2);
        assert_eq!(level(400), 3);
    }

    #[test]
    fn midnight_crossing_counts_for_start_day() {
        // 23:50 → 00:40: Dart passes the start's local date.
        let mut s = ProgressState::default();
        apply(&mut s, &eff("1-free-", "2026-10-14", 100, 14, 600.0, 3000), 2);
        assert_eq!(s.ride_days.len(), 1);
        assert_eq!(s.ride_days[0].date, "2026-10-14");
    }

    #[test]
    fn dst_week_is_one_iso_week() {
        // Sat 24 + Mon 26 Oct 2026 would straddle; Sun 25 Oct (DST end) and
        // Thu 22 Oct are the same ISO week (W43) as given by Dart.
        let mut s = ProgressState::default();
        apply(&mut s, &eff("1-free-", "2026-10-22", 20383, 2911, 300.0, 3600), 2);
        apply(&mut s, &eff("2-free-", "2026-10-25", 20386, 2911, 300.0, 3600), 2);
        assert_eq!(days_in_week(&s, 2911), 2);
        assert_eq!(streak_weeks(&s, 2911, 2), 1);
    }

    #[test]
    fn streak_weeks_rules() {
        let mut s = ProgressState::default();
        let mut n = 0;
        let mut ride = |s: &mut ProgressState, week: i64, dow: i64| {
            n += 1;
            let day = week * 7 + dow;
            apply(s, &eff(&format!("{n}-free-"), &format!("d{day}"), day, week, 300.0, 3600), 2)
        };
        for w in 10..14 {
            ride(&mut s, w, 0);
            let r = ride(&mut s, w, 3);
            if w == 13 {
                assert!(r.new_badges.contains(&"streak_4w".to_string()));
            }
        }
        assert_eq!(streak_weeks(&s, 13, 2), 4);
        // Week 14 in progress with one ride: not broken yet.
        ride(&mut s, 14, 0);
        assert_eq!(streak_weeks(&s, 14, 2), 4);
        // Week 14 ended with 1 day → broken at week 15.
        assert_eq!(streak_weeks(&s, 15, 2), 0);
    }

    #[test]
    fn badges_once_each() {
        let mut s = ProgressState::default();
        let mut e = eff("1-route-k", "2026-10-14", 100, 14, 900.0, 3700);
        e.kind = "route".into();
        e.completed = true;
        e.ghost_beat = true;
        e.distance_km = 120.0;
        let r = apply(&mut s, &e, 2);
        for b in ["first_ride", "first_route", "hour_ride", "km_100", "ghost_beat"] {
            assert!(r.new_badges.contains(&b.to_string()), "{b}: {r:?}");
        }
        let mut e2 = e.clone();
        e2.uid = "2-route-k".into();
        assert!(apply(&mut s, &e2, 2).new_badges.is_empty());
        let mut f = eff("3-workout-ftp_ramp", "2026-10-15", 101, 14, 300.0, 1500);
        f.kind = "workout".into();
        f.completed = true;
        f.ftp_test = true;
        f.ftp_accepted = true;
        let r = apply(&mut s, &f, 2);
        assert_eq!(r.new_badges, vec!["first_ftp_test".to_string()], "FTP test isn't first_workout");
    }

    #[test]
    fn fitness_matches_hand_computed_ewma() {
        // Day 0: 100 TSS, day 1: 0, day 2: 50.
        let m: BTreeMap<i64, f64> = [(0, 100.0), (2, 50.0)].into();
        let (ctl, atl, form) = fitness(&m, 2);
        let c0 = 100.0 / 42.0;
        let c1 = c0 - c0 / 42.0;
        let c2 = c1 + (50.0 - c1) / 42.0;
        let a0 = 100.0 / 7.0;
        let a1 = a0 - a0 / 7.0;
        let a2 = a1 + (50.0 - a1) / 7.0;
        assert!((ctl - c2).abs() < 1e-12 && (atl - a2).abs() < 1e-12);
        assert!((form - (c2 - a2)).abs() < 1e-12);
        // Hand values: CTL ≈ 3.4594, ATL ≈ 17.6385, form ≈ −14.18.
        assert!((ctl - 3.4594).abs() < 1e-3, "{ctl}");
        assert!((atl - 17.6385).abs() < 1e-3, "{atl}");
        assert_eq!(fitness(&BTreeMap::new(), 5), (0.0, 0.0, 0.0));
    }

    #[test]
    fn corrupt_file_moves_to_bad_and_save_is_atomic() {
        let dir = std::env::temp_dir().join(format!("tacx-progress-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("progress.json");
        std::fs::write(&p, "{not json").unwrap();
        assert_eq!(load(&p), ProgressState::default());
        assert!(dir.join("progress.json.bad").exists());
        let mut s = ProgressState::default();
        apply(&mut s, &eff("1-free-", "2026-10-14", 100, 14, 540.0, 3600), 2);
        save(&p, &s).unwrap();
        assert_eq!(load(&p), s);
        assert!(!dir.join("progress.json.tmp").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// What the UI shows (summary line, settings).
#[derive(Clone, Debug, Default)]
pub struct ProgressView {
    pub xp: u64,
    pub level: u32,
    pub xp_gained: u32,
    pub new_badges: Vec<String>,
    pub streak_weeks: u32,
    pub week_days: u32,
    pub weekly_target: u32,
    pub badges: Vec<Badge>,
    pub total_km: f64,
    pub efforts: u32,
    pub ctl: f64,
    pub atl: f64,
    /// CTL − ATL ("form today").
    pub form: f64,
}

/// Award a badge outside an effort (FTP accepted after the summary).
pub fn award_badge(st: &mut ProgressState, id: &str, date: &str, uid: &str) -> bool {
    if st.badges.iter().any(|b| b.id == id) {
        return false;
    }
    st.badges.push(Badge { id: id.into(), date: date.into(), effort: uid.into() });
    true
}

pub fn view(st: &ProgressState, week: i64, today: i64, target: u32) -> ProgressView {
    let (ctl, atl, form) = fitness(&st.tss_by_day, today);
    ProgressView {
        xp: st.xp,
        level: level(st.xp),
        streak_weeks: streak_weeks(st, week, target),
        week_days: days_in_week(st, week),
        weekly_target: target.clamp(1, 7),
        badges: st.badges.clone(),
        total_km: st.totals.km,
        efforts: st.totals.efforts,
        ctl,
        atl,
        form,
        ..Default::default()
    }
}

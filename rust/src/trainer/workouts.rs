//! Structured workouts: JSON library under Documents/Tacx Desktop/workouts/,
//! multi-step ERG/ramp/resistance/simGrade engine, built-in pack.

use crate::trainer::ride::default_export_dir;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

pub const WORKOUT_FILE_SUFFIX: &str = ".tacxworkout.json";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkoutFile {
    pub version: u32,
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub builtin: bool,
    pub steps: Vec<WorkoutStep>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WorkoutStep {
    /// erg | resistance | ramp | simGrade
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_s: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub distance_m: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watts: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watts_start: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub watts_end: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resistance_pct: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grade_pct: Option<f64>,
}

impl WorkoutStep {
    pub fn erg(duration_s: u32, watts: u32) -> Self {
        Self {
            kind: "erg".into(),
            duration_s: Some(duration_s),
            distance_m: None,
            watts: Some(watts),
            watts_start: None,
            watts_end: None,
            resistance_pct: None,
            grade_pct: None,
        }
    }

    pub fn ramp(duration_s: u32, start: u32, end: u32) -> Self {
        Self {
            kind: "ramp".into(),
            duration_s: Some(duration_s),
            distance_m: None,
            watts: None,
            watts_start: Some(start),
            watts_end: Some(end),
            resistance_pct: None,
            grade_pct: None,
        }
    }

    pub fn sim_grade(duration_s: u32, grade_pct: f64) -> Self {
        Self {
            kind: "simGrade".into(),
            duration_s: Some(duration_s),
            distance_m: None,
            watts: None,
            watts_start: None,
            watts_end: None,
            resistance_pct: None,
            grade_pct: Some(grade_pct),
        }
    }

    pub fn duration_or_zero(&self) -> u32 {
        self.duration_s.unwrap_or(0)
    }
}

use crate::trainer::types::{WorkoutInfo, WorkoutStatus};

pub fn workouts_dir() -> PathBuf {
    default_export_dir().join("workouts")
}

pub fn routes_dir() -> PathBuf {
    default_export_dir().join("routes")
}

pub fn ensure_dirs() -> Result<(), String> {
    std::fs::create_dir_all(workouts_dir())
        .map_err(|e| format!("Could not create workouts dir: {e}"))?;
    std::fs::create_dir_all(routes_dir())
        .map_err(|e| format!("Could not create routes dir: {e}"))?;
    Ok(())
}

fn builtins() -> Vec<WorkoutFile> {
    let mut out = Vec::new();

    // Existing interval presets as step lists (immutable builtins).
    out.push(interval_builtin(
        "10x30_30",
        "10×30/30",
        "Classic VO2 bursts — 10×30s work / 30s recovery",
        10,
        30,
        30,
        280,
        120,
    ));
    out.push(interval_builtin(
        "5x3_2",
        "5×3/2",
        "Sweet-spot / threshold blocks — 5×3min / 2min",
        5,
        180,
        120,
        250,
        140,
    ));
    out.push(interval_builtin(
        "4x4_3",
        "Norwegian 4×4",
        "Norwegian 4×4 — 4×4min / 3min",
        4,
        240,
        180,
        270,
        130,
    ));

    out.push(WorkoutFile {
        version: 1,
        id: "warmup_15".into(),
        name: "Easy warm-up".into(),
        description: "5′ @ 120 → ramp 5′ → 150 → 5′ @ 130".into(),
        builtin: true,
        steps: vec![
            WorkoutStep::erg(300, 120),
            WorkoutStep::ramp(300, 120, 150),
            WorkoutStep::erg(300, 130),
        ],
    });

    let mut sweet = Vec::new();
    for i in 0..3 {
        sweet.push(WorkoutStep::erg(600, 230));
        if i < 2 {
            sweet.push(WorkoutStep::erg(300, 140));
        }
    }
    out.push(WorkoutFile {
        version: 1,
        id: "sweet_3x10".into(),
        name: "Sweet spot 3×10".into(),
        description: "3×10′ @ 230 / 5′ @ 140".into(),
        builtin: true,
        steps: sweet,
    });

    let mut vo2 = Vec::new();
    for i in 0..5 {
        vo2.push(WorkoutStep::erg(180, 300));
        if i < 4 {
            vo2.push(WorkoutStep::erg(180, 120));
        }
    }
    out.push(WorkoutFile {
        version: 1,
        id: "vo2_5x3".into(),
        name: "VO2 5×3".into(),
        description: "5×3′ @ 300 / 3′ @ 120".into(),
        builtin: true,
        steps: vo2,
    });

    out.push(WorkoutFile {
        version: 1,
        id: "recovery_30".into(),
        name: "Spin recovery".into(),
        description: "30′ @ 100 W flat".into(),
        builtin: true,
        steps: vec![WorkoutStep::erg(1800, 100)],
    });

    // Hilly sim demo — 20′ of grade changes.
    let grades = [2.0, 4.0, 6.0, 3.0, -1.0, 5.0, 2.0, 0.0, 4.0, 1.0];
    out.push(WorkoutFile {
        version: 1,
        id: "hilly_sim_20".into(),
        name: "Hilly sim demo".into(),
        description: "20′ simulation grade script (±1…6 %). Needs trainer sim.".into(),
        builtin: true,
        steps: grades
            .iter()
            .map(|g| WorkoutStep::sim_grade(120, *g))
            .collect(),
    });

    out
}

fn interval_builtin(
    id: &str,
    name: &str,
    desc: &str,
    repeats: u32,
    work_s: u32,
    rest_s: u32,
    work_w: u32,
    rest_w: u32,
) -> WorkoutFile {
    let mut steps = Vec::new();
    for i in 0..repeats {
        steps.push(WorkoutStep::erg(work_s, work_w));
        if i + 1 < repeats {
            steps.push(WorkoutStep::erg(rest_s, rest_w));
        }
    }
    WorkoutFile {
        version: 1,
        id: id.into(),
        name: name.into(),
        description: desc.into(),
        builtin: true,
        steps,
    }
}

fn to_info(w: &WorkoutFile) -> WorkoutInfo {
    let total: u32 = w.steps.iter().map(|s| s.duration_or_zero()).sum();
    WorkoutInfo {
        id: w.id.clone(),
        name: w.name.clone(),
        description: w.description.clone(),
        builtin: w.builtin,
        step_count: w.steps.len() as u32,
        total_duration_s: total,
    }
}

pub fn list_workouts() -> Result<Vec<WorkoutInfo>, String> {
    ensure_dirs()?;
    let mut map = std::collections::BTreeMap::new();
    for b in builtins() {
        map.insert(b.id.clone(), to_info(&b));
    }
    let dir = workouts_dir();
    if let Ok(rd) = std::fs::read_dir(&dir) {
        for ent in rd.flatten() {
            let path = ent.path();
            let name = path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_string();
            if !name.ends_with(WORKOUT_FILE_SUFFIX) {
                continue;
            }
            match load_workout_file(&path) {
                Ok(w) => {
                    // User files override display for same id only if not builtin key conflict —
                    // builtins stay immutable; user copy gets new id on save-as.
                    if !w.builtin {
                        map.insert(w.id.clone(), to_info(&w));
                    }
                }
                Err(e) => log::warn!("Skip workout {}: {e}", path.display()),
            }
        }
    }
    Ok(map.into_values().collect())
}

pub fn load_workout(id: &str) -> Result<WorkoutFile, String> {
    if let Some(b) = builtins().into_iter().find(|w| w.id == id) {
        return Ok(b);
    }
    let path = workouts_dir().join(format!("{id}{WORKOUT_FILE_SUFFIX}"));
    load_workout_file(&path)
}

fn load_workout_file(path: &Path) -> Result<WorkoutFile, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| format!("Could not read {}: {e}", path.display()))?;
    let mut w: WorkoutFile = serde_json::from_str(&raw)
        .map_err(|e| format!("Invalid workout JSON {}: {e}", path.display()))?;
    w.builtin = false;
    if w.version == 0 {
        w.version = 1;
    }
    w.validate()
        .map_err(|e| format!("Invalid workout {}: {e}", path.display()))?;
    Ok(w)
}

pub fn save_workout(mut workout: WorkoutFile) -> Result<String, String> {
    ensure_dirs()?;
    if workout.builtin || builtins().iter().any(|b| b.id == workout.id) {
        // Force save-as copy for builtins.
        workout.id = unique_user_id(&workout.name);
        workout.builtin = false;
    }
    workout.builtin = false;
    workout.version = 1;
    if workout.steps.is_empty() {
        return Err("Add at least one step before saving".into());
    }
    workout.validate()?;
    let path = workouts_dir().join(format!("{}{WORKOUT_FILE_SUFFIX}", workout.id));
    let json = serde_json::to_string_pretty(&workout)
        .map_err(|e| format!("JSON encode failed: {e}"))?;
    std::fs::write(&path, json)
        .map_err(|e| format!("Could not write {}: {e}", path.display()))?;
    Ok(path.display().to_string())
}

pub fn delete_workout(id: &str) -> Result<(), String> {
    if builtins().iter().any(|b| b.id == id) {
        return Err("Built-in workouts cannot be deleted".into());
    }
    let path = workouts_dir().join(format!("{id}{WORKOUT_FILE_SUFFIX}"));
    if path.exists() {
        std::fs::remove_file(&path)
            .map_err(|e| format!("Could not delete {}: {e}", path.display()))?;
    }
    Ok(())
}

fn unique_user_id(name: &str) -> String {
    let slug: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    let slug = slug.trim_matches('_');
    let base = if slug.is_empty() { "workout" } else { slug };
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() % 1_000_000)
        .unwrap_or(0);
    format!("{base}_{stamp}")
}

pub fn workout_to_json(w: &WorkoutFile) -> Result<String, String> {
    serde_json::to_string_pretty(w).map_err(|e| e.to_string())
}

pub fn workout_from_json(s: &str) -> Result<WorkoutFile, String> {
    serde_json::from_str(s).map_err(|e| e.to_string())
}

/// Hard limits for user workouts (also applied to builtins in tests).
pub const MAX_STEP_WATTS: u32 = 2000;
pub const MAX_STEP_DURATION_S: u32 = 6 * 3600;
pub const GRADE_LIMIT_PCT: f64 = 25.0;

impl WorkoutFile {
    /// Rejects workouts the engine cannot run faithfully: no steps, unknown
    /// kinds, missing/zero durations (distance-only steps are not supported
    /// yet), missing targets, or targets outside trainer-safe ranges.
    pub fn validate(&self) -> Result<(), String> {
        if self.steps.is_empty() {
            return Err("Workout has no steps".into());
        }
        for (i, s) in self.steps.iter().enumerate() {
            let n = i + 1;
            let dur = s.duration_s.unwrap_or(0);
            if dur == 0 {
                return Err(if s.distance_m.is_some() {
                    format!("Step {n}: distance-only steps are not supported yet — use durationS")
                } else {
                    format!("Step {n}: durationS must be at least 1 s")
                });
            }
            if dur > MAX_STEP_DURATION_S {
                return Err(format!("Step {n}: durationS over 6 h"));
            }
            let watts_ok = |w: Option<u32>, what: &str| -> Result<(), String> {
                match w {
                    None => Err(format!("Step {n}: {what} is required")),
                    Some(w) if w > MAX_STEP_WATTS => {
                        Err(format!("Step {n}: {what} {w} W is over {MAX_STEP_WATTS} W"))
                    }
                    _ => Ok(()),
                }
            };
            match s.kind.as_str() {
                "erg" => watts_ok(s.watts, "watts")?,
                "ramp" => {
                    watts_ok(s.watts_start, "wattsStart")?;
                    watts_ok(s.watts_end, "wattsEnd")?;
                }
                "resistance" => match s.resistance_pct {
                    Some(p) if p.is_finite() && (0.0..=100.0).contains(&p) => {}
                    _ => return Err(format!("Step {n}: resistancePct must be 0–100")),
                },
                "simGrade" => match s.grade_pct {
                    Some(g) if g.is_finite() && g.abs() <= GRADE_LIMIT_PCT => {}
                    _ => {
                        return Err(format!(
                            "Step {n}: gradePct must be within ±{GRADE_LIMIT_PCT} %"
                        ))
                    }
                },
                other => return Err(format!("Step {n}: unknown step kind '{other}'")),
            }
        }
        Ok(())
    }

    fn has_sim_step(&self) -> bool {
        self.steps.iter().any(|s| s.kind == "simGrade")
    }
}

/// What the engine wants applied right now.
#[derive(Clone, Debug, PartialEq)]
pub enum WorkoutCommand {
    Erg(u32),
    Resistance(f64),
    SimGrade(f64),
}

/// Engine clock: tokio's Instant so tests can use `tokio::time::pause()`.
type Instant = tokio::time::Instant;

/// Ramps re-send ERG at most this often...
const RAMP_RESEND_EVERY: Duration = Duration::from_secs(1);
/// ...and only when the target moved by at least this much.
const RAMP_MIN_DELTA_W: u32 = 2;
/// Engine tick while waiting for a step deadline.
const TICK: Duration = Duration::from_millis(250);

struct EngineInner {
    running: bool,
    done: bool,
    /// Last run's failure (command rejected, unknown step…), cleared on start.
    error: Option<String>,
    /// Bumped by every `run` and `stop`; a run loop exits as soon as it sees
    /// a newer generation, so two runs can never drive the trainer at once.
    generation: u64,
    workout: Option<WorkoutFile>,
    step_index: usize,
    step_started: Instant,
    step_duration: Duration,
    /// For ramp interpolation.
    ramp_start_w: u32,
    ramp_end_w: u32,
}

#[derive(Clone)]
pub struct WorkoutEngine {
    inner: Arc<Mutex<EngineInner>>,
}

impl Default for WorkoutEngine {
    fn default() -> Self {
        Self::new()
    }
}

fn step_command(step: &WorkoutStep) -> Result<WorkoutCommand, String> {
    Ok(match step.kind.as_str() {
        "erg" => WorkoutCommand::Erg(step.watts.unwrap_or(0)),
        "ramp" => WorkoutCommand::Erg(step.watts_start.unwrap_or(100)),
        "resistance" => WorkoutCommand::Resistance(step.resistance_pct.unwrap_or(20.0)),
        "simGrade" => WorkoutCommand::SimGrade(step.grade_pct.unwrap_or(0.0)),
        other => return Err(format!("Unknown step kind: {other}")),
    })
}

impl WorkoutEngine {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(EngineInner {
                running: false,
                done: false,
                error: None,
                generation: 0,
                workout: None,
                step_index: 0,
                step_started: Instant::now(),
                step_duration: Duration::ZERO,
                ramp_start_w: 0,
                ramp_end_w: 0,
            })),
        }
    }

    pub fn status(&self) -> WorkoutStatus {
        let g = self.inner.lock();
        let Some(w) = g.workout.as_ref() else {
            return WorkoutStatus {
                status_text: match &g.error {
                    Some(e) => format!("Stopped: {e}"),
                    None => "Idle".into(),
                },
                error: g.error.clone(),
                ..Default::default()
            };
        };
        let remaining = if g.running {
            g.step_duration
                .saturating_sub(g.step_started.elapsed())
                .as_secs_f64()
        } else {
            0.0
        };
        let (target_watts, target_grade, phase) = if g.running {
            if let Some(step) = w.steps.get(g.step_index) {
                match step.kind.as_str() {
                    "ramp" => (Some(ramp_watts(&g)), None, "RAMP"),
                    "erg" => (step.watts, None, "ERG"),
                    "resistance" => (None, None, "RES"),
                    "simGrade" => (None, step.grade_pct, "SIM"),
                    _ => (None, None, "?"),
                }
            } else {
                (None, None, "—")
            }
        } else if g.done {
            (None, None, "Done")
        } else {
            (None, None, "Idle")
        };
        let rem = remaining.round().max(0.0) as u64;
        let status_text = if g.running {
            format!(
                "{} · {} {}/{} · {:02}:{:02}",
                w.name,
                phase,
                g.step_index + 1,
                w.steps.len(),
                rem / 60,
                rem % 60
            )
        } else if g.done {
            format!("{} · Done", w.name)
        } else if let Some(e) = &g.error {
            format!("{} · Stopped: {e}", w.name)
        } else {
            "Idle".into()
        };
        WorkoutStatus {
            running: g.running,
            workout_id: w.id.clone(),
            workout_name: w.name.clone(),
            step_index: g.step_index as u32,
            step_count: w.steps.len() as u32,
            remaining_s: remaining,
            target_watts,
            target_grade_pct: target_grade,
            status_text,
            done: g.done,
            error: g.error.clone(),
        }
    }

    pub fn current_command(&self) -> Option<WorkoutCommand> {
        let g = self.inner.lock();
        if !g.running {
            return None;
        }
        let step = g.workout.as_ref()?.steps.get(g.step_index)?;
        match step.kind.as_str() {
            "ramp" => Some(WorkoutCommand::Erg(ramp_watts(&g))),
            _ => step_command(step).ok(),
        }
    }

    pub fn stop(&self) {
        let mut g = self.inner.lock();
        g.generation += 1;
        g.running = false;
        g.done = false;
        g.error = None;
        g.workout = None;
        g.step_index = 0;
    }

    /// Runs [workout] to completion, sending commands through [on_cmd].
    ///
    /// Every exit path leaves a consistent state: finished → `done`, failed →
    /// `error` set and `running = false`, superseded by a newer `run`/`stop`
    /// → untouched (the newer owner manages it). Step boundaries follow an
    /// absolute schedule from the workout start, so command latency and tick
    /// overshoot never accumulate.
    pub async fn run<F, Fut>(&self, workout: WorkoutFile, mut on_cmd: F) -> Result<(), String>
    where
        F: FnMut(WorkoutCommand) -> Fut,
        Fut: std::future::Future<Output = Result<(), String>>,
    {
        if workout.steps.is_empty() {
            return Err("Workout has no steps".into());
        }
        let gen = {
            let mut g = self.inner.lock();
            g.generation += 1;
            g.done = false;
            g.error = None;
            g.running = true;
            g.workout = Some(workout.clone());
            g.step_index = 0;
            g.step_started = Instant::now();
            g.step_duration = Duration::ZERO;
            g.generation
        };

        let result = self.run_steps(gen, &workout, &mut on_cmd).await;

        let finished = {
            let mut g = self.inner.lock();
            if g.generation != gen {
                return Ok(()); // superseded: the newer run/stop owns the state
            }
            g.running = false;
            match &result {
                Ok(()) => {
                    g.done = true;
                    true
                }
                Err(e) => {
                    g.done = false;
                    g.error = Some(e.clone());
                    log::warn!("Workout '{}' stopped: {e}", workout.name);
                    false
                }
            }
        };
        // Flatten grade at the end of workouts that used simulation only;
        // ERG-only workouts must not flip an FTMS trainer into sim mode.
        if finished && workout.has_sim_step() {
            if let Err(e) = on_cmd(WorkoutCommand::SimGrade(0.0)).await {
                log::warn!("Workout end: could not flatten grade: {e}");
            }
        }
        result
    }

    fn superseded(&self, gen: u64) -> bool {
        self.inner.lock().generation != gen
    }

    async fn run_steps<F, Fut>(
        &self,
        gen: u64,
        workout: &WorkoutFile,
        on_cmd: &mut F,
    ) -> Result<(), String>
    where
        F: FnMut(WorkoutCommand) -> Fut,
        Fut: std::future::Future<Output = Result<(), String>>,
    {
        let t0 = Instant::now();
        let mut step_start = t0;
        for (idx, step) in workout.steps.iter().enumerate() {
            let dur = Duration::from_secs(step.duration_or_zero().max(1) as u64);
            let deadline = step_start + dur;
            {
                let mut g = self.inner.lock();
                if g.generation != gen {
                    return Ok(());
                }
                g.step_index = idx;
                g.step_duration = dur;
                // Scheduled start, not "now": latency doesn't stretch steps.
                g.step_started = step_start;
                if step.kind == "ramp" {
                    g.ramp_start_w = step.watts_start.unwrap_or(100);
                    g.ramp_end_w = step.watts_end.unwrap_or(150);
                }
            }

            let cmd = step_command(step)?;
            on_cmd(cmd.clone()).await?;
            let mut last_sent = match cmd {
                WorkoutCommand::Erg(w) => Some((w, Instant::now())),
                _ => None,
            };

            loop {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                tokio::time::sleep_until(deadline.min(now + TICK)).await;
                if self.superseded(gen) {
                    return Ok(());
                }
                if step.kind == "ramp" {
                    let w = {
                        let g = self.inner.lock();
                        ramp_watts(&g)
                    };
                    let due = match last_sent {
                        Some((lw, at)) => {
                            at.elapsed() >= RAMP_RESEND_EVERY && lw.abs_diff(w) >= RAMP_MIN_DELTA_W
                        }
                        None => true,
                    };
                    if due && Instant::now() < deadline {
                        // A dropped ramp update is not fatal: the next one
                        // (≤ 1 s later) carries the newer target anyway.
                        if let Err(e) = on_cmd(WorkoutCommand::Erg(w)).await {
                            log::warn!("Ramp update {w} W failed: {e}");
                        }
                        last_sent = Some((w, Instant::now()));
                    }
                }
            }
            step_start = deadline;
        }
        Ok(())
    }
}

fn ramp_watts(g: &EngineInner) -> u32 {
    let t = g.step_started.elapsed().as_secs_f64() / g.step_duration.as_secs_f64().max(0.001);
    let t = t.clamp(0.0, 1.0);
    let w = g.ramp_start_w as f64 + (g.ramp_end_w as f64 - g.ramp_start_w as f64) * t;
    w.round() as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_roundtrip_warmup() {
        let w = load_workout("warmup_15").unwrap();
        let json = workout_to_json(&w).unwrap();
        let back = workout_from_json(&json).unwrap();
        assert_eq!(back.id, "warmup_15");
        assert_eq!(back.steps.len(), 3);
        assert_eq!(back.steps[1].kind, "ramp");
        assert_eq!(back.steps[1].watts_start, Some(120));
        assert_eq!(back.steps[1].watts_end, Some(150));
    }

    #[test]
    fn builtins_cover_checklist_keys() {
        let ids: Vec<_> = builtins().into_iter().map(|w| w.id).collect();
        for key in [
            "10x30_30",
            "5x3_2",
            "4x4_3",
            "warmup_15",
            "sweet_3x10",
            "vo2_5x3",
            "recovery_30",
            "hilly_sim_20",
        ] {
            assert!(ids.iter().any(|i| i == key), "missing {key}");
        }
        assert!(ids.len() >= 7);
    }

    #[test]
    fn builtin_ids_are_immutable_keys() {
        let w = load_workout("recovery_30").unwrap();
        assert!(w.builtin);
        assert!(builtins().iter().any(|b| b.id == w.id));
    }

    #[tokio::test]
    async fn engine_runs_custom_steps() {
        let engine = WorkoutEngine::new();
        let w = WorkoutFile {
            version: 1,
            id: "t".into(),
            name: "Test".into(),
            description: String::new(),
            builtin: false,
            steps: vec![
                WorkoutStep::erg(1, 200),
                WorkoutStep::ramp(1, 200, 250),
            ],
        };
        let applied = Arc::new(Mutex::new(Vec::<u32>::new()));
        let app2 = applied.clone();
        let eng = engine.clone();
        let handle = tokio::spawn(async move {
            eng.run(w, |cmd| {
                let app2 = app2.clone();
                async move {
                    if let WorkoutCommand::Erg(w) = cmd {
                        app2.lock().push(w);
                    }
                    Ok(())
                }
            })
            .await
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        while !engine.status().done && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let _ = handle.await;
        let watts = applied.lock().clone();
        assert!(watts.contains(&200), "applied={watts:?}");
        assert!(engine.status().done || !engine.status().running);
    }

    fn wf(steps: Vec<WorkoutStep>) -> WorkoutFile {
        WorkoutFile {
            version: 1,
            id: "t".into(),
            name: "Test".into(),
            description: String::new(),
            builtin: false,
            steps,
        }
    }

    /// Runs [w] on a paused clock, recording every command with its time
    /// (seconds since start). [fail_on] makes that command index return Err.
    async fn record(
        engine: &WorkoutEngine,
        w: WorkoutFile,
        cmd_delay: Duration,
        fail_on: Option<usize>,
    ) -> (Result<(), String>, Vec<(f64, WorkoutCommand)>) {
        let t0 = Instant::now();
        let log = Arc::new(Mutex::new(Vec::new()));
        let log2 = log.clone();
        let r = engine
            .run(w, move |cmd| {
                let log2 = log2.clone();
                async move {
                    let n = {
                        let mut l = log2.lock();
                        l.push((t0.elapsed().as_secs_f64(), cmd));
                        l.len() - 1
                    };
                    tokio::time::sleep(cmd_delay).await;
                    if Some(n) == fail_on {
                        Err("CP rejected".into())
                    } else {
                        Ok(())
                    }
                }
            })
            .await;
        let l = log.lock().clone();
        (r, l)
    }

    #[tokio::test(start_paused = true)]
    async fn engine_first_cmd_error_clears_running() {
        let e = WorkoutEngine::new();
        let (r, _) = record(&e, wf(vec![WorkoutStep::erg(5, 200)]), Duration::ZERO, Some(0)).await;
        assert!(r.is_err());
        let st = e.status();
        assert!(!st.running && !st.done);
        assert_eq!(st.error.as_deref(), Some("CP rejected"));
        assert!(st.status_text.contains("Stopped"), "{}", st.status_text);
        assert!(e.current_command().is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn engine_unknown_kind_clears_running() {
        let e = WorkoutEngine::new();
        let mut bad = WorkoutStep::erg(5, 100);
        bad.kind = "foo".into();
        let (r, _) = record(&e, wf(vec![WorkoutStep::erg(1, 100), bad]), Duration::ZERO, None).await;
        assert!(r.unwrap_err().contains("foo"));
        assert!(!e.status().running);
        assert!(e.status().error.is_some());
    }

    #[tokio::test(start_paused = true)]
    async fn engine_step_boundaries_follow_absolute_schedule() {
        let e = WorkoutEngine::new();
        let steps = (0..20).map(|i| WorkoutStep::erg(1, 100 + i)).collect();
        let t0 = Instant::now();
        let (r, log) = record(&e, wf(steps), Duration::from_millis(100), None).await;
        r.unwrap();
        let total = t0.elapsed().as_secs_f64();
        assert!(total <= 20.3, "drifted to {total:.2} s");
        // Step n starts at n seconds, regardless of the 100 ms command latency.
        for (n, (t, _)) in log.iter().enumerate() {
            assert!((t - n as f64).abs() < 0.01, "step {n} at {t:.3}");
        }
        assert!(e.status().done);
    }

    #[tokio::test(start_paused = true)]
    async fn ramp_interpolates_and_is_rate_limited() {
        let e = WorkoutEngine::new();
        let (r, log) = record(&e, wf(vec![WorkoutStep::ramp(10, 100, 200)]), Duration::ZERO, None).await;
        r.unwrap();
        let watts: Vec<u32> = log
            .iter()
            .map(|(_, c)| match c {
                WorkoutCommand::Erg(w) => *w,
                other => panic!("unexpected {other:?}"),
            })
            .collect();
        assert_eq!(watts[0], 100);
        assert!(watts.windows(2).all(|p| p[1] >= p[0]), "{watts:?}");
        assert!(*watts.last().unwrap() >= 185, "{watts:?}");
        // ≤ 1 command per second (+ the step start).
        assert!(watts.len() <= 11, "{} cmds: {watts:?}", watts.len());
        for p in log.windows(2) {
            assert!(p[1].0 - p[0].0 >= 0.99, "{log:?}");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn flat_ramp_sends_once() {
        let e = WorkoutEngine::new();
        let (_, log) = record(&e, wf(vec![WorkoutStep::ramp(10, 150, 151)]), Duration::ZERO, None).await;
        assert_eq!(log.len(), 1, "{log:?}");
    }

    #[tokio::test(start_paused = true)]
    async fn erg_step_sends_exactly_once_and_no_simgrade_at_end() {
        let e = WorkoutEngine::new();
        let (r, log) = record(&e, wf(vec![WorkoutStep::erg(5, 220)]), Duration::ZERO, None).await;
        r.unwrap();
        assert_eq!(log.iter().map(|(_, c)| c.clone()).collect::<Vec<_>>(), vec![WorkoutCommand::Erg(220)]);
    }

    #[tokio::test(start_paused = true)]
    async fn sim_workout_flattens_grade_at_end() {
        let e = WorkoutEngine::new();
        let (_, log) = record(&e, wf(vec![WorkoutStep::sim_grade(3, 4.0)]), Duration::ZERO, None).await;
        assert_eq!(log.last().unwrap().1, WorkoutCommand::SimGrade(0.0));
    }

    #[tokio::test(start_paused = true)]
    async fn restart_while_running_never_runs_two_loops() {
        let e = WorkoutEngine::new();
        let log = Arc::new(Mutex::new(Vec::<(char, u32)>::new()));
        let mk = |tag: char| {
            let log = log.clone();
            move |cmd: WorkoutCommand| {
                let log = log.clone();
                async move {
                    if let WorkoutCommand::Erg(w) = cmd {
                        log.lock().push((tag, w));
                    }
                    Ok::<(), String>(())
                }
            }
        };
        let ea = e.clone();
        let a = tokio::spawn({
            let f = mk('A');
            async move { ea.run(wf(vec![WorkoutStep::ramp(20, 100, 300)]), f).await }
        });
        tokio::time::sleep(Duration::from_millis(1500)).await;
        let eb = e.clone();
        let b = tokio::spawn({
            let f = mk('B');
            async move { eb.run(wf(vec![WorkoutStep::erg(3, 150)]), f).await }
        });
        tokio::time::sleep(Duration::from_millis(10)).await;
        let n_before = log.lock().len();
        let _ = b.await;
        let _ = a.await;
        let l = log.lock().clone();
        let first_b = l.iter().position(|(t, _)| *t == 'B').unwrap();
        assert!(first_b < n_before.max(first_b + 1));
        assert!(l[first_b..].iter().all(|(t, _)| *t == 'B'), "{l:?}");
        assert!(e.status().done, "B owns the final state");
    }

    #[tokio::test(start_paused = true)]
    async fn status_remaining_and_target_during_ramp() {
        let e = WorkoutEngine::new();
        let e2 = e.clone();
        let h = tokio::spawn(async move {
            e2.run(wf(vec![WorkoutStep::ramp(10, 100, 200)]), |_| async { Ok(()) })
                .await
        });
        tokio::time::sleep(Duration::from_millis(5000)).await;
        let st = e.status();
        assert!(st.running);
        assert!((st.target_watts.unwrap() as i64 - 150).abs() <= 2, "{st:?}");
        assert!((st.remaining_s - 5.0).abs() < 0.3, "{st:?}");
        h.await.unwrap().unwrap();
    }

    #[test]
    fn validate_rejects_bad_steps() {
        let ok = wf(vec![WorkoutStep::erg(60, 200)]);
        assert!(ok.validate().is_ok());
        let mut missing = WorkoutStep::erg(60, 200);
        missing.watts = None;
        assert!(wf(vec![missing]).validate().unwrap_err().contains("watts"));
        assert!(wf(vec![WorkoutStep::erg(60, 5000)]).validate().is_err());
        let mut res = WorkoutStep::erg(60, 0);
        res.kind = "resistance".into();
        res.resistance_pct = Some(150.0);
        assert!(wf(vec![res]).validate().is_err());
        assert!(wf(vec![WorkoutStep::sim_grade(60, 90.0)]).validate().is_err());
        assert!(wf(vec![WorkoutStep::sim_grade(60, f64::NAN)]).validate().is_err());
        let mut dist = WorkoutStep::erg(0, 200);
        dist.duration_s = None;
        dist.distance_m = Some(1000.0);
        assert!(wf(vec![dist]).validate().unwrap_err().contains("distance"));
        assert!(wf(vec![WorkoutStep::erg(0, 200)]).validate().is_err());
        assert!(wf(vec![]).validate().is_err());
        let mut unknown = WorkoutStep::erg(60, 200);
        unknown.kind = "warp".into();
        assert!(wf(vec![unknown]).validate().is_err());
    }

    #[test]
    fn builtins_all_validate() {
        for b in builtins() {
            b.validate().unwrap_or_else(|e| panic!("{}: {e}", b.id));
            assert!(b.steps.iter().map(|s| s.duration_or_zero()).sum::<u32>() > 0);
        }
    }

    /// Shared with the Dart side (test/fixtures/workout_plan_fixture.json):
    /// both languages must derive the same targets from the same JSON.
    #[test]
    fn shared_fixture_matches_engine_targets() {
        let raw = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../test/fixtures/workout_plan_fixture.json"),
        )
        .unwrap();
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let w: WorkoutFile = serde_json::from_value(v["workout"].clone()).unwrap();
        w.validate().unwrap();
        let exp = &v["expected"];
        let total: u32 = w.steps.iter().map(|s| s.duration_or_zero()).sum();
        assert_eq!(total as u64, exp["totalS"].as_u64().unwrap());
        for (i, s) in w.steps.iter().enumerate() {
            let start = match step_command(s).unwrap() {
                WorkoutCommand::Erg(w) => Some(w as u64),
                _ => None,
            };
            assert_eq!(start, exp["stepStartWatts"][i].as_u64(), "step {i}");
        }
        assert_eq!(
            step_command(&w.steps[2]).unwrap(),
            WorkoutCommand::Resistance(exp["resistancePct"].as_f64().unwrap())
        );
        assert_eq!(
            step_command(&w.steps[3]).unwrap(),
            WorkoutCommand::SimGrade(exp["gradePct"].as_f64().unwrap())
        );
        let mid = (w.steps[1].watts_start.unwrap() + w.steps[1].watts_end.unwrap()) / 2;
        assert_eq!(mid as u64, exp["rampMidWatts"].as_u64().unwrap());
    }
}


//! Structured workouts: JSON library under Documents/Tacx Desktop/workouts/,
//! multi-step ERG/ramp/resistance/simGrade engine, built-in pack.

use crate::trainer::ride::default_export_dir;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

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
    if w.steps.is_empty() {
        return Err("Workout has no steps".into());
    }
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

/// What the engine wants applied right now.
#[derive(Clone, Debug)]
pub enum WorkoutCommand {
    Erg(u32),
    Resistance(f64),
    SimGrade(f64),
}

struct EngineInner {
    running: bool,
    done: bool,
    cancel: bool,
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

impl WorkoutEngine {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(EngineInner {
                running: false,
                done: false,
                cancel: false,
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
                status_text: "Idle".into(),
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
                    "ramp" => {
                        let t = g.step_started.elapsed().as_secs_f64()
                            / g.step_duration.as_secs_f64().max(0.001);
                        let t = t.clamp(0.0, 1.0);
                        let w_now = g.ramp_start_w as f64
                            + (g.ramp_end_w as f64 - g.ramp_start_w as f64) * t;
                        (Some(w_now.round() as u32), None, "RAMP")
                    }
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
        }
    }

    pub fn current_command(&self) -> Option<WorkoutCommand> {
        let g = self.inner.lock();
        if !g.running {
            return None;
        }
        let step = g.workout.as_ref()?.steps.get(g.step_index)?;
        match step.kind.as_str() {
            "erg" => Some(WorkoutCommand::Erg(step.watts.unwrap_or(0))),
            "ramp" => {
                let t = g.step_started.elapsed().as_secs_f64()
                    / g.step_duration.as_secs_f64().max(0.001);
                let t = t.clamp(0.0, 1.0);
                let w = g.ramp_start_w as f64
                    + (g.ramp_end_w as f64 - g.ramp_start_w as f64) * t;
                Some(WorkoutCommand::Erg(w.round() as u32))
            }
            "resistance" => Some(WorkoutCommand::Resistance(
                step.resistance_pct.unwrap_or(20.0),
            )),
            "simGrade" => Some(WorkoutCommand::SimGrade(step.grade_pct.unwrap_or(0.0))),
            _ => None,
        }
    }

    pub fn stop(&self) {
        let mut g = self.inner.lock();
        g.cancel = true;
        g.running = false;
        g.done = false;
        g.workout = None;
        g.step_index = 0;
    }

    pub async fn run<F, Fut>(&self, workout: WorkoutFile, mut on_cmd: F) -> Result<(), String>
    where
        F: FnMut(WorkoutCommand) -> Fut,
        Fut: std::future::Future<Output = Result<(), String>>,
    {
        if workout.steps.is_empty() {
            return Err("Workout has no steps".into());
        }
        {
            let mut g = self.inner.lock();
            g.cancel = true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;

        {
            let mut g = self.inner.lock();
            g.cancel = false;
            g.done = false;
            g.running = true;
            g.workout = Some(workout.clone());
            g.step_index = 0;
        }

        for (idx, step) in workout.steps.iter().enumerate() {
            {
                let mut g = self.inner.lock();
                if g.cancel {
                    g.running = false;
                    return Ok(());
                }
                g.step_index = idx;
                let dur = Duration::from_secs(step.duration_or_zero().max(1) as u64);
                g.step_duration = dur;
                g.step_started = Instant::now();
                if step.kind == "ramp" {
                    g.ramp_start_w = step.watts_start.unwrap_or(100);
                    g.ramp_end_w = step.watts_end.unwrap_or(150);
                }
            }

            let cmd = match step.kind.as_str() {
                "erg" => WorkoutCommand::Erg(step.watts.unwrap_or(0)),
                "ramp" => WorkoutCommand::Erg(step.watts_start.unwrap_or(100)),
                "resistance" => {
                    WorkoutCommand::Resistance(step.resistance_pct.unwrap_or(20.0))
                }
                "simGrade" => WorkoutCommand::SimGrade(step.grade_pct.unwrap_or(0.0)),
                other => return Err(format!("Unknown step kind: {other}")),
            };
            on_cmd(cmd).await?;

            // Tick until step duration elapsed (ramp re-applies watts ~1 Hz).
            loop {
                tokio::time::sleep(Duration::from_millis(250)).await;
                let (cancel, elapsed_done, is_ramp) = {
                    let g = self.inner.lock();
                    (
                        g.cancel,
                        g.step_started.elapsed() >= g.step_duration,
                        step.kind == "ramp",
                    )
                };
                if cancel {
                    let mut g = self.inner.lock();
                    g.running = false;
                    return Ok(());
                }
                if is_ramp {
                    if let Some(WorkoutCommand::Erg(w)) = self.current_command() {
                        let _ = on_cmd(WorkoutCommand::Erg(w)).await;
                    }
                }
                if elapsed_done {
                    break;
                }
            }
        }

        {
            let mut g = self.inner.lock();
            g.running = false;
            g.done = true;
        }
        // Flatten grade at end of sim workouts.
        let _ = on_cmd(WorkoutCommand::SimGrade(0.0)).await;
        Ok(())
    }
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
}

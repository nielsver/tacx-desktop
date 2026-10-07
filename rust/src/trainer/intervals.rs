//! Interval presets — same product set as the former Python scaffold.

use crate::trainer::types::{IntervalPresetInfo, IntervalStatus};
use parking_lot::Mutex;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub fn presets() -> Vec<IntervalPresetInfo> {
    vec![
        IntervalPresetInfo {
            key: "10x30_30".into(),
            label: "10×30/30s".into(),
            description: "Classic VO2 bursts — 10×30s work / 30s recovery".into(),
            repeats: 10,
            work_s: 30,
            rest_s: 30,
            work_watts: 280,
            rest_watts: 120,
        },
        IntervalPresetInfo {
            key: "5x3_2".into(),
            label: "5×3/2min".into(),
            description: "Sweet-spot / threshold blocks — 5×3min / 2min".into(),
            repeats: 5,
            work_s: 180,
            rest_s: 120,
            work_watts: 250,
            rest_watts: 140,
        },
        IntervalPresetInfo {
            key: "4x4_3".into(),
            label: "4×4/3min".into(),
            description: "Norwegian 4×4 — 4×4min / 3min".into(),
            repeats: 4,
            work_s: 240,
            rest_s: 180,
            work_watts: 270,
            rest_watts: 130,
        },
    ]
}

pub fn preset_by_key(key: &str) -> Option<IntervalPresetInfo> {
    presets().into_iter().find(|p| p.key == key)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Idle,
    Work,
    Rest,
    Done,
}

struct Inner {
    running: bool,
    phase: Phase,
    preset: Option<IntervalPresetInfo>,
    repeat_index: u32,
    phase_started: Instant,
    phase_duration: Duration,
    cancel: bool,
}

#[derive(Clone)]
pub struct IntervalEngine {
    inner: Arc<Mutex<Inner>>,
}

impl Default for IntervalEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl IntervalEngine {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                running: false,
                phase: Phase::Idle,
                preset: None,
                repeat_index: 0,
                phase_started: Instant::now(),
                phase_duration: Duration::ZERO,
                cancel: false,
            })),
        }
    }

    pub fn status(&self) -> IntervalStatus {
        let g = self.inner.lock();
        let remaining = if g.running {
            g.phase_duration
                .saturating_sub(g.phase_started.elapsed())
                .as_secs_f64()
        } else {
            0.0
        };
        let phase = match g.phase {
            Phase::Idle => "Idle",
            Phase::Work => "WORK",
            Phase::Rest => "REST",
            Phase::Done => "Done",
        };
        let status_text = match (&g.preset, g.phase) {
            (_, Phase::Idle) => "Idle".into(),
            (_, Phase::Done) => "Done".into(),
            (Some(p), _) => {
                let rem = remaining.round().max(0.0) as u64;
                let mm = rem / 60;
                let ss = rem % 60;
                format!(
                    "{} · {} {}/{} · {:02}:{:02}",
                    p.label,
                    phase,
                    g.repeat_index + 1,
                    p.repeats,
                    mm,
                    ss
                )
            }
            _ => "—".into(),
        };
        IntervalStatus {
            running: g.running,
            phase: phase.into(),
            status_text,
            repeat_index: g.repeat_index,
            remaining_s: remaining,
        }
    }

    pub fn stop(&self) {
        let mut g = self.inner.lock();
        g.cancel = true;
        g.running = false;
        g.phase = Phase::Idle;
    }

    /// Returns current target watts when phase changes / on tick; caller applies ERG.
    pub async fn run<F, Fut>(&self, key: &str, mut on_target: F) -> Result<(), String>
    where
        F: FnMut(u32) -> Fut,
        Fut: std::future::Future<Output = Result<(), String>>,
    {
        let preset = preset_by_key(key).ok_or_else(|| format!("Unknown preset: {key}"))?;
        {
            let mut g = self.inner.lock();
            g.cancel = true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;

        {
            let mut g = self.inner.lock();
            g.cancel = false;
            g.running = true;
            g.preset = Some(preset.clone());
            g.repeat_index = 0;
            g.phase = Phase::Work;
            g.phase_duration = Duration::from_secs(preset.work_s as u64);
            g.phase_started = Instant::now();
        }
        on_target(preset.work_watts).await?;

        loop {
            tokio::time::sleep(Duration::from_millis(200)).await;
            let (done_phase, cancel, elapsed_done, is_work, repeats, rest_s, work_s, rest_w, work_w, idx) = {
                let g = self.inner.lock();
                let elapsed_done = g.phase_started.elapsed() >= g.phase_duration;
                (
                    g.phase == Phase::Done,
                    g.cancel,
                    elapsed_done,
                    g.phase == Phase::Work,
                    g.preset.as_ref().map(|p| p.repeats).unwrap_or(0),
                    g.preset.as_ref().map(|p| p.rest_s).unwrap_or(0),
                    g.preset.as_ref().map(|p| p.work_s).unwrap_or(0),
                    g.preset.as_ref().map(|p| p.rest_watts).unwrap_or(0),
                    g.preset.as_ref().map(|p| p.work_watts).unwrap_or(0),
                    g.repeat_index,
                )
            };
            if cancel || done_phase {
                let mut g = self.inner.lock();
                g.running = false;
                if g.phase != Phase::Done {
                    g.phase = Phase::Idle;
                }
                break;
            }
            if !elapsed_done {
                continue;
            }
            if is_work {
                {
                    let mut g = self.inner.lock();
                    g.phase = Phase::Rest;
                    g.phase_duration = Duration::from_secs(rest_s as u64);
                    g.phase_started = Instant::now();
                }
                on_target(rest_w).await?;
            } else {
                let next = idx + 1;
                if next >= repeats {
                    let mut g = self.inner.lock();
                    g.phase = Phase::Done;
                    g.running = false;
                    break;
                }
                {
                    let mut g = self.inner.lock();
                    g.repeat_index = next;
                    g.phase = Phase::Work;
                    g.phase_duration = Duration::from_secs(work_s as u64);
                    g.phase_started = Instant::now();
                }
                on_target(work_w).await?;
            }
        }
        Ok(())
    }
}

//! Automatic disconnect recovery policy (P0-UX-4 / P1-BLE-4).
//!
//! Pure, hardware-free pieces of auto-reconnect: the bounded backoff schedule,
//! which failures are worth retrying, the cancellation token, which control
//! target to restore, and how progress is surfaced in `ConnectionSnapshot`.
//! `controller.rs` drives the actual BLE I/O.

use crate::trainer::types::{ConnectionState, ControlMode};
use std::time::{Duration, Instant};

/// Delay before each automatic attempt: ~1 s, 3 s, 8 s, 15 s, then give up.
pub const DEFAULT_BACKOFF_S: [u64; 4] = [1, 3, 8, 15];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackoffPolicy {
    delays: Vec<Duration>,
}

impl Default for BackoffPolicy {
    fn default() -> Self {
        Self::from_secs(&DEFAULT_BACKOFF_S)
    }
}

impl BackoffPolicy {
    pub fn from_secs(secs: &[u64]) -> Self {
        Self {
            delays: secs.iter().map(|s| Duration::from_secs(*s)).collect(),
        }
    }

    pub fn max_attempts(&self) -> u32 {
        self.delays.len() as u32
    }

    /// Delay before 1-based `attempt`, or `None` once the schedule is exhausted.
    pub fn delay_before(&self, attempt: u32) -> Option<Duration> {
        if attempt == 0 {
            return None;
        }
        self.delays.get(attempt as usize - 1).copied()
    }

    /// What to do after `attempt` (1-based) failed with `kind`.
    pub fn after_failure(&self, attempt: u32, kind: FailureKind) -> NextStep {
        if kind == FailureKind::ExclusiveControl {
            return NextStep::Blocked;
        }
        match self.delay_before(attempt + 1) {
            Some(delay) => NextStep::Retry {
                attempt: attempt + 1,
                delay,
            },
            None => NextStep::GiveUp,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NextStep {
    Retry { attempt: u32, delay: Duration },
    /// Schedule exhausted — leave the manual Reconnect button.
    GiveUp,
    /// Another app holds the trainer (NOCTRL) — retrying would fight it.
    Blocked,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailureKind {
    /// Out of range, asleep, adapter hiccup — worth another try.
    Transient,
    /// FTMS Request Control rejected / Control Not Permitted.
    ExclusiveControl,
}

/// Classify a raw `connect_ble` error.
pub fn classify_failure(err: &str) -> FailureKind {
    let lower = err.to_lowercase();
    if lower.contains("request control rejected")
        || lower.contains("control not permitted")
        || lower.contains("exclusive control (noctrl)")
    {
        FailureKind::ExclusiveControl
    } else {
        FailureKind::Transient
    }
}

/// A link that drops again within this window after an automatic reconnect
/// continues the same backoff cycle instead of restarting at attempt 1, so a
/// flapping trainer can never loop forever.
pub const STABLE_LINK: Duration = Duration::from_secs(20);

/// First attempt number for a new loss, given the previous auto-reconnect
/// success (time since it, and which attempt succeeded).
pub fn starting_attempt(last_success: Option<(Duration, u32)>) -> u32 {
    match last_success {
        Some((since, attempt)) if since < STABLE_LINK => attempt + 1,
        _ => 1,
    }
}

/// Why auto-reconnect starts (or not) when a link-lost signal arrives.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LossDecision {
    Retry,
    /// Stale signal: user disconnected, switched to demo, or connected again.
    Ignore,
    /// Link dropped after FTMS reported Control Permission Lost.
    Blocked,
}

pub fn on_link_lost(
    token_current: bool,
    demo_mode: bool,
    link_alive: bool,
    control_lost: bool,
    has_device: bool,
) -> LossDecision {
    if !token_current || demo_mode || link_alive || !has_device {
        return LossDecision::Ignore;
    }
    if control_lost {
        return LossDecision::Blocked;
    }
    LossDecision::Retry
}

/// Generation counter: every user Disconnect / demo switch / manual connect
/// calls [`ReconnectGate::cancel`], which invalidates outstanding tokens held
/// by link watchers and retry loops.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReconnectGate {
    epoch: u64,
}

impl ReconnectGate {
    pub fn token(&self) -> u64 {
        self.epoch
    }

    pub fn cancel(&mut self) -> u64 {
        self.epoch = self.epoch.wrapping_add(1);
        self.epoch
    }

    pub fn is_current(&self, token: u64) -> bool {
        self.epoch == token
    }
}

/// Last simulation parameters sent (FTMS 0x11 / FE-C track+wind).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SimParams {
    pub wind_speed_mps: f64,
    pub grade_pct: f64,
    pub crr: f64,
    pub cw: f64,
}

/// Control target to re-apply after a successful reconnect.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ResumeTarget {
    Erg(u32),
    Resistance(f64),
    Simulation(SimParams),
}

/// Running interval preset wins (its *current* phase watts), else the last
/// mode the rider used.
pub fn pick_resume_target(
    interval_watts: Option<u32>,
    mode: ControlMode,
    target_power_w: Option<f64>,
    resistance_pct: Option<f64>,
    last_sim: Option<SimParams>,
) -> Option<ResumeTarget> {
    if let Some(w) = interval_watts {
        return Some(ResumeTarget::Erg(w));
    }
    match mode {
        ControlMode::Erg => target_power_w.map(|w| ResumeTarget::Erg(w.round() as u32)),
        ControlMode::Resistance => resistance_pct.map(ResumeTarget::Resistance),
        ControlMode::Simulation => last_sim.map(ResumeTarget::Simulation),
        ControlMode::Idle => target_power_w.map(|w| ResumeTarget::Erg(w.round() as u32)),
    }
}

/// Auto-reconnect progress kept by the controller.
#[derive(Clone, Debug, PartialEq)]
#[derive(Default)]
pub enum AutoReconnect {
    #[default]
    Inactive,
    Waiting {
        attempt: u32,
        max: u32,
        next_at: Instant,
    },
    Attempting {
        attempt: u32,
        max: u32,
    },
    GaveUp {
        attempts: u32,
        last_error: String,
    },
    Blocked {
        message: String,
    },
}


/// Snapshot fields derived from [`AutoReconnect`] (only used while the link is down).
#[derive(Clone, Debug, PartialEq)]
pub struct ReconnectView {
    pub state: ConnectionState,
    pub detail: String,
    pub attempt: u32,
    pub max_attempts: u32,
    pub in_s: u32,
    pub gave_up: bool,
}

impl AutoReconnect {
    pub fn view(&self, now: Instant) -> Option<ReconnectView> {
        match self {
            AutoReconnect::Inactive => None,
            AutoReconnect::Waiting {
                attempt,
                max,
                next_at,
            } => {
                let rem = next_at.saturating_duration_since(now);
                let in_s = rem.as_millis().div_ceil(1000) as u32;
                Some(ReconnectView {
                    state: ConnectionState::Reconnecting,
                    detail: format!(
                        "Connection lost — reconnecting ({attempt}/{max}) in {in_s} s…"
                    ),
                    attempt: *attempt,
                    max_attempts: *max,
                    in_s,
                    gave_up: false,
                })
            }
            AutoReconnect::Attempting { attempt, max } => Some(ReconnectView {
                state: ConnectionState::Reconnecting,
                detail: format!("Connection lost — reconnecting ({attempt}/{max})…"),
                attempt: *attempt,
                max_attempts: *max,
                in_s: 0,
                gave_up: false,
            }),
            AutoReconnect::GaveUp {
                attempts,
                last_error,
            } => Some(ReconnectView {
                state: ConnectionState::Error,
                detail: format!(
                    "Link lost — auto-reconnect gave up after {attempts} attempts. Wake the trainer (pedal), then tap Reconnect. ({last_error})"
                ),
                attempt: *attempts,
                max_attempts: *attempts,
                in_s: 0,
                gave_up: true,
            }),
            AutoReconnect::Blocked { message } => Some(ReconnectView {
                state: ConnectionState::Error,
                detail: format!("Control lost — {message}"),
                attempt: 0,
                max_attempts: 0,
                in_s: 0,
                gave_up: false,
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_schedule_is_1_3_8_15() {
        let p = BackoffPolicy::default();
        assert_eq!(p.max_attempts(), 4);
        let got: Vec<u64> = (1..=4)
            .map(|a| p.delay_before(a).unwrap().as_secs())
            .collect();
        assert_eq!(got, vec![1, 3, 8, 15]);
        assert_eq!(p.delay_before(0), None);
        assert_eq!(p.delay_before(5), None);
    }

    #[test]
    fn retries_until_exhausted_then_gives_up() {
        let p = BackoffPolicy::default();
        let mut attempt = 1;
        let mut total = p.delay_before(1).unwrap();
        loop {
            match p.after_failure(attempt, FailureKind::Transient) {
                NextStep::Retry { attempt: n, delay } => {
                    assert_eq!(n, attempt + 1);
                    total += delay;
                    attempt = n;
                }
                NextStep::GiveUp => break,
                NextStep::Blocked => panic!("transient must not block"),
            }
        }
        assert_eq!(attempt, 4);
        // Bounded: whole schedule fits in ~27 s of waiting.
        assert_eq!(total, Duration::from_secs(27));
    }

    #[test]
    fn exclusive_control_never_retries() {
        let p = BackoffPolicy::default();
        assert_eq!(p.after_failure(1, FailureKind::ExclusiveControl), NextStep::Blocked);
        assert_eq!(p.after_failure(4, FailureKind::ExclusiveControl), NextStep::Blocked);
    }

    #[test]
    fn empty_policy_gives_up_immediately() {
        let p = BackoffPolicy::from_secs(&[]);
        assert_eq!(p.max_attempts(), 0);
        assert_eq!(p.delay_before(1), None);
    }

    #[test]
    fn flapping_link_continues_the_cycle() {
        let p = BackoffPolicy::default();
        assert_eq!(starting_attempt(None), 1);
        assert_eq!(starting_attempt(Some((Duration::from_secs(60), 2))), 1);
        assert_eq!(starting_attempt(Some((Duration::from_secs(2), 2))), 3);
        // Succeeded on the last attempt and dropped again at once → no budget left.
        assert_eq!(p.delay_before(starting_attempt(Some((Duration::from_secs(1), 4)))), None);
    }

    #[test]
    fn classifies_noctrl_vs_transient() {
        for e in [
            "Could not take exclusive control (NOCTRL). Disconnect other FTMS clients and retry. (Request Control rejected: Request Control → control not permitted (NOCTRL) — another app holds the trainer.)",
            "Request Control → control not permitted (NOCTRL)",
        ] {
            assert_eq!(classify_failure(e), FailureKind::ExclusiveControl, "{e}");
        }
        for e in [
            "Device AA:BB not found — scan again while the trainer is awake",
            "Connect failed (busy trainer?): timed out",
            "Request Control failed (NOCTRL?): link dropped",
            "Service discovery failed: disconnected",
        ] {
            assert_eq!(classify_failure(e), FailureKind::Transient, "{e}");
        }
    }

    #[test]
    fn loss_decision() {
        assert_eq!(on_link_lost(true, false, false, false, true), LossDecision::Retry);
        // User disconnect / demo switch / manual connect → stale token.
        assert_eq!(on_link_lost(false, false, false, false, true), LossDecision::Ignore);
        assert_eq!(on_link_lost(true, true, false, false, true), LossDecision::Ignore);
        assert_eq!(on_link_lost(true, false, true, false, true), LossDecision::Ignore);
        assert_eq!(on_link_lost(true, false, false, false, false), LossDecision::Ignore);
        assert_eq!(on_link_lost(true, false, false, true, true), LossDecision::Blocked);
    }

    #[test]
    fn gate_cancel_invalidates_outstanding_tokens() {
        let mut g = ReconnectGate::default();
        let t0 = g.token();
        assert!(g.is_current(t0));
        let t1 = g.cancel();
        assert!(!g.is_current(t0));
        assert!(g.is_current(t1));
        assert_eq!(g.token(), t1);
        g.cancel();
        assert!(!g.is_current(t1));
    }

    #[test]
    fn resume_target_prefers_interval_then_mode() {
        let sim = SimParams {
            wind_speed_mps: 1.0,
            grade_pct: 4.5,
            crr: 0.004,
            cw: 0.51,
        };
        assert_eq!(
            pick_resume_target(Some(280), ControlMode::Resistance, None, Some(30.0), None),
            Some(ResumeTarget::Erg(280))
        );
        assert_eq!(
            pick_resume_target(None, ControlMode::Erg, Some(212.0), None, None),
            Some(ResumeTarget::Erg(212))
        );
        assert_eq!(
            pick_resume_target(None, ControlMode::Resistance, None, Some(35.0), None),
            Some(ResumeTarget::Resistance(35.0))
        );
        assert_eq!(
            pick_resume_target(None, ControlMode::Simulation, None, None, Some(sim)),
            Some(ResumeTarget::Simulation(sim))
        );
        assert_eq!(pick_resume_target(None, ControlMode::Idle, None, None, Some(sim)), None);
        assert_eq!(pick_resume_target(None, ControlMode::Simulation, None, None, None), None);
    }

    #[test]
    fn view_texts_and_countdown() {
        let now = Instant::now();
        let w = AutoReconnect::Waiting {
            attempt: 2,
            max: 4,
            next_at: now + Duration::from_millis(2_100),
        }
        .view(now)
        .unwrap();
        assert_eq!(w.state, ConnectionState::Reconnecting);
        assert_eq!((w.attempt, w.max_attempts, w.in_s), (2, 4, 3));
        assert_eq!(w.detail, "Connection lost — reconnecting (2/4) in 3 s…");
        assert!(!w.gave_up);

        let a = AutoReconnect::Attempting { attempt: 3, max: 4 }.view(now).unwrap();
        assert_eq!(a.detail, "Connection lost — reconnecting (3/4)…");
        assert_eq!(a.in_s, 0);

        let g = AutoReconnect::GaveUp {
            attempts: 4,
            last_error: "not found".into(),
        }
        .view(now)
        .unwrap();
        assert_eq!(g.state, ConnectionState::Error);
        assert!(g.gave_up);
        assert!(g.detail.starts_with("Link lost"));
        assert!(g.detail.contains("Reconnect"));

        let b = AutoReconnect::Blocked {
            message: "NOCTRL".into(),
        }
        .view(now)
        .unwrap();
        assert_eq!(b.state, ConnectionState::Error);
        assert!(b.detail.starts_with("Control lost"));
        assert!(AutoReconnect::Inactive.view(now).is_none());
    }
}

//! Trainer link health: packets per second and age of the last packet.
//!
//! Every trainer data notification (FTMS Indoor Bike Data, FE-C UART TX,
//! or a Demo tick) calls [`trainer_packet`]. The status bar then shows
//! whether data is flowing, so a rider can tell a trainer / BLE stall
//! (age climbing, rate falling) from an app stall (the whole UI freezes).
//!
//! The meter is pure over an injected clock (`Instant`), so thresholds are
//! unit-tested with a fake clock.

use crate::trainer::types::{LinkHealth, LinkLevel};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// Last packet younger than this is healthy (green).
pub const GOOD_MAX: Duration = Duration::from_millis(1500);
/// Older than [`GOOD_MAX`] but younger than this is stale (amber); beyond, lost (red).
pub const STALE_MAX: Duration = Duration::from_millis(4000);
/// Window for the packets-per-second rate.
pub const RATE_WINDOW: Duration = Duration::from_secs(5);
/// Bound on remembered packet times (FTMS tops out around 4–10 Hz).
const MAX_TIMES: usize = 256;

#[derive(Debug, Default)]
pub struct LinkMeter {
    times: VecDeque<Instant>,
    first: Option<Instant>,
    last: Option<Instant>,
}

impl LinkMeter {
    pub fn on_packet(&mut self, now: Instant) {
        self.first.get_or_insert(now);
        self.last = Some(now);
        self.times.push_back(now);
        self.prune(now);
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    fn prune(&mut self, now: Instant) {
        while self
            .times
            .front()
            .is_some_and(|t| now.saturating_duration_since(*t) > RATE_WINDOW)
            || self.times.len() > MAX_TIMES
        {
            self.times.pop_front();
        }
    }

    /// Level for a last-packet age (`None` = nothing received yet).
    pub fn level_for(age: Option<Duration>) -> LinkLevel {
        match age {
            None => LinkLevel::NoData,
            Some(a) if a < GOOD_MAX => LinkLevel::Good,
            Some(a) if a < STALE_MAX => LinkLevel::Stale,
            Some(_) => LinkLevel::Lost,
        }
    }

    pub fn health(&self, now: Instant) -> LinkHealth {
        let age = self.last.map(|l| now.saturating_duration_since(l));
        let in_window = self
            .times
            .iter()
            .filter(|t| now.saturating_duration_since(**t) <= RATE_WINDOW)
            .count();
        // Divide by the observed span until a full window has elapsed, so
        // the first seconds after connect don't under-report.
        let span = self
            .first
            .map(|f| now.saturating_duration_since(f).min(RATE_WINDOW))
            .unwrap_or_default()
            .as_secs_f64()
            .max(1.0);
        LinkHealth {
            packets_per_s: in_window as f64 / span,
            last_packet_age_ms: age.map(|a| a.as_millis().min(u32::MAX as u128) as u32),
            level: Self::level_for(age),
        }
    }
}

static TRAINER_LINK: Lazy<Mutex<LinkMeter>> = Lazy::new(|| Mutex::new(LinkMeter::default()));

/// A trainer data packet arrived (call from the notification pumps / demo tick).
pub fn trainer_packet() {
    TRAINER_LINK.lock().on_packet(Instant::now());
}

/// Forget the previous link (new connect, disconnect).
pub fn reset_trainer_link() {
    TRAINER_LINK.lock().reset();
}

pub fn trainer_link_health() -> LinkHealth {
    TRAINER_LINK.lock().health(Instant::now())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn thresholds_with_fake_clock() {
        let t0 = Instant::now();
        let mut m = LinkMeter::default();
        assert_eq!(m.health(t0).level, LinkLevel::NoData);
        assert_eq!(m.health(t0).last_packet_age_ms, None);
        m.on_packet(t0);
        assert_eq!(m.health(t0).level, LinkLevel::Good);
        assert_eq!(m.health(t0 + ms(1499)).level, LinkLevel::Good);
        assert_eq!(m.health(t0 + ms(1500)).level, LinkLevel::Stale);
        assert_eq!(m.health(t0 + ms(3999)).level, LinkLevel::Stale);
        assert_eq!(m.health(t0 + ms(4000)).level, LinkLevel::Lost);
        assert_eq!(m.health(t0 + ms(2500)).last_packet_age_ms, Some(2500));
        // A fresh packet recovers immediately.
        m.on_packet(t0 + ms(6000));
        assert_eq!(m.health(t0 + ms(6100)).level, LinkLevel::Good);
    }

    #[test]
    fn rate_over_window() {
        let t0 = Instant::now();
        let mut m = LinkMeter::default();
        // 4 Hz for 10 s.
        for i in 0..40 {
            m.on_packet(t0 + ms(i * 250));
        }
        let h = m.health(t0 + ms(9750));
        assert!((h.packets_per_s - 4.0).abs() < 0.25, "{}", h.packets_per_s);
        // Trainer stalls: the rate decays to 0 as the window empties.
        let h = m.health(t0 + ms(12_000));
        assert!(h.packets_per_s < 3.0);
        assert_eq!(h.level, LinkLevel::Stale); // 2.25 s since the last packet
        assert_eq!(m.health(t0 + ms(14_000)).level, LinkLevel::Lost);
        assert_eq!(m.health(t0 + ms(20_000)).packets_per_s, 0.0);
    }

    #[test]
    fn early_rate_is_not_under_reported() {
        let t0 = Instant::now();
        let mut m = LinkMeter::default();
        for i in 0..9 {
            m.on_packet(t0 + ms(i * 250));
        }
        // 2 s in at 4 Hz: 9 packets / 2 s ≈ 4.5, not 9 / 5 = 1.8.
        let h = m.health(t0 + ms(2000));
        assert!(h.packets_per_s > 4.0, "{}", h.packets_per_s);
    }

    #[test]
    fn reset_and_bounded_memory() {
        let t0 = Instant::now();
        let mut m = LinkMeter::default();
        for i in 0..2000 {
            m.on_packet(t0 + Duration::from_micros(i * 100));
        }
        assert!(m.times.len() <= MAX_TIMES);
        m.reset();
        assert_eq!(m.health(t0).level, LinkLevel::NoData);
        assert_eq!(m.health(t0).packets_per_s, 0.0);
    }

    #[test]
    fn clock_going_backwards_is_safe() {
        let t0 = Instant::now() + ms(10_000);
        let mut m = LinkMeter::default();
        m.on_packet(t0);
        let h = m.health(t0 - ms(500));
        assert_eq!(h.last_packet_age_ms, Some(0));
        assert_eq!(h.level, LinkLevel::Good);
    }
}

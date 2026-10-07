//! FE-C-over-BLE write rate limiter (~4 Hz) with latest-wins coalescing.
//!
//! Spec / Tacx UART guidance: avoid flooding WithoutResponse writes. Interval
//! ERG steps and rapid UI nudges coalesce to the newest payload.

use std::time::{Duration, Instant};

/// Minimum gap between FE-C UART writes (4 Hz ⇒ 250 ms).
pub const FEC_MIN_WRITE_INTERVAL: Duration = Duration::from_millis(250);

/// Decision after offering a payload to the limiter.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RateDecision {
    /// Send `payload` immediately.
    SendNow(Vec<u8>),
    /// Too soon; `payload` replaced any pending frame. Wait `wait` then flush.
    Coalesced { wait: Duration },
}

/// Latest-wins throttle for FE-C WithoutResponse writes.
#[derive(Debug, Default)]
pub struct FecWriteRateLimiter {
    last_sent: Option<Instant>,
    pending: Option<Vec<u8>>,
}

impl FecWriteRateLimiter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Offer a frame. Returns SendNow or Coalesced (caller should schedule flush).
    pub fn offer(&mut self, payload: Vec<u8>, now: Instant) -> RateDecision {
        match self.last_sent {
            None => {
                self.last_sent = Some(now);
                self.pending = None;
                RateDecision::SendNow(payload)
            }
            Some(last) => {
                let elapsed = now.saturating_duration_since(last);
                if elapsed >= FEC_MIN_WRITE_INTERVAL {
                    self.last_sent = Some(now);
                    self.pending = None;
                    RateDecision::SendNow(payload)
                } else {
                    self.pending = Some(payload);
                    RateDecision::Coalesced {
                        wait: FEC_MIN_WRITE_INTERVAL - elapsed,
                    }
                }
            }
        }
    }

    /// Take pending frame if the min interval has elapsed (or force).
    pub fn take_pending_if_ready(&mut self, now: Instant) -> Option<Vec<u8>> {
        let pending = self.pending.as_ref()?;
        let _ = pending;
        match self.last_sent {
            None => {
                let p = self.pending.take()?;
                self.last_sent = Some(now);
                Some(p)
            }
            Some(last) => {
                if now.saturating_duration_since(last) >= FEC_MIN_WRITE_INTERVAL {
                    let p = self.pending.take()?;
                    self.last_sent = Some(now);
                    Some(p)
                } else {
                    None
                }
            }
        }
    }

    /// Time until a pending flush may be sent, if any.
    pub fn pending_wait(&self, now: Instant) -> Option<Duration> {
        let _ = self.pending.as_ref()?;
        let last = self.last_sent?;
        let elapsed = now.saturating_duration_since(last);
        if elapsed >= FEC_MIN_WRITE_INTERVAL {
            Some(Duration::ZERO)
        } else {
            Some(FEC_MIN_WRITE_INTERVAL - elapsed)
        }
    }

    pub fn has_pending(&self) -> bool {
        self.pending.is_some()
    }

}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(tag: u8) -> Vec<u8> {
        vec![0xA4, tag]
    }

    #[test]
    fn first_write_sends_immediately() {
        let mut lim = FecWriteRateLimiter::new();
        let now = Instant::now();
        match lim.offer(frame(1), now) {
            RateDecision::SendNow(p) => assert_eq!(p, frame(1)),
            other => panic!("expected SendNow, got {other:?}"),
        }
        assert!(!lim.has_pending());
    }

    #[test]
    fn rapid_offers_coalesce_latest_wins() {
        let mut lim = FecWriteRateLimiter::new();
        let t0 = Instant::now();
        assert!(matches!(lim.offer(frame(1), t0), RateDecision::SendNow(_)));
        match lim.offer(frame(2), t0 + Duration::from_millis(10)) {
            RateDecision::Coalesced { wait } => {
                assert!(wait <= FEC_MIN_WRITE_INTERVAL);
                assert!(wait >= Duration::from_millis(200));
            }
            other => panic!("expected Coalesced, got {other:?}"),
        }
        // Newer supersedes older pending
        assert!(matches!(
            lim.offer(frame(3), t0 + Duration::from_millis(20)),
            RateDecision::Coalesced { .. }
        ));
        let flushed = lim
            .take_pending_if_ready(t0 + FEC_MIN_WRITE_INTERVAL)
            .expect("pending");
        assert_eq!(flushed, frame(3), "latest-wins coalesce");
        assert!(!lim.has_pending());
    }

    #[test]
    fn after_interval_sends_immediately_again() {
        let mut lim = FecWriteRateLimiter::new();
        let t0 = Instant::now();
        assert!(matches!(lim.offer(frame(1), t0), RateDecision::SendNow(_)));
        let t1 = t0 + FEC_MIN_WRITE_INTERVAL;
        match lim.offer(frame(2), t1) {
            RateDecision::SendNow(p) => assert_eq!(p, frame(2)),
            other => panic!("expected SendNow after interval, got {other:?}"),
        }
    }

    #[test]
    fn take_pending_not_ready_before_interval() {
        let mut lim = FecWriteRateLimiter::new();
        let t0 = Instant::now();
        let _ = lim.offer(frame(1), t0);
        let _ = lim.offer(frame(2), t0 + Duration::from_millis(5));
        assert!(lim.take_pending_if_ready(t0 + Duration::from_millis(50)).is_none());
        assert!(lim.has_pending());
    }

    #[test]
    fn ten_offers_in_one_window_only_one_immediate_rest_coalesce() {
        let mut lim = FecWriteRateLimiter::new();
        let t0 = Instant::now();
        let mut send_now = 0usize;
        let mut coalesced = 0usize;
        for i in 0..10u8 {
            // All within the same 250 ms window (0..90 ms)
            match lim.offer(frame(i), t0 + Duration::from_millis(u64::from(i) * 10)) {
                RateDecision::SendNow(_) => send_now += 1,
                RateDecision::Coalesced { .. } => coalesced += 1,
            }
        }
        assert_eq!(send_now, 1, "only first write in a 4 Hz window is immediate");
        assert_eq!(coalesced, 9);
        let flushed = lim
            .take_pending_if_ready(t0 + FEC_MIN_WRITE_INTERVAL)
            .expect("pending latest");
        assert_eq!(flushed, frame(9), "latest-wins after burst");
    }

    #[test]
    fn min_interval_is_250ms() {
        assert_eq!(FEC_MIN_WRITE_INTERVAL, Duration::from_millis(250));
    }
}

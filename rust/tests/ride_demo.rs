//! End-to-end: the 1 Hz ride sampler records a connected demo trainer.
use tacx_desktop_core::api::trainer as api;
use tacx_desktop_core::trainer::controller::{controller, ensure_runtime};

#[test]
fn ride_stats_accumulate_while_demo_connected() {
    ensure_runtime();
    let rt = tacx_desktop_core::trainer::controller::runtime();
    rt.block_on(async {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.set_demo_mode(true).await;
        let devs = g.scan(300).await.expect("scan");
        g.connect(Some(devs[0].id.clone())).await.expect("connect");
        g.set_target_power(200).await.expect("erg");
    });
    api::reset_ride_stats();
    // Poll (≤10 s) instead of a fixed sleep: CI runners can be slow.
    let mut s = api::get_ride_stats();
    for _ in 0..100 {
        if s.elapsed_s >= 2 && s.energy_kj > 0.0 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
        s = api::get_ride_stats();
    }
    assert!(s.recording, "recording while connected: {s:?}");
    assert!(s.elapsed_s >= 2, "elapsed: {s:?}");
    assert!(s.avg_power_w > 0.0 && s.max_power_w >= s.avg_power_w, "power: {s:?}");
    assert!(s.energy_kj > 0.0 && s.distance_km > 0.0, "totals: {s:?}");

    api::reset_ride_stats();
    let z = api::get_ride_stats();
    assert_eq!(z.elapsed_s, 0);
    assert_eq!(z.energy_kj, 0.0);

    rt.block_on(async {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        let _ = g.disconnect().await;
    });
    let mut idle = api::get_ride_stats();
    for _ in 0..30 {
        if !idle.recording {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
        idle = api::get_ride_stats();
    }
    assert!(!idle.recording, "stops recording after disconnect: {idle:?}");
}

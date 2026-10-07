use tacx_desktop_core::trainer::controller::{controller, ensure_runtime};
use tacx_desktop_core::trainer::intervals::{preset_by_key, presets, IntervalEngine};
use tacx_desktop_core::trainer::types::ConnectionState;
use std::sync::{Arc, Mutex};

#[test]
fn presets_complete() {
    let keys: Vec<_> = presets().into_iter().map(|p| p.key).collect();
    assert!(keys.contains(&"10x30_30".into()));
    assert!(keys.contains(&"5x3_2".into()));
    assert!(keys.contains(&"4x4_3".into()));
    assert!(preset_by_key("nope").is_none());
}

#[tokio::test]
async fn interval_engine_fires_targets() {
    let engine = IntervalEngine::new();
    let hits: Arc<Mutex<Vec<u32>>> = Arc::new(Mutex::new(Vec::new()));
    let hits2 = hits.clone();
    let handle = tokio::spawn(async move {
        let _ = engine
            .run("10x30_30", |w| {
                let hits2 = hits2.clone();
                async move {
                    hits2.lock().unwrap().push(w);
                    Ok(())
                }
            })
            .await;
    });
    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
    handle.abort();
    let v = hits.lock().unwrap().clone();
    assert_eq!(v.first().copied(), Some(280));
}

#[tokio::test(flavor = "current_thread")]
async fn reconnect_after_demo_connect() {
    ensure_runtime();
    // Use controller async API only — avoid sync FRB helpers that block_on.
    {
        let ctrl = controller();
        let mut g = ctrl.lock().await;
        g.set_demo_mode(true).await;
        let devices = g.scan(300).await.expect("scan");
        g.connect(Some(devices[0].id.clone()))
            .await
            .expect("connect");
        g.disconnect().await.expect("disc");
        g.reconnect().await.expect("reconnect");
        assert_eq!(g.snapshot().state, ConnectionState::Connected);
        g.disconnect().await.ok();
    }
}

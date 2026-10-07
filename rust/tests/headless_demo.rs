#[tokio::test]
async fn headless_demo_smoke() {
    tacx_desktop_core::trainer::controller::ensure_runtime();
    let msg = tacx_desktop_core::api::trainer::run_headless_demo_smoke()
        .await
        .expect("smoke");
    assert!(msg.contains("OK"));
}

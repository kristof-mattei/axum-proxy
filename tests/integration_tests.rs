#![expect(clippy::tests_outside_test_module, reason = "Integration tests")]

#[test]
fn assert_world_ok() {
    let cls1 = || true;
    let cls2 = || true;
    assert_eq!(cls1(), cls2());
}

#[test]
fn assert_world_ok2() {
    let cls1 = || false;
    let cls2 = || false;
    assert_eq!(cls1(), cls2());
}

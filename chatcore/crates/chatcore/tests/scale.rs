//! Chạy kịch bản dùng chung ở `src/scenarios.rs`.
use chatcore::scenarios::scale as s;

#[test]
fn group_at_device_limit() {
    s::group_at_device_limit();
}

#[test]
fn limits_are_enforced() {
    s::limits_are_enforced();
}

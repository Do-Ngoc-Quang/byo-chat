//! Chạy kịch bản dùng chung ở `src/scenarios.rs`.
use chatcore::scenarios::scale as s;

#[test]
fn group_of_1000_devices() {
    s::group_of_1000_devices();
}

#[test]
fn limits_are_enforced() {
    s::limits_are_enforced();
}

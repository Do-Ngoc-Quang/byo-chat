//! Chạy kịch bản dùng chung ở `src/scenarios.rs`.
use chatcore::scenarios::recovery as s;

#[test]
fn recovery_with_new_signing_key_keeps_old_leaf_until_lowest_index_removes_it() {
    s::recovery_with_new_signing_key_keeps_old_leaf_until_lowest_index_removes_it();
}

#[test]
fn resync_with_same_signing_key_removes_old_leaf_by_itself() {
    s::resync_with_same_signing_key_removes_old_leaf_by_itself();
}

#[test]
fn exporter_rules_for_sframe_key() {
    s::exporter_rules_for_sframe_key();
}

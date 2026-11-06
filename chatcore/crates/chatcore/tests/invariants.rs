//! Chạy kịch bản dùng chung ở `src/scenarios.rs`.
use chatcore::scenarios::invariants as s;

#[test]
fn inv1_same_epoch_and_exporter_after_mixed_commits() {
    s::inv1_same_epoch_and_exporter_after_mixed_commits();
}

#[test]
fn inv2_concurrent_commits_only_one_wins() {
    s::inv2_concurrent_commits_only_one_wins();
}

#[test]
fn inv3_every_logged_message_decrypts_with_its_epoch_key() {
    s::inv3_every_logged_message_decrypts_with_its_epoch_key();
}

#[test]
fn send_with_stale_epoch_is_rejected() {
    s::send_with_stale_epoch_is_rejected();
}

#[test]
fn inv4_removed_device_cannot_read_later_epochs() {
    s::inv4_removed_device_cannot_read_later_epochs();
}

#[test]
fn inv5_retry_with_same_client_msg_id_adds_no_entry() {
    s::inv5_retry_with_same_client_msg_id_adds_no_entry();
}

//! Chạy lại các kịch bản bất biến / recovery / scale trên WASM (node và trình duyệt).
use chatcore::scenarios::{invariants as i, recovery as r, scale as s};
use wasm_bindgen_test::*;
#[cfg(feature = "browser")]
wasm_bindgen_test_configure!(run_in_browser);

#[wasm_bindgen_test] fn inv1() { i::inv1_same_epoch_and_exporter_after_mixed_commits(); }
#[wasm_bindgen_test] fn inv2() { i::inv2_concurrent_commits_only_one_wins(); }
#[wasm_bindgen_test] fn inv3() { i::inv3_every_logged_message_decrypts_with_its_epoch_key(); }
#[wasm_bindgen_test] fn inv4() { i::inv4_removed_device_cannot_read_later_epochs(); }
#[wasm_bindgen_test] fn inv5() { i::inv5_retry_with_same_client_msg_id_adds_no_entry(); }
#[wasm_bindgen_test] fn stale_epoch() { i::send_with_stale_epoch_is_rejected(); }
#[wasm_bindgen_test] fn recovery_new_key() { r::recovery_with_new_signing_key_keeps_old_leaf_until_lowest_index_removes_it(); }
#[wasm_bindgen_test] fn resync_same_key() { r::resync_with_same_signing_key_removes_old_leaf_by_itself(); }
#[wasm_bindgen_test] fn exporter() { r::exporter_rules_for_sframe_key(); }
#[wasm_bindgen_test] fn limits() { s::limits_are_enforced(); }
#[wasm_bindgen_test] fn scale_at_limit() { s::group_at_device_limit(); }

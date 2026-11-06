//! Cầu nối WASM của `chatcore` cho Web (chạy trong Web Worker). Hiện chỉ có khung; API MLS
//! cho Dart thêm ở giai đoạn 3.
use wasm_bindgen::prelude::*;

/// Phiên bản lõi, để Dart/JS kiểm tra nạp đúng.
#[wasm_bindgen]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

//! Lõi MLS của hệ thống chat (spec: docs/spec/giao-thuc.md mục 6, 8).
//! Bọc OpenMLS 0.8; không tự viết primitive mật mã.
pub mod api;
pub mod credential;
pub mod mls;
pub mod scenarios;
pub mod sim;
pub mod pb {
    include!(concat!(env!("OUT_DIR"), "/chat.v1.rs"));
}

/// Phiên bản lõi (dùng chung cho cầu nối FFI và WASM).
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

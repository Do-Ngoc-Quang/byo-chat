//! Lõi MLS của hệ thống chat (spec: docs/spec/giao-thuc.md mục 6, 8).
//! Bọc OpenMLS 0.8; không tự viết primitive mật mã.
pub mod mls;
pub mod sim;
pub mod pb {
    include!(concat!(env!("OUT_DIR"), "/chat.v1.rs"));
}

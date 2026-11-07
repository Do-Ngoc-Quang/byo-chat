//! Cầu nối WASM của `chatcore` cho Web (chạy trong Web Worker, ADR 0006).
use wasm_bindgen::prelude::*;

/// Phiên bản lõi, để Dart/JS kiểm tra nạp đúng.
#[wasm_bindgen]
pub fn core_version() -> String {
    chatcore::version().to_string()
}

/// Một thiết bị; Worker giữ một thể hiện. `call` theo `chatcore::api::Core::call`.
#[wasm_bindgen]
pub struct WasmCore(chatcore::api::Core);

#[wasm_bindgen]
impl WasmCore {
    #[wasm_bindgen(constructor)]
    pub fn new(identity: &[u8]) -> Result<WasmCore, JsError> {
        chatcore::api::Core::new(identity).map(WasmCore).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Tạo thiết bị theo spec 6.1; `args` như `chatcore::api::Core::open_device`.
    pub fn open_device(args: &[u8]) -> Result<WasmCore, JsError> {
        chatcore::api::Core::open_device(args).map(WasmCore).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Khôi phục từ snapshot đã mã hóa; `args` như `chatcore::api::Core::open_restore`.
    pub fn open_restore(args: &[u8]) -> Result<WasmCore, JsError> {
        chatcore::api::Core::open_restore(args).map(WasmCore).map_err(|e| JsError::new(&e.to_string()))
    }

    pub fn call(&mut self, op: &str, args: &[u8]) -> Result<Vec<u8>, JsError> {
        self.0.call(op, args).map_err(|e| JsError::new(&e.to_string()))
    }
}

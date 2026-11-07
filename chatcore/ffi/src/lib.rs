//! Cầu nối C ABI của `chatcore` cho Dart (`dart:ffi`) trên Android và desktop (ADR 0006).
//! Quy ước: bộ đệm/chuỗi trả về cấp phát ở Rust, Dart phải giải phóng bằng hàm `*_free` tương ứng.
//! Không để panic vượt ranh giới C: mọi hàm bọc `catch_unwind` và báo lỗi bằng chuỗi.
use chatcore::api::Core;
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

fn cstr(s: impl Into<Vec<u8>>) -> *mut c_char {
    CString::new(s).unwrap_or_else(|_| CString::new("lỗi có byte NUL").unwrap()).into_raw()
}

/// Phiên bản lõi, để Dart kiểm tra nạp đúng thư viện.
#[no_mangle]
pub extern "C" fn chatcore_version() -> *mut c_char {
    cstr(chatcore::version())
}

/// Giải phóng chuỗi do hàm của thư viện này trả về.
///
/// # Safety
/// `p` phải do thư viện này trả về và chưa giải phóng, hoặc null.
#[no_mangle]
pub unsafe extern "C" fn chatcore_string_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}

/// Tạo thiết bị với `identity`. Thành công: trả con trỏ, `*err` = null. Lỗi: trả null, `*err` là chuỗi lỗi.
///
/// # Safety
/// `identity` trỏ tới `len` byte hợp lệ; `err` trỏ tới ô con trỏ ghi được.
#[no_mangle]
pub unsafe extern "C" fn chatcore_open(identity: *const u8, len: usize, err: *mut *mut c_char) -> *mut Core {
    *err = std::ptr::null_mut();
    let id = std::slice::from_raw_parts(identity, len);
    match catch_unwind(|| Core::new(id)) {
        Ok(Ok(c)) => Box::into_raw(Box::new(c)),
        Ok(Err(e)) => {
            *err = cstr(e.to_string());
            std::ptr::null_mut()
        }
        Err(_) => {
            *err = cstr("panic trong chatcore_open");
            std::ptr::null_mut()
        }
    }
}

/// Tạo thiết bị theo spec 6.1 (xem `Core::open_device`); `args` là danh sách đã đóng gói.
///
/// # Safety
/// Như `chatcore_open`.
#[no_mangle]
pub unsafe extern "C" fn chatcore_open_device(args: *const u8, len: usize, err: *mut *mut c_char) -> *mut Core {
    *err = std::ptr::null_mut();
    let a = std::slice::from_raw_parts(args, len);
    match catch_unwind(|| Core::open_device(a)) {
        Ok(Ok(c)) => Box::into_raw(Box::new(c)),
        Ok(Err(e)) => {
            *err = cstr(e.to_string());
            std::ptr::null_mut()
        }
        Err(_) => {
            *err = cstr("panic trong chatcore_open_device");
            std::ptr::null_mut()
        }
    }
}

/// Khôi phục thiết bị từ snapshot đã mã hóa (xem `Core::open_restore`); `args` = [sealed, key] đã đóng gói.
///
/// # Safety
/// Như `chatcore_open`.
#[no_mangle]
pub unsafe extern "C" fn chatcore_open_restore(args: *const u8, len: usize, err: *mut *mut c_char) -> *mut Core {
    *err = std::ptr::null_mut();
    let a = std::slice::from_raw_parts(args, len);
    match catch_unwind(|| Core::open_restore(a)) {
        Ok(Ok(c)) => Box::into_raw(Box::new(c)),
        Ok(Err(e)) => {
            *err = cstr(e.to_string());
            std::ptr::null_mut()
        }
        Err(_) => {
            *err = cstr("panic trong chatcore_open_restore");
            std::ptr::null_mut()
        }
    }
}

/// Hủy thiết bị.
///
/// # Safety
/// `h` do `chatcore_open` trả về và chưa đóng, hoặc null.
#[no_mangle]
pub unsafe extern "C" fn chatcore_close(h: *mut Core) {
    if !h.is_null() {
        drop(Box::from_raw(h));
    }
}

/// Gọi thao tác `op` với đối số đã đóng gói (xem `chatcore::api::Core::call`).
/// Thành công: trả null, `*out`/`*out_len` là kết quả (giải phóng bằng `chatcore_buf_free`).
/// Lỗi: trả chuỗi lỗi (giải phóng bằng `chatcore_string_free`).
///
/// # Safety
/// `h` hợp lệ và không bị gọi đồng thời từ nhiều luồng; `op` là chuỗi C; `args` trỏ `args_len` byte.
#[no_mangle]
pub unsafe extern "C" fn chatcore_call(
    h: *mut Core,
    op: *const c_char,
    args: *const u8,
    args_len: usize,
    out: *mut *mut u8,
    out_len: *mut usize,
) -> *mut c_char {
    let core = &mut *h;
    let args = std::slice::from_raw_parts(args, args_len);
    let Ok(op) = CStr::from_ptr(op).to_str() else { return cstr("op không phải UTF-8") };
    match catch_unwind(AssertUnwindSafe(|| core.call(op, args))) {
        Ok(Ok(v)) => {
            let b = v.into_boxed_slice();
            *out_len = b.len();
            *out = Box::into_raw(b) as *mut u8;
            std::ptr::null_mut()
        }
        Ok(Err(e)) => cstr(e.to_string()),
        Err(_) => cstr("panic trong chatcore_call"),
    }
}

/// Giải phóng bộ đệm do `chatcore_call` trả về.
///
/// # Safety
/// `p`/`len` đúng như `chatcore_call` đã trả, chưa giải phóng.
#[no_mangle]
pub unsafe extern "C" fn chatcore_buf_free(p: *mut u8, len: usize) {
    if !p.is_null() {
        drop(Box::from_raw(std::slice::from_raw_parts_mut(p, len)));
    }
}

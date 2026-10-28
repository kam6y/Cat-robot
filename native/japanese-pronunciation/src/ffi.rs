//! Minimal C boundary. The owning Swift actor serializes access to each handle.
use crate::{Error, Pronouncer, MAX_INPUT_BYTES};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    panic::{catch_unwind, AssertUnwindSafe},
    path::Path,
    ptr,
};

fn status<T>(operation: impl FnOnce() -> Result<T, Error>, success: impl FnOnce(T)) -> i32 {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(value)) => {
            success(value);
            0
        }
        Ok(Err(Error::InvalidInput)) => 1,
        Ok(Err(_)) => 2,
        Err(_) => 3,
    }
}

/// # Safety
/// `path` must be a live NUL-terminated UTF-8 string, and `out` writable.
#[no_mangle]
pub unsafe extern "C" fn cjp_create(path: *const c_char, out: *mut *mut c_void) -> i32 {
    if out.is_null() {
        return 1;
    }
    *out = ptr::null_mut();
    if path.is_null() {
        return 1;
    }
    status(
        || {
            let path = CStr::from_ptr(path)
                .to_str()
                .map_err(|_| Error::InvalidInput)?;
            let instance = Pronouncer::load(Path::new(path))?;
            Ok(Box::into_raw(Box::new(instance)).cast::<c_void>())
        },
        |value| *out = value,
    )
}

/// # Safety
/// `handle` must be a live cjp_create result used by one caller at a time;
/// `input` must point to `len` readable bytes and `out` must be writable.
#[no_mangle]
pub unsafe extern "C" fn cjp_convert(
    handle: *mut c_void,
    input: *const u8,
    len: usize,
    out: *mut *mut c_char,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    *out = ptr::null_mut();
    if handle.is_null() || input.is_null() || len > MAX_INPUT_BYTES {
        return 1;
    }
    status(
        || {
            let bytes = std::slice::from_raw_parts(input, len);
            let text = std::str::from_utf8(bytes).map_err(|_| Error::InvalidInput)?;
            let result = (&*handle.cast::<Pronouncer>()).pronounce(text)?;
            Ok(CString::new(result)
                .map_err(|_| Error::Conversion)?
                .into_raw())
        },
        |value| *out = value,
    )
}

/// # Safety
/// `text` must be null or a string returned by cjp_convert, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn cjp_string_free(text: *mut c_char) {
    if !text.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(CString::from_raw(text))));
    }
}

/// # Safety
/// `handle` must be null or a cjp_create result, destroyed once after all calls.
#[no_mangle]
pub unsafe extern "C" fn cjp_destroy(handle: *mut c_void) {
    if !handle.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(Box::from_raw(handle.cast::<Pronouncer>()))
        }));
    }
}

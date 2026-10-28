use cjp_pronunciation::ffi::*;
use std::{
    ffi::{c_char, c_void, CStr, CString},
    ptr,
};

fn handle() -> *mut c_void {
    let path =
        CString::new(std::env::var("JPREPROCESS_DICT").expect("real dictionary required")).unwrap();
    let mut handle = ptr::null_mut();
    assert_eq!(unsafe { cjp_create(path.as_ptr(), &mut handle) }, 0);
    assert!(!handle.is_null());
    handle
}

#[test]
fn native_allocation_roundtrip_reads_and_releases() {
    let handle = handle();
    for _ in 0..3 {
        let input = "YouTubeを見よう。";
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe { cjp_convert(handle, input.as_ptr(), input.len(), &mut result) },
            0
        );
        assert!(!result.is_null());
        assert_eq!(
            unsafe { CStr::from_ptr(result) }.to_str().unwrap(),
            "ユーチューブヲミヨー。"
        );
        unsafe {
            cjp_string_free(result);
        }
    }
    unsafe {
        cjp_destroy(handle);
        cjp_string_free(ptr::null_mut());
        cjp_destroy(ptr::null_mut());
    }
}

#[test]
fn null_arguments_are_rejected_and_output_is_cleared() {
    let mut output = ptr::dangling_mut::<c_char>();
    assert_eq!(
        unsafe { cjp_convert(ptr::null_mut(), ptr::null(), 0, &mut output) },
        1
    );
    assert!(output.is_null());
    assert_eq!(
        unsafe { cjp_convert(ptr::null_mut(), ptr::null(), 0, ptr::null_mut()) },
        1
    );
    let mut created = ptr::dangling_mut::<c_void>();
    assert_eq!(unsafe { cjp_create(ptr::null(), &mut created) }, 1);
    assert!(created.is_null());
    assert_eq!(unsafe { cjp_create(ptr::null(), ptr::null_mut()) }, 1);
}

#[test]
fn malformed_input_is_rejected_before_speech() {
    let handle = handle();
    for input in [vec![0xff], b"a\0b".to_vec(), vec![b'a'; 32_769]] {
        let mut output = ptr::dangling_mut::<c_char>();
        assert_eq!(
            unsafe { cjp_convert(handle, input.as_ptr(), input.len(), &mut output) },
            1
        );
        assert!(output.is_null());
    }
    let mut output = ptr::dangling_mut::<c_char>();
    assert_eq!(
        unsafe { cjp_convert(handle, ptr::null(), 4, &mut output) },
        1
    );
    assert!(output.is_null());
    unsafe {
        cjp_destroy(handle);
    }
}

#[test]
fn failed_dictionary_initialization_has_no_handle() {
    let path = CString::new("/missing-catrobot-dictionary").unwrap();
    let mut output = ptr::dangling_mut::<c_void>();
    assert_eq!(unsafe { cjp_create(path.as_ptr(), &mut output) }, 2);
    assert!(output.is_null());
}

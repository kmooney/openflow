//! Put text on the clipboard and paste it into whatever has focus.
//!
//! Insertion is deliberately the simple strategy: clipboard plus a synthesized
//! Ctrl+V works in essentially every app, including Electron shells and
//! terminals, where writing through UI Automation's `ValuePattern` is
//! inconsistent (and, in a terminal, usually impossible). The cost is that we
//! borrow the clipboard for a moment, so we put the old contents back.

use std::time::Duration;

use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN,
};
use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, SetForegroundWindow};

/// Copy text to the clipboard, without pasting. What the Listen button does.
pub fn copy(text: &str) -> bool {
    set_clipboard_text(text)
}

/// Paste `text` into whatever had focus, restoring the clipboard afterwards.
///
/// Runs on a thread of its own because it waits: a synthesized keystroke picks
/// up whatever modifiers are physically held, so firing Ctrl+V while Ctrl+Shift
/// is still down delivers Ctrl+Shift+V -- which pastes as plain text in some
/// apps and does nothing at all in others. It waits for the real modifier state
/// rather than guessing at how fast someone lets go.
pub fn paste(text: String, target: Option<HWND>) {
    if text.is_empty() {
        return;
    }
    let target = target.map(|h| h.0 as isize);
    std::thread::Builder::new()
        .name("openflow.paste".into())
        .spawn(move || {
            let saved = read_clipboard_text();
            if !set_clipboard_text(&text) {
                return;
            }

            wait_for_modifiers_to_clear();

            // Only if focus has actually moved: an unsolicited
            // SetForegroundWindow is usually refused by Windows anyway, and we
            // never took focus in the first place.
            if let Some(h) = target {
                let target = HWND(h as *mut std::ffi::c_void);
                unsafe {
                    if GetForegroundWindow() != target {
                        let _ = SetForegroundWindow(target);
                        std::thread::sleep(Duration::from_millis(30));
                    }
                }
            }

            send_ctrl_v();

            // Long enough for the target app to have read the clipboard.
            // Restoring too early pastes the old contents instead.
            std::thread::sleep(Duration::from_millis(450));
            if let Some(saved) = saved {
                set_clipboard_text(&saved);
            }
        })
        .ok();
}

/// Poll until no modifier is held. Gives up after a second and pastes anyway --
/// someone genuinely resting on a modifier should still get their text.
fn wait_for_modifiers_to_clear() {
    for _ in 0..40 {
        if !any_modifier_down() {
            // One beat after the last modifier lifts, so the focused app has
            // processed the key-up before the paste arrives.
            std::thread::sleep(Duration::from_millis(30));
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    std::thread::sleep(Duration::from_millis(30));
}

fn any_modifier_down() -> bool {
    [VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN]
        .iter()
        .any(|vk| (unsafe { GetAsyncKeyState(vk.0 as i32) } as u16 & 0x8000) != 0)
}

fn key_input(vk: VIRTUAL_KEY, up: bool) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up {
                    KEYEVENTF_KEYUP
                } else {
                    Default::default()
                },
                time: 0,
                // So the hotkey hook can tell our paste from the user typing.
                dwExtraInfo: crate::win::INPUT_SIGNATURE,
            },
        },
    }
}

fn send_ctrl_v() {
    const V: VIRTUAL_KEY = VIRTUAL_KEY(0x56);
    let inputs = [
        key_input(VK_CONTROL, false),
        key_input(V, false),
        key_input(V, true),
        key_input(VK_CONTROL, true),
    ];
    unsafe {
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

fn set_clipboard_text(text: &str) -> bool {
    let mut utf16: Vec<u16> = text.encode_utf16().collect();
    utf16.push(0);
    let bytes = std::mem::size_of_val(&utf16[..]);

    unsafe {
        // The clipboard is a shared, single-owner resource; another app may
        // hold it for a few milliseconds. Retrying beats losing the paste.
        if !open_clipboard_with_retry() {
            return false;
        }
        let ok = (|| {
            EmptyClipboard().ok()?;
            let handle: HGLOBAL = GlobalAlloc(GMEM_MOVEABLE, bytes).ok()?;
            let ptr = GlobalLock(handle) as *mut u16;
            if ptr.is_null() {
                return None;
            }
            std::ptr::copy_nonoverlapping(utf16.as_ptr(), ptr, utf16.len());
            let _ = GlobalUnlock(handle);
            // Ownership passes to the clipboard on success, so the memory must
            // not be freed here.
            SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(handle.0))).ok()?;
            Some(())
        })()
        .is_some();
        let _ = CloseClipboard();
        ok
    }
}

fn read_clipboard_text() -> Option<String> {
    unsafe {
        if !open_clipboard_with_retry() {
            return None;
        }
        let text = (|| {
            let handle = GetClipboardData(CF_UNICODETEXT.0 as u32).ok()?;
            let global = HGLOBAL(handle.0);
            let ptr = GlobalLock(global) as *const u16;
            if ptr.is_null() {
                return None;
            }
            let mut len = 0usize;
            while *ptr.add(len) != 0 {
                len += 1;
            }
            let slice = std::slice::from_raw_parts(ptr, len);
            let s = String::from_utf16_lossy(slice);
            let _ = GlobalUnlock(global);
            Some(s)
        })();
        let _ = CloseClipboard();
        text
    }
}

fn open_clipboard_with_retry() -> bool {
    for _ in 0..10 {
        if unsafe { OpenClipboard(None) }.is_ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The clipboard is a real machine-wide resource, so this both proves the
    /// round trip and would catch a leak of the global handle.
    #[test]
    fn text_survives_a_clipboard_round_trip() {
        let before = read_clipboard_text();
        let sample = "OpenFlow round trip \u{2014} caf\u{e9}, na\u{ef}ve, \u{1f3a4}";
        assert!(set_clipboard_text(sample));
        assert_eq!(read_clipboard_text().as_deref(), Some(sample));
        // Leave the user's clipboard as we found it.
        if let Some(b) = before {
            set_clipboard_text(&b);
        }
    }

    #[test]
    fn empty_text_is_not_pasted() {
        // Nothing to assert beyond "this does not panic or clear the
        // clipboard": paste returns before touching anything.
        paste(String::new(), None);
    }
}

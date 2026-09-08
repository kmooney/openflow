//! Reads what has focus right now: which app, and which field inside it.
//!
//! This runs on the hotkey press, immediately before the microphone opens, so
//! it has a hard constraint the rest of the app does not: **it must never
//! block.** A UI Automation query is a cross-process call, and a busy or hung
//! app can sit on one indefinitely, which would swallow the beginning of the
//! utterance. Every query below degrades to the app-wide answer rather than
//! stopping anything, and the whole field lookup runs under a deadline.

use std::ffi::c_void;
use std::sync::mpsc;
use std::time::Duration;

use windows::core::BSTR;
use windows::Win32::Foundation::{CloseHandle, HWND, MAX_PATH};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::System::ProcessStatus::GetModuleFileNameExW;
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_VM_READ,
};
use windows::Win32::UI::Accessibility::{CUIAutomation, IUIAutomation};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumChildWindows, GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId,
};

use crate::kit::context::{DictationContext, FieldKind};

/// How long we will wait on another process before giving up on the field and
/// keeping just the app. Long enough for a healthy app answering in
/// single-digit milliseconds, short enough that a wedged one is not our
/// problem.
const FIELD_TIMEOUT: Duration = Duration::from_millis(200);

pub fn foreground_window() -> Option<HWND> {
    let hwnd = unsafe { GetForegroundWindow() };
    (!hwnd.is_invalid()).then_some(hwnd)
}

/// The app and field that have focus. Never blocks for longer than
/// [`FIELD_TIMEOUT`].
pub fn current() -> DictationContext {
    let Some(hwnd) = foreground_window() else {
        return DictationContext::unknown();
    };
    let (app_id, app_name) = app_of(hwnd);
    let base = DictationContext::new(app_id.clone(), app_name.clone(), FieldKind::Unknown);
    if app_id.is_none() {
        return base;
    }

    match focused_field() {
        Some(field) => DictationContext::new(app_id, app_name, field),
        None => base,
    }
}

/// Just the foreground app, with no field lookup.
///
/// This is what the twice-a-second poll uses. Reading the focused element is a
/// cross-process call, and making one of those continuously so a tray menu can
/// show a label would be rude to every other app on the machine; the field is
/// resolved once, when the chord goes down and it actually matters.
pub fn current_app_only() -> DictationContext {
    let Some(hwnd) = foreground_window() else {
        return DictationContext::unknown();
    };
    let (app_id, app_name) = app_of(hwnd);
    DictationContext::new(app_id, app_name, FieldKind::Unknown)
}

/// Executable name and window title for the process owning `hwnd`.
fn app_of(hwnd: HWND) -> (Option<String>, Option<String>) {
    let hwnd = real_owner(hwnd);
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    if pid == 0 {
        return (None, None);
    }

    let exe = unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ,
            false,
            pid,
        )
    }
    .ok()
    .and_then(|handle| {
        let mut buf = [0u16; MAX_PATH as usize];
        let len = unsafe { GetModuleFileNameExW(Some(handle), None, &mut buf) };
        unsafe { CloseHandle(handle).ok() };
        (len > 0).then(|| String::from_utf16_lossy(&buf[..len as usize]))
    })
    .and_then(|path| {
        path.rsplit(['\\', '/'])
            .next()
            .map(|s| s.to_lowercase())
            .filter(|s| !s.is_empty())
    });

    // The window title is a poor display name (it changes with the document),
    // so the executable stands in when nothing better is available. Deriving a
    // pretty name from version resources was tried and is not worth the code:
    // "chrome.exe" is recognisable, and the user is choosing from a short list.
    let title = window_title(hwnd).filter(|t| !t.is_empty());
    let name = exe.clone().map(|e| pretty_name(&e, title.as_deref()));
    (exe, name)
}

/// Packaged (UWP/WinUI) apps are hosted by ApplicationFrameHost.exe, so asking
/// the foreground window for its process gives the host rather than the app.
/// The real one owns a child window with a different process id.
fn real_owner(hwnd: HWND) -> HWND {
    let mut host_pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut host_pid)) };
    if host_pid == 0 || !is_frame_host(host_pid) {
        return hwnd;
    }

    struct Search {
        host_pid: u32,
        found: Option<HWND>,
    }
    let mut search = Search {
        host_pid,
        found: None,
    };

    unsafe extern "system" fn visit(child: HWND, param: windows::Win32::Foundation::LPARAM) -> windows::core::BOOL {
        let search = &mut *(param.0 as *mut Search);
        let mut pid = 0u32;
        GetWindowThreadProcessId(child, Some(&mut pid));
        if pid != 0 && pid != search.host_pid {
            search.found = Some(child);
            return false.into(); // stop enumerating
        }
        true.into()
    }

    unsafe {
        let _ = EnumChildWindows(
            Some(hwnd),
            Some(visit),
            windows::Win32::Foundation::LPARAM(&mut search as *mut Search as isize),
        );
    }
    search.found.unwrap_or(hwnd)
}

fn is_frame_host(pid: u32) -> bool {
    let Ok(handle) =
        (unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, pid) })
    else {
        return false;
    };
    let mut buf = [0u16; MAX_PATH as usize];
    let len = unsafe { GetModuleFileNameExW(Some(handle), None, &mut buf) };
    unsafe { CloseHandle(handle).ok() };
    if len == 0 {
        return false;
    }
    String::from_utf16_lossy(&buf[..len as usize])
        .to_lowercase()
        .ends_with("applicationframehost.exe")
}

fn window_title(hwnd: HWND) -> Option<String> {
    let mut buf = [0u16; 256];
    let len = unsafe { GetWindowTextW(hwnd, &mut buf) };
    (len > 0).then(|| String::from_utf16_lossy(&buf[..len as usize]))
}

/// A name a human recognises, from the executable and, where it helps, the
/// window title. Pure so the guesswork is testable.
pub fn pretty_name(exe: &str, title: Option<&str>) -> String {
    let stem = exe.strip_suffix(".exe").unwrap_or(exe);
    // Many apps put their own name last in the title ("Inbox - Outlook"), which
    // is a better label than the executable when the two agree.
    if let Some(title) = title {
        if let Some(tail) = title.rsplit(&[' ', '-'][..]).next() {
            if tail.len() > 2 && tail.to_lowercase() == stem.to_lowercase() {
                return tail.to_string();
            }
        }
    }
    stem.to_string()
}

/// The focused element's kind, via UI Automation, under a deadline.
///
/// Runs on a scratch thread: there is no way to cancel a cross-process COM call
/// once it is in flight, so the only way to keep a wedged app from holding up
/// the microphone is to stop waiting for it and let the thread finish on its
/// own. The thread is short-lived and touches nothing else.
fn focused_field() -> Option<FieldKind> {
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("openflow.focus".into())
        .spawn(move || {
            let _ = tx.send(read_focused_field());
        })
        .ok()?;
    rx.recv_timeout(FIELD_TIMEOUT).ok().flatten()
}

fn read_focused_field() -> Option<FieldKind> {
    unsafe {
        // Multithreaded apartment: this thread has no message loop, and an STA
        // without one deadlocks the moment a call needs to marshal.
        let com = CoInitializeEx(None, COINIT_MULTITHREADED);
        let result = (|| {
            let automation: IUIAutomation =
                CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER).ok()?;
            let element = automation.GetFocusedElement().ok()?;

            let role = element
                .CurrentLocalizedControlType()
                .ok()
                .map(bstr_to_string)
                .unwrap_or_default()
                .to_lowercase();
            // The localized name is what the user's Windows calls it, which is
            // no good for matching. The numeric control type is stable.
            let role = match element.CurrentControlType() {
                Ok(t) => control_type_name(t.0).unwrap_or(&role).to_string(),
                Err(_) => role,
            };

            let hints = [
                element.CurrentAutomationId().ok().map(bstr_to_string),
                element.CurrentName().ok().map(bstr_to_string),
                element.CurrentHelpText().ok().map(bstr_to_string),
                // Chromium and Electron apps routinely leave the field itself
                // anonymous and name the group around it.
                automation
                    .ControlViewWalker()
                    .ok()
                    .and_then(|walker| walker.GetParentElement(&element).ok())
                    .and_then(|parent| parent.CurrentName().ok())
                    .map(bstr_to_string),
            ];
            let hints: Vec<Option<&str>> = hints.iter().map(|h| h.as_deref()).collect();

            Some(FieldKind::classify(Some(&role), &hints))
        })();
        if com.is_ok() {
            CoUninitialize();
        }
        result
    }
}

fn bstr_to_string(b: BSTR) -> String {
    b.to_string()
}

/// The UI Automation control types worth naming, mapped to the vocabulary
/// `FieldKind::classify` speaks. Everything else classifies on its hints alone.
fn control_type_name(id: i32) -> Option<&'static str> {
    match id {
        50004 => Some("edit"),     // UIA_EditControlTypeId
        50003 => Some("combobox"), // UIA_ComboBoxControlTypeId
        50030 => Some("document"), // UIA_DocumentControlTypeId
        50020 => Some("text"),     // UIA_TextControlTypeId
        _ => None,
    }
}

/// Keeps the `c_void` import honest on builds where the paste target is unused.
const _: Option<*mut c_void> = None;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_types_map_to_the_vocabulary_classify_speaks() {
        assert_eq!(control_type_name(50004), Some("edit"));
        assert_eq!(control_type_name(50030), Some("document"));
        assert_eq!(control_type_name(1), None);
    }

    #[test]
    fn the_display_name_prefers_the_apps_own_name_when_the_title_agrees() {
        assert_eq!(pretty_name("outlook.exe", Some("Inbox - Outlook")), "Outlook");
        assert_eq!(pretty_name("code.exe", Some("main.rs - Code")), "Code");
    }

    #[test]
    fn a_title_that_says_nothing_useful_leaves_the_executable_name() {
        assert_eq!(pretty_name("chrome.exe", Some("Some page title")), "chrome");
        assert_eq!(pretty_name("chrome.exe", None), "chrome");
        assert_eq!(pretty_name("wt.exe", Some("wt")), "wt", "too short to be a name");
    }

    /// Reading focus must work, or degrade, on whatever is in the foreground
    /// when the tests run -- including nothing at all.
    #[test]
    fn reading_the_current_context_never_blocks_or_panics() {
        let started = std::time::Instant::now();
        let context = current();
        assert!(
            started.elapsed() < FIELD_TIMEOUT * 3,
            "focus detection must not hold up the microphone"
        );
        // Whatever it found, the identity must be normalised.
        if let Some(id) = &context.app_id {
            assert_eq!(*id, id.to_lowercase());
        }
    }
}

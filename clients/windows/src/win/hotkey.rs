//! Push-to-talk on a held modifier chord: hold to open the microphone, release
//! to send.
//!
//! A **low-level keyboard hook**, not `RegisterHotKey`. `RegisterHotKey` cannot
//! express a chord of modifiers with no ordinary key, which is the whole design
//! -- watching modifiers means the chord cannot collide with a shortcut the
//! focused app already owns, and nothing is typed while you hold it.
//!
//! The hook lives on **its own thread with its own message loop**, and that is
//! not tidiness. Windows silently removes a low-level hook whose callback takes
//! longer than `LowLevelHooksTimeout` (300 ms by default), so the hook may
//! never share a thread with a UI that paints or an engine that transcribes.
//! The callback here does nothing but read key state and post to a channel.
//!
//! It also does something the macOS client cannot: **an ordinary keystroke
//! arriving while the chord is held cancels the utterance.** The hook sees
//! every key, so Ctrl+Shift+T is a reopened tab rather than a recording, which
//! is what makes Ctrl+Shift usable as the default chord.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, VK_CAPITAL, VK_CONTROL, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU,
    VK_RCONTROL, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, GetMessageW, KillTimer, PostThreadMessageW, SetTimer, SetWindowsHookExW,
    UnhookWindowsHookEx, HHOOK, KBDLLHOOKSTRUCT, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_QUIT,
    WM_SYSKEYDOWN, WM_TIMER,
};

use crate::kit::chord::{self, ChordTracker, ModifierChord, Transition};
use crate::kit::wake::Wake;

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum HotkeyEvent {
    Pressed,
    Released,
    /// A key was pressed while the chord was held, so this was a shortcut.
    Cancelled,
}

/// Events give a fast press and release; polling makes it *correct*. A missed
/// release leaves the chord stuck engaged, so the next press does nothing and
/// the one after that behaves like a toggle. Reconciling against the real
/// modifier state means a dropped event costs 60 ms, not a broken hotkey.
const POLL_MS: u32 = 60;

pub struct Hotkey {
    pub events: Receiver<HotkeyEvent>,
    chord: Arc<AtomicU32>,
    arm_delay_ms: Arc<AtomicU64>,
    thread_id: u32,
    installed: Arc<AtomicBool>,
}

impl Hotkey {
    /// Change the chord without restarting the hook.
    pub fn set_chord(&self, chord: ModifierChord) {
        self.chord.store(chord.mask(), Ordering::Relaxed);
    }

    pub fn set_arm_delay(&self, delay: Duration) {
        self.arm_delay_ms
            .store(delay.as_millis() as u64, Ordering::Relaxed);
    }

    /// False when the hook could not be installed at all. Unlike macOS there is
    /// no permission to grant, so this is close to "never", but a false here
    /// must never be reported as a working hotkey.
    pub fn is_installed(&self) -> bool {
        self.installed.load(Ordering::Relaxed)
    }

    pub fn stop(&self) {
        unsafe {
            let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
        }
    }
}

/// State shared with the hook callback. A `static` rather than a field because
/// `SetWindowsHookExW` takes a bare function pointer with nowhere to hang a
/// context, and only one hook is ever installed.
struct Shared {
    /// Set by the callback when an ordinary key the user pressed goes down.
    /// Drained by the poll on the same thread.
    interrupted: AtomicBool,
}

static SHARED: OnceLock<Shared> = OnceLock::new();

pub fn start(initial: ModifierChord, arm_delay: Duration, wake: Arc<Wake>) -> Hotkey {
    let (tx, rx) = std::sync::mpsc::channel();
    let chord = Arc::new(AtomicU32::new(initial.mask()));
    let arm_delay_ms = Arc::new(AtomicU64::new(arm_delay.as_millis() as u64));
    let installed = Arc::new(AtomicBool::new(false));
    let (id_tx, id_rx) = std::sync::mpsc::channel::<u32>();

    let thread_chord = chord.clone();
    let thread_delay = arm_delay_ms.clone();
    let thread_installed = installed.clone();
    std::thread::Builder::new()
        .name("openflow.hotkey".into())
        .spawn(move || {
            let _ = id_tx.send(unsafe { GetCurrentThreadId() });
            hook_thread(tx, thread_chord, thread_delay, thread_installed, wake);
        })
        .expect("the hotkey thread must start");

    let thread_id = id_rx.recv().unwrap_or(0);
    Hotkey {
        events: rx,
        chord,
        arm_delay_ms,
        thread_id,
        installed,
    }
}

fn hook_thread(
    events: Sender<HotkeyEvent>,
    chord: Arc<AtomicU32>,
    arm_delay_ms: Arc<AtomicU64>,
    installed: Arc<AtomicBool>,
    wake: Arc<Wake>,
) {
    SHARED.get_or_init(|| Shared {
        interrupted: AtomicBool::new(false),
    });

    let hook = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(low_level_proc), None, 0) };
    let hook: Option<HHOOK> = match hook {
        Ok(h) => {
            installed.store(true, Ordering::Relaxed);
            Some(h)
        }
        Err(_) => None,
    };

    let timer = unsafe { SetTimer(None, 0, POLL_MS, None) };
    let mut push = PushToTalk::new(ModifierChord::new(chord.load(Ordering::Relaxed)));

    let mut msg = MSG::default();
    loop {
        let got = unsafe { GetMessageW(&mut msg, None, 0, 0) };
        if got.0 <= 0 {
            break; // WM_QUIT, or the queue is broken
        }
        if msg.message != WM_TIMER {
            continue;
        }

        // The chord can change while the hook is live; re-arm rather than
        // restarting the thread.
        let wanted = ModifierChord::new(chord.load(Ordering::Relaxed));
        push.retarget(wanted);
        push.arm_delay_ms = arm_delay_ms.load(Ordering::Relaxed);

        if let Some(shared) = SHARED.get() {
            if shared.interrupted.swap(false, Ordering::Relaxed) {
                if let Some(e) = push.interrupt() {
                    if events.send(e).is_err() {
                        break;
                    }
                    wake.wake();
                }
            }
        }

        if let Some(e) = push.update(current_modifiers(), now_ms()) {
            if events.send(e).is_err() {
                break;
            }
            // How soon the microphone opens after the chord goes down must not
            // depend on how often the UI happens to tick.
            wake.wake();
        }
    }

    unsafe {
        if timer != 0 {
            let _ = KillTimer(None, timer);
        }
        if let Some(h) = hook {
            let _ = UnhookWindowsHookEx(h);
        }
    }
    installed.store(false, Ordering::Relaxed);
}

/// Runs on the hook thread for every keystroke on the machine. It must stay
/// trivial: anything slow here gets the hook removed by Windows.
unsafe extern "system" fn low_level_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0 && (wparam.0 as u32 == WM_KEYDOWN || wparam.0 as u32 == WM_SYSKEYDOWN) {
        let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        // Our own synthesized Ctrl+V must not read as the user typing. Only
        // *ours* is excluded: someone typing through a remapper still gets
        // their shortcuts (see win::INPUT_SIGNATURE).
        let ours = info.dwExtraInfo == crate::win::INPUT_SIGNATURE;
        if !ours && !is_modifier(info.vkCode) {
            if let Some(shared) = SHARED.get() {
                shared.interrupted.store(true, Ordering::Relaxed);
            }
        }
    }
    // Never swallow the key. The chord is a listener, not a grab: everything
    // the user types still reaches the app they typed it into.
    CallNextHookEx(None, code, wparam, lparam)
}

fn is_modifier(vk: u32) -> bool {
    const MODIFIERS: [u16; 12] = [
        VK_CONTROL.0,
        VK_LCONTROL.0,
        VK_RCONTROL.0,
        VK_MENU.0,
        VK_LMENU.0,
        VK_RMENU.0,
        VK_SHIFT.0,
        VK_LSHIFT.0,
        VK_RSHIFT.0,
        VK_LWIN.0,
        VK_RWIN.0,
        // Caps Lock latches, so it is not part of any chord and pressing it is
        // not "typing" either.
        VK_CAPITAL.0,
    ];
    MODIFIERS.contains(&(vk as u16))
}

/// Physical modifier state, which is the authority. Event state alone drifts:
/// a `keyup` can go missing while a system window is up, and the next press is
/// then swallowed.
pub fn current_modifiers() -> u32 {
    let down = |vk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY| -> bool {
        (unsafe { GetAsyncKeyState(vk.0 as i32) } as u16 & 0x8000) != 0
    };
    let mut flags = 0;
    if down(VK_CONTROL) {
        flags |= chord::CONTROL;
    }
    if down(VK_MENU) {
        flags |= chord::ALT;
    }
    if down(VK_SHIFT) {
        flags |= chord::SHIFT;
    }
    if down(VK_LWIN) || down(VK_RWIN) {
        flags |= chord::WIN;
    }
    flags
}

fn now_ms() -> u64 {
    static START: OnceLock<std::time::Instant> = OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_millis() as u64
}

/// The chord decision with its arming delay, kept free of Win32 so it can be
/// tested. `ChordTracker` says whether the chord is down; this says whether
/// that should open the microphone.
struct PushToTalk {
    tracker: ChordTracker,
    /// How long the chord must be held before the microphone opens.
    ///
    /// macOS opens immediately, because a held Control-Option means nothing
    /// else. Ctrl+Shift is a prefix of real shortcuts, and opening the
    /// microphone on the way into Ctrl+Shift+Arrow -- which people press
    /// continuously while selecting text -- would be a device activation
    /// several times a minute for nothing.
    arm_delay_ms: u64,
    /// When the chord went down, if it has not opened the microphone yet.
    pending_since: Option<u64>,
    /// True between an emitted Pressed and its Released or Cancelled. Without
    /// it, a chord released during the arming delay would emit a Released with
    /// no Pressed before it.
    open: bool,
}

impl PushToTalk {
    fn new(chord: ModifierChord) -> Self {
        PushToTalk {
            tracker: ChordTracker::new(chord.mask()),
            arm_delay_ms: 0,
            pending_since: None,
            open: false,
        }
    }

    fn retarget(&mut self, chord: ModifierChord) {
        if self.tracker.mask() != chord.mask() {
            self.tracker = ChordTracker::new(chord.mask());
            self.pending_since = None;
            self.open = false;
        }
    }

    fn update(&mut self, flags: u32, now_ms: u64) -> Option<HotkeyEvent> {
        match self.tracker.update(flags) {
            Transition::Pressed => {
                if self.arm_delay_ms == 0 {
                    self.open = true;
                    return Some(HotkeyEvent::Pressed);
                }
                self.pending_since = Some(now_ms);
                None
            }
            Transition::Released => {
                self.pending_since = None;
                if std::mem::take(&mut self.open) {
                    Some(HotkeyEvent::Released)
                } else {
                    // Let go before the delay elapsed: this was a shortcut on
                    // its way past, and nothing ever started.
                    None
                }
            }
            Transition::Cancelled => None,
            Transition::None => {
                let since = self.pending_since?;
                if self.open || now_ms.saturating_sub(since) < self.arm_delay_ms {
                    return None;
                }
                self.pending_since = None;
                self.open = true;
                Some(HotkeyEvent::Pressed)
            }
        }
    }

    fn interrupt(&mut self) -> Option<HotkeyEvent> {
        let cancelled = self.tracker.interrupt() == Transition::Cancelled;
        self.pending_since = None;
        if cancelled && std::mem::take(&mut self.open) {
            Some(HotkeyEvent::Cancelled)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctrl_shift() -> u32 {
        chord::CONTROL | chord::SHIFT
    }

    fn armed(delay: u64) -> PushToTalk {
        let mut p = PushToTalk::new(ModifierChord::default());
        p.arm_delay_ms = delay;
        p
    }

    #[test]
    fn with_no_delay_it_behaves_exactly_like_the_mac() {
        let mut p = armed(0);
        assert_eq!(p.update(ctrl_shift(), 0), Some(HotkeyEvent::Pressed));
        assert_eq!(p.update(ctrl_shift(), 10), None);
        assert_eq!(p.update(0, 20), Some(HotkeyEvent::Released));
    }

    #[test]
    fn the_microphone_waits_for_the_arming_delay() {
        let mut p = armed(250);
        assert_eq!(p.update(ctrl_shift(), 1_000), None, "not yet");
        assert_eq!(p.update(ctrl_shift(), 1_100), None, "still not yet");
        assert_eq!(p.update(ctrl_shift(), 1_260), Some(HotkeyEvent::Pressed));
        assert_eq!(p.update(ctrl_shift(), 1_320), None, "held is not a new press");
        assert_eq!(p.update(0, 1_400), Some(HotkeyEvent::Released));
    }

    /// Ctrl+Shift+Arrow, pressed continuously while selecting text: the chord
    /// goes down and up faster than the delay, and the microphone never opens.
    #[test]
    fn a_chord_released_inside_the_delay_never_starts_anything() {
        let mut p = armed(250);
        assert_eq!(p.update(ctrl_shift(), 0), None);
        assert_eq!(p.update(0, 80), None, "no Released without a Pressed");
        // And the next real hold still works.
        assert_eq!(p.update(ctrl_shift(), 100), None);
        assert_eq!(p.update(ctrl_shift(), 400), Some(HotkeyEvent::Pressed));
    }

    /// Ctrl+Shift+T after the microphone opened: the recording is abandoned,
    /// and holding on does not silently restart it.
    #[test]
    fn a_keystroke_cancels_an_open_recording() {
        let mut p = armed(0);
        assert_eq!(p.update(ctrl_shift(), 0), Some(HotkeyEvent::Pressed));
        assert_eq!(p.interrupt(), Some(HotkeyEvent::Cancelled));
        assert_eq!(p.update(ctrl_shift(), 10), None, "still held must not re-arm");
        assert_eq!(p.update(0, 20), None, "and there is nothing left to release");
        assert_eq!(p.update(ctrl_shift(), 30), Some(HotkeyEvent::Pressed));
    }

    #[test]
    fn a_keystroke_during_the_delay_cancels_silently() {
        let mut p = armed(250);
        assert_eq!(p.update(ctrl_shift(), 0), None);
        assert_eq!(p.interrupt(), None, "nothing had started, so nothing is cancelled");
        assert_eq!(p.update(ctrl_shift(), 500), None, "and it must not arm late");
    }

    #[test]
    fn changing_the_chord_mid_session_re_arms_cleanly() {
        let mut p = armed(0);
        assert_eq!(p.update(ctrl_shift(), 0), Some(HotkeyEvent::Pressed));
        p.retarget(ModifierChord::new(chord::CONTROL | chord::ALT));
        assert_eq!(p.update(ctrl_shift(), 10), None, "the old chord is no longer it");
        assert_eq!(
            p.update(chord::CONTROL | chord::ALT, 20),
            Some(HotkeyEvent::Pressed)
        );
    }

    #[test]
    fn press_and_release_always_alternate() {
        let mut p = armed(0);
        let mut last = HotkeyEvent::Released;
        let sequence = [ctrl_shift(), ctrl_shift(), 0, chord::CONTROL, ctrl_shift(), 0];
        for (i, flags) in sequence.into_iter().enumerate() {
            if let Some(e) = p.update(flags, i as u64 * 10) {
                assert_ne!(e, last, "two {e:?} in a row is a toggle, not push-to-talk");
                last = e;
            }
        }
    }

    #[test]
    fn caps_lock_is_not_typing() {
        assert!(is_modifier(VK_CAPITAL.0 as u32));
        assert!(is_modifier(VK_LSHIFT.0 as u32));
        assert!(!is_modifier(b'T' as u32));
    }
}

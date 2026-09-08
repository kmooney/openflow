//! Everything platform-shaped: the hotkey, insertion, focus, the tray, and the
//! two places we read files Windows owns.
//!
//! The rule that keeps the split honest, carried over from the Swift clients:
//! **if it needs a Win32 call, it goes here; if it does not, it goes in `kit`.**
//! Nothing in this module knows how to dictate.

/// Stamped on every keystroke OpenFlow synthesizes, and checked by the hotkey
/// hook so our own paste is not mistaken for the user typing.
///
/// Checking `LLKHF_INJECTED` instead would have been simpler and wrong: plenty
/// of people type through something that injects -- AutoHotkey, PowerToys
/// Keyboard Manager, a KVM switch, the on-screen keyboard -- and for them every
/// keystroke would look like ours, so Ctrl+Shift+T would record instead of
/// reopening a tab. A signature only we write is the narrow test.
pub const INPUT_SIGNATURE: usize = 0x0F10_0F10;

pub mod browser_history;
pub mod focus;
pub mod hotkey;
pub mod paster;
pub mod playback;
pub mod tray;

//! OpenFlow for Windows.
//!
//! Hold Ctrl+Shift, speak, release; cleaned-up text appears at the cursor in
//! whatever app has focus. Everything runs on this machine.
//!
//! The layering is the one the spec settled on (notes/spec.md 6.0), with the
//! Swift Kit's job done by `kit`:
//!
//! ```text
//! ui + win       hotkey - paste - tray - windows      Windows only
//! kit            audio - whisper - store - engine     this crate
//! openflow-core  formatting - normalize - ledger      every client and server
//! ```
//!
//! Sharing `openflow-core` directly, with no FFI in the way, is why this client
//! is Rust: the Swift clients reach the same code through a C ABI, and a third
//! copy of the formatting rules was never going to stay in step.
//!
//! It is a library as well as a binary so the end-to-end test in `tests/` can
//! drive the real pipeline rather than a copy of it.

pub mod app;
pub mod kit;
pub mod ui;
pub mod win;

/// Our own executable name, so the foreground poll can tell when the user has
/// simply switched to this window.
pub const OUR_EXE: &str = "openflow.exe";

//! The dictation cycle, minus anything platform-shaped.
//!
//! This is the Windows counterpart of `OpenFlowKit` in the Swift clients, and
//! it keeps the same rule: **if it needs a Win32 call, it goes in `win`; if it
//! does not, it goes here.** The layering the spec settled on (6.0) is
//!
//! ```text
//! ui + win       hotkey - paste - tray - windows      Windows only
//! kit            audio - whisper - store - engine     this module
//! openflow-core  formatting - normalize - ledger      every client and server
//! ```
//!
//! with one Windows-specific exception noted in `store.rs`: reading the local
//! time zone needs a system call, and pulling in a date library to avoid one
//! line of `cfg` would be the worse trade.

pub mod audio;
pub mod audio_store;
pub mod chord;
pub mod context;
pub mod denoise;
pub mod domains;
pub mod engine;
pub mod filters;
pub mod formatter;
pub mod models;
pub mod settings;
pub mod store;
pub mod tone;
pub mod tone_memory;
pub mod transcribe;
pub mod vocabulary;
pub mod wake;

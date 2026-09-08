//! A way for a background thread to say "there is something to look at".
//!
//! The app services the hotkey, the engine and any download from the UI
//! thread's tick. Without this, how fast the microphone opens after the chord
//! goes down is decided by how often that tick runs -- so the tick has to be
//! fast, and a tray app that idles at a tenth of a second is burning a
//! measurable slice of a core to do nothing.
//!
//! With it the tick can be lazy and the interesting moments are still
//! immediate. It is a bare closure rather than an `egui::Context` because
//! nothing else in `kit` knows what a UI is.

use std::sync::Mutex;

#[derive(Default)]
pub struct Wake {
    // Set once the UI exists, which is after the threads that hold this have
    // already started. A wake before then is simply dropped: there is nothing
    // yet that could have missed anything.
    inner: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
}

impl Wake {
    pub fn set(&self, f: impl Fn() + Send + Sync + 'static) {
        *self.inner.lock().unwrap() = Some(Box::new(f));
    }

    pub fn wake(&self) {
        if let Some(f) = self.inner.lock().unwrap().as_ref() {
            f();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    #[test]
    fn waking_before_the_ui_exists_is_harmless() {
        let wake = Wake::default();
        wake.wake();
        wake.wake();
    }

    #[test]
    fn every_wake_reaches_the_ui_once_it_is_set() {
        let wake = Arc::new(Wake::default());
        let count = Arc::new(AtomicUsize::new(0));
        let c = count.clone();
        wake.set(move || {
            c.fetch_add(1, Ordering::Relaxed);
        });
        wake.wake();
        wake.wake();
        assert_eq!(count.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn it_can_be_woken_from_another_thread() {
        let wake = Arc::new(Wake::default());
        let count = Arc::new(AtomicUsize::new(0));
        let c = count.clone();
        wake.set(move || {
            c.fetch_add(1, Ordering::Relaxed);
        });
        let w = wake.clone();
        std::thread::spawn(move || w.wake()).join().unwrap();
        assert_eq!(count.load(Ordering::Relaxed), 1);
    }
}

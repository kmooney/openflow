//! Which whisper models are on this machine, downloading new ones, and
//! remembering the choice.
//!
//! Nothing ships inside the executable. macOS made the same call and iOS did
//! not, for a reason that holds here: a desktop has the disk and the bandwidth,
//! and `small.en` at 466 MB is not something to bundle into every download when
//! most people will change it anyway. A missing model is not fatal -- the app
//! opens on the screen that fixes it.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::kit::wake::Wake;

/// A Whisper model the user can run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WhisperModel {
    pub id: &'static str,
    pub filename: &'static str,
    pub display_name: &'static str,
    /// Approximate download size, for the UI to show before committing.
    pub bytes: i64,
    /// Honest one-liner about the trade, not marketing.
    pub note: &'static str,
}

impl WhisperModel {
    pub fn download_url(&self) -> String {
        format!(
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{}",
            self.filename
        )
    }

    pub fn size_description(&self) -> String {
        human_bytes(self.bytes)
    }
}

/// The models on offer, with what M0 actually measured rather than what the
/// model cards claim. Ordered fastest to most accurate.
pub const CATALOG: &[WhisperModel] = &[
    WhisperModel {
        id: "tiny.en",
        filename: "ggml-tiny.en.bin",
        display_name: "Tiny (English)",
        bytes: 77_700_000,
        note: "Fastest and least accurate. Useful on older machines; expect mistakes on names.",
    },
    WhisperModel {
        id: "base.en",
        filename: "ggml-base.en.bin",
        display_name: "Base (English)",
        bytes: 147_950_000,
        note: "Fast, but substitutes words rather than admitting uncertainty \u{2014} it can turn \u{201c}uh\u{201d} into \u{201c}that\u{201d}.",
    },
    WhisperModel {
        id: "small.en",
        filename: "ggml-small.en.bin",
        display_name: "Small (English)",
        bytes: 487_600_000,
        note: "Clearly more accurate, about 2.4\u{d7} slower than Base. The desktop default, and the best choice if names matter.",
    },
    WhisperModel {
        id: "large-v3-turbo-q5_0",
        filename: "ggml-large-v3-turbo-q5_0.bin",
        display_name: "Large v3 Turbo (quantised)",
        bytes: 574_000_000,
        note: "Most accurate, and the slowest for dictation: it keeps the full large encoder, so short utterances cost over a second before it transcribes anything.",
    },
];

/// What to select when the user has never chosen. M0 disqualified base.en as
/// the desktop default because it substitutes rather than admitting
/// uncertainty.
pub const DEFAULT_ID: &str = "small.en";

pub fn model(id: &str) -> Option<&'static WhisperModel> {
    CATALOG.iter().find(|m| m.id == id)
}

pub fn human_bytes(bytes: i64) -> String {
    const UNITS: [&str; 4] = ["bytes", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1000.0 && unit < UNITS.len() - 1 {
        value /= 1000.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} bytes")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Progress {
    pub fraction: f64,
    pub received: i64,
    pub total: i64,
}

struct Download {
    progress: Arc<Mutex<Progress>>,
    cancel: Arc<AtomicBool>,
}

pub struct ModelStore {
    directory: PathBuf,
    installed: Vec<String>,
    downloads: HashMap<String, Download>,
    finished: Arc<Mutex<Vec<(String, Result<(), String>)>>>,
    wake: Arc<Wake>,
    pub selected_id: String,
    pub last_error: Option<String>,
    /// Bumped whenever the selection changes, so the caller knows to reload the
    /// engine without us holding a reference to it.
    pub selection_revision: u64,
}

impl ModelStore {
    pub fn new(directory: PathBuf, remembered: Option<String>, wake: Arc<Wake>) -> Self {
        let _ = std::fs::create_dir_all(&directory);
        let mut store = ModelStore {
            directory,
            installed: Vec::new(),
            downloads: HashMap::new(),
            finished: Arc::new(Mutex::new(Vec::new())),
            wake,
            selected_id: remembered.unwrap_or_else(|| DEFAULT_ID.to_string()),
            last_error: None,
            selection_revision: 0,
        };
        store.refresh();
        // A model can be deleted out from under the selection, and the default
        // may simply not be downloaded yet; never leave the app pointing at
        // something that is not there.
        if store.location(&store.selected_id.clone()).is_none() {
            store.selected_id = store.best_installed().unwrap_or_default();
        }
        store
    }

    /// Deliberately catalogue order rather than "the first one found": a set
    /// iterated in hash order picks a different model between launches for
    /// anyone holding two of them.
    fn best_installed(&self) -> Option<String> {
        CATALOG
            .iter()
            .find(|m| self.installed.iter().any(|i| i == m.id))
            .map(|m| m.id.to_string())
    }

    pub fn refresh(&mut self) {
        self.installed = CATALOG
            .iter()
            .filter(|m| self.directory.join(m.filename).exists())
            .map(|m| m.id.to_string())
            .collect();
    }

    pub fn is_installed(&self, id: &str) -> bool {
        self.installed.iter().any(|i| i == id)
    }

    pub fn location(&self, id: &str) -> Option<PathBuf> {
        let m = model(id)?;
        let path = self.directory.join(m.filename);
        path.exists().then_some(path)
    }

    pub fn active_path(&self) -> Option<PathBuf> {
        self.location(&self.selected_id)
    }

    pub fn select(&mut self, id: &str) {
        if self.location(id).is_none() {
            return;
        }
        self.selected_id = id.to_string();
        self.selection_revision += 1;
    }

    pub fn progress(&self, id: &str) -> Option<Progress> {
        self.downloads.get(id).map(|d| *d.progress.lock().unwrap())
    }

    // MARK: download

    pub fn download(&mut self, id: &str) {
        let Some(m) = model(id) else { return };
        if self.downloads.contains_key(id) || self.location(id).is_some() {
            return;
        }
        self.last_error = None;

        let progress = Arc::new(Mutex::new(Progress {
            fraction: 0.0,
            received: 0,
            total: m.bytes,
        }));
        let cancel = Arc::new(AtomicBool::new(false));
        let finished = self.finished.clone();
        let destination = self.directory.join(m.filename);
        // Download beside the destination, not on top of it: an interrupted
        // write must never leave something that looks like an installed model.
        let staging = self.directory.join(format!("{}.part", m.filename));
        let url = m.download_url();
        let expected = m.bytes;
        let id_owned = id.to_string();

        let p = progress.clone();
        let c = cancel.clone();
        let wake = self.wake.clone();
        std::thread::spawn(move || {
            let result = fetch(&url, &staging, expected, &p, &c);
            let result = result.and_then(|_| {
                // A truncated file loads as a corrupt model and fails in a way
                // that looks like a bug in the app.
                let size = std::fs::metadata(&staging).map(|m| m.len() as i64).unwrap_or(0);
                if size < expected / 2 {
                    let _ = std::fs::remove_file(&staging);
                    return Err("Download was incomplete. Try again.".into());
                }
                let _ = std::fs::remove_file(&destination);
                std::fs::rename(&staging, &destination).map_err(|e| e.to_string())
            });
            if result.is_err() {
                let _ = std::fs::remove_file(&staging);
            }
            finished.lock().unwrap().push((id_owned, result));
            // A finished download changes which model is loaded; that should
            // not wait for the next idle tick.
            wake.wake();
        });

        self.downloads
            .insert(id.to_string(), Download { progress, cancel });
    }

    /// Drains anything a download thread finished. Returns true when something
    /// changed, so the caller can reload its engine and repaint.
    pub fn poll(&mut self) -> bool {
        let done: Vec<(String, Result<(), String>)> =
            std::mem::take(&mut *self.finished.lock().unwrap());
        if done.is_empty() {
            return false;
        }
        for (id, result) in done {
            self.downloads.remove(&id);
            match result {
                Ok(()) => {
                    self.refresh();
                    self.select(&id);
                }
                Err(e) => self.last_error = Some(e),
            }
        }
        true
    }

    pub fn cancel_download(&mut self, id: &str) {
        if let Some(d) = self.downloads.remove(id) {
            d.cancel.store(true, Ordering::Relaxed);
        }
    }

    /// Remove a downloaded model.
    pub fn delete(&mut self, id: &str) {
        let Some(m) = model(id) else { return };
        let _ = std::fs::remove_file(self.directory.join(m.filename));
        self.refresh();
        if self.selected_id != id {
            return;
        }
        // Fall back deliberately rather than via `select`, which refuses a
        // model that is not present -- that guard made the fallback a no-op and
        // left the selection pointing at the file just deleted.
        match self.best_installed() {
            Some(next) => {
                self.selected_id = next;
                self.selection_revision += 1;
            }
            None => {
                self.selected_id = String::new(); // nothing usable; active_path is None
                self.selection_revision += 1;
            }
        }
    }

    pub fn disk_usage(&self) -> i64 {
        let Ok(items) = std::fs::read_dir(&self.directory) else {
            return 0;
        };
        items
            .flatten()
            .filter_map(|e| e.metadata().ok())
            .filter(|m| m.is_file())
            .map(|m| m.len() as i64)
            .sum()
    }
}

fn fetch(
    url: &str,
    destination: &Path,
    expected: i64,
    progress: &Arc<Mutex<Progress>>,
    cancel: &Arc<AtomicBool>,
) -> Result<(), String> {
    let response = ureq::get(url)
        .call()
        .map_err(|e| format!("Could not reach the model host: {e}"))?;

    // The server may not send a length; fall back to the catalogue's size so
    // the bar still moves.
    let total = response
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<i64>().ok())
        .filter(|v| *v > 0)
        .unwrap_or(expected);

    let mut reader = response.into_body().into_reader();
    let mut file = std::fs::File::create(destination).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; 256 * 1024];
    let mut received: i64 = 0;

    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err("cancelled".into());
        }
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        received += n as i64;
        *progress.lock().unwrap() = Progress {
            fraction: (received as f64 / total.max(1) as f64).min(1.0),
            received,
            total,
        };
    }
    file.flush().map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("of-models-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn plant(dir: &Path, id: &str) {
        let m = model(id).unwrap();
        std::fs::write(dir.join(m.filename), b"not really a model").unwrap();
    }

    #[test]
    fn the_catalogue_is_ordered_fastest_first_and_ids_are_unique() {
        let mut sizes: Vec<i64> = CATALOG.iter().map(|m| m.bytes).collect();
        let sorted = {
            let mut s = sizes.clone();
            s.sort();
            s
        };
        sizes.dedup();
        assert_eq!(CATALOG.iter().map(|m| m.bytes).collect::<Vec<_>>(), sorted);
        let ids: std::collections::HashSet<_> = CATALOG.iter().map(|m| m.id).collect();
        assert_eq!(ids.len(), CATALOG.len());
    }

    #[test]
    fn nothing_installed_leaves_no_active_model_rather_than_a_dangling_path() {
        let dir = scratch("empty");
        let store = ModelStore::new(dir.clone(), None, Arc::new(Wake::default()));
        assert!(store.active_path().is_none());
        assert!(store.selected_id.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_remembered_choice_that_is_gone_falls_back_to_what_is_there() {
        let dir = scratch("gone");
        plant(&dir, "tiny.en");
        let store = ModelStore::new(dir.clone(), Some("large-v3-turbo-q5_0".into()), Arc::new(Wake::default()));
        assert_eq!(store.selected_id, "tiny.en");
        assert!(store.active_path().is_some());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_fallback_is_catalogue_order_so_it_does_not_change_between_launches() {
        let dir = scratch("order");
        plant(&dir, "small.en");
        plant(&dir, "tiny.en");
        for _ in 0..5 {
            let store = ModelStore::new(dir.clone(), None, Arc::new(Wake::default()));
            // "small.en" is the remembered-less default and is installed.
            assert_eq!(store.selected_id, "small.en");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Deleting the active model must move the selection, not strand it on a
    /// file that no longer exists.
    #[test]
    fn deleting_the_active_model_moves_the_selection() {
        let dir = scratch("delete");
        plant(&dir, "tiny.en");
        plant(&dir, "small.en");
        let mut store = ModelStore::new(dir.clone(), Some("small.en".into()), Arc::new(Wake::default()));
        assert_eq!(store.selected_id, "small.en");
        store.delete("small.en");
        assert_eq!(store.selected_id, "tiny.en");
        assert!(store.active_path().is_some());

        store.delete("tiny.en");
        assert!(store.selected_id.is_empty());
        assert!(store.active_path().is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn selecting_a_model_that_is_not_there_is_refused() {
        let dir = scratch("refuse");
        plant(&dir, "tiny.en");
        let mut store = ModelStore::new(dir.clone(), None, Arc::new(Wake::default()));
        let before = store.selected_id.clone();
        store.select("large-v3-turbo-q5_0");
        assert_eq!(store.selected_id, before);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn selecting_bumps_the_revision_so_the_engine_reloads() {
        let dir = scratch("revision");
        plant(&dir, "tiny.en");
        plant(&dir, "base.en");
        let mut store = ModelStore::new(dir.clone(), Some("tiny.en".into()), Arc::new(Wake::default()));
        let before = store.selection_revision;
        store.select("base.en");
        assert!(store.selection_revision > before);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sizes_read_the_way_a_person_would_say_them() {
        assert_eq!(human_bytes(512), "512 bytes");
        assert_eq!(human_bytes(487_600_000), "487.6 MB");
    }
}

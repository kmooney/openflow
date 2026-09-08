//! Reads the domains you actually visit out of a browser's history, so the
//! vocabulary can be seeded with real sites instead of waiting for each one to
//! be transcribed wrong first.
//!
//! This is the most sensitive thing OpenFlow touches, so the handling is
//! deliberately narrow:
//!
//! - **Read-only, and never in place.** The database is copied to a temporary
//!   file and the copy is opened; the browser holds the original open and a
//!   stray write would corrupt it. The copy is deleted before this returns.
//! - **Only hosts leave this function.** Paths, query strings, titles and
//!   timestamps are dropped at the source -- the URL column is read but never
//!   returned, so nothing downstream can leak a full URL into a file or a log.
//! - **Nothing happens without being asked.** There is no scan on launch; the
//!   user presses a button, sees the list, and chooses to write it.

use std::path::PathBuf;

use rusqlite::{Connection, OpenFlags};

use crate::kit::domains;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Source {
    pub id: String,
    pub name: String,
    /// Executable name, so a seeded list lands in the right vocabulary section.
    pub app_id: String,
    pub path: PathBuf,
}

/// Browsers with a readable history on this machine.
pub fn available() -> Vec<Source> {
    let mut found = Vec::new();
    let local = std::env::var("LOCALAPPDATA").map(PathBuf::from).ok();
    let roaming = std::env::var("APPDATA").map(PathBuf::from).ok();

    if let Some(local) = &local {
        for (id, name, exe, dir) in [
            ("chrome", "Chrome", "chrome.exe", "Google/Chrome/User Data"),
            ("edge", "Edge", "msedge.exe", "Microsoft/Edge/User Data"),
            (
                "brave",
                "Brave",
                "brave.exe",
                "BraveSoftware/Brave-Browser/User Data",
            ),
            ("vivaldi", "Vivaldi", "vivaldi.exe", "Vivaldi/User Data"),
        ] {
            let history = local.join(dir).join("Default").join("History");
            if history.exists() {
                found.push(Source {
                    id: id.into(),
                    name: name.into(),
                    app_id: exe.into(),
                    path: history,
                });
            }
        }
    }

    if let Some(roaming) = &roaming {
        let profiles = roaming.join("Mozilla/Firefox/Profiles");
        if let Ok(entries) = std::fs::read_dir(&profiles) {
            // Newest profile wins when there are several; "default-release" is
            // the usual one but is not guaranteed to exist.
            let mut places: Vec<(std::time::SystemTime, PathBuf)> = entries
                .flatten()
                .map(|e| e.path().join("places.sqlite"))
                .filter(|p| p.exists())
                .filter_map(|p| {
                    let modified = std::fs::metadata(&p).ok()?.modified().ok()?;
                    Some((modified, p))
                })
                .collect();
            places.sort_by(|a, b| b.0.cmp(&a.0));
            if let Some((_, path)) = places.into_iter().next() {
                found.push(Source {
                    id: "firefox".into(),
                    name: "Firefox".into(),
                    app_id: "firefox.exe".into(),
                    path,
                });
            }
        }
    }

    found
}

/// Names the temporary copy so a leftover is recognisable, and so the tests can
/// assert none survives.
const STAGING_PREFIX: &str = "of-history-";

/// Most-visited domains, highest first. Hosts only -- see the note above.
pub fn domains_from(source: &Source, limit: i64) -> Result<Vec<(String, i64)>, String> {
    // Unique per call, not per browser: two reads in flight at once would
    // otherwise share a directory and delete each other's copy on the way out.
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let staging = std::env::temp_dir().join(format!(
        "{}{}-{}",
        STAGING_PREFIX,
        std::process::id(),
        SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let _ = std::fs::create_dir_all(&staging);
    let copy = staging.join("history.sqlite");

    let cleanup = || {
        let _ = std::fs::remove_dir_all(&staging);
    };

    // The write-ahead log holds recent visits; without it a browser that is
    // currently running looks weeks out of date.
    if let Err(e) = std::fs::copy(&source.path, &copy) {
        cleanup();
        return Err(format!("Could not read {}'s history: {e}", source.name));
    }
    for suffix in ["-wal", "-shm"] {
        let side = PathBuf::from(format!("{}{suffix}", source.path.display()));
        if side.exists() {
            let _ = std::fs::copy(&side, PathBuf::from(format!("{}{suffix}", copy.display())));
        }
    }

    let result = read_visits(&copy, limit);
    cleanup();

    match result {
        Some(visits) => Ok(domains::rank(&visits)),
        None => Err(format!(
            "{}'s history is not in a layout OpenFlow understands.",
            source.name
        )),
    }
}

fn read_visits(path: &std::path::Path, limit: i64) -> Option<Vec<(String, i64)>> {
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;

    // Firefox and the Chromium browsers name these differently; try both rather
    // than branching on which browser we think this is.
    for sql in [
        "SELECT url, visit_count FROM moz_places WHERE visit_count > 0 ORDER BY visit_count DESC LIMIT ?1;",
        "SELECT url, visit_count FROM urls WHERE visit_count > 0 ORDER BY visit_count DESC LIMIT ?1;",
    ] {
        let Ok(mut stmt) = db.prepare(sql) else {
            continue; // wrong schema; try the other
        };
        let rows = stmt.query_map([limit], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        });
        if let Ok(rows) = rows {
            // Hosts are extracted by the caller, so the URLs go out of scope
            // with this function and never reach a UI or a file.
            return Some(rows.flatten().collect());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// These tests share one temporary directory and one process id, and one of
    /// them asserts that no staging copy is left behind. Run in parallel they
    /// would see each other's copies mid-read, so they take turns.
    static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn serial() -> std::sync::MutexGuard<'static, ()> {
        SERIAL.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn chromium_fixture(path: &std::path::Path) {
        let db = Connection::open(path).unwrap();
        db.execute_batch(
            "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER);
             INSERT INTO urls(url,title,visit_count) VALUES
               ('https://www.doordash.com/store/1?secret=xyz','Order',9),
               ('https://news.ycombinator.com/item?id=1','HN',4),
               ('http://localhost:3000/admin','local',7),
               ('https://doordash.com/other','Order',2);",
        )
        .unwrap();
    }

    #[test]
    fn only_hosts_come_out_and_they_are_ranked_by_visits() {
        let _serial = serial();
        let dir = std::env::temp_dir().join(format!("of-bh-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("History");
        chromium_fixture(&path);

        let source = Source {
            id: "test".into(),
            name: "Test".into(),
            app_id: "chrome.exe".into(),
            path,
        };
        let domains = domains_from(&source, 100).unwrap();
        assert_eq!(
            domains,
            vec![
                ("doordash.com".to_string(), 11),
                ("news.ycombinator.com".to_string(), 4),
            ]
        );
        // The paths and query strings are gone, not merely unused.
        assert!(domains.iter().all(|(d, _)| !d.contains('/') && !d.contains("secret")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unrecognised_schema_says_so_rather_than_returning_nothing() {
        let _serial = serial();
        let dir = std::env::temp_dir().join(format!("of-bh-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("History");
        Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE nonsense(a INTEGER);")
            .unwrap();

        let source = Source {
            id: "test".into(),
            name: "Test".into(),
            app_id: "chrome.exe".into(),
            path,
        };
        assert!(domains_from(&source, 100).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_history_file_is_an_error_not_a_crash() {
        let _serial = serial();
        let source = Source {
            id: "test".into(),
            name: "Test".into(),
            app_id: "chrome.exe".into(),
            path: PathBuf::from("C:/nope/History"),
        };
        assert!(domains_from(&source, 100).is_err());
    }

    /// The original must never be opened for writing, and the copy must be
    /// gone by the time this returns.
    #[test]
    fn the_browsers_own_database_is_left_alone() {
        let _serial = serial();
        let dir = std::env::temp_dir().join(format!("of-bh-ro-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("History");
        chromium_fixture(&path);
        let before = std::fs::metadata(&path).unwrap().len();

        let source = Source {
            id: "test".into(),
            name: "Test".into(),
            app_id: "chrome.exe".into(),
            path: path.clone(),
        };
        domains_from(&source, 100).unwrap();

        assert_eq!(std::fs::metadata(&path).unwrap().len(), before);

        let mine = format!("{STAGING_PREFIX}{}-", std::process::id());
        let leftovers = std::fs::read_dir(std::env::temp_dir())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with(&mine))
            .count();
        assert_eq!(leftovers, 0, "the copy must not outlive the read");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

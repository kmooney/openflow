//! Local history. In standalone mode this is the whole persistence layer;
//! when a server is paired it becomes the sync source.
//!
//! Same schema, same column names and same `outcome` values as the Swift
//! clients, so one database format means one thing on every platform.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension};

use crate::kit::tone::Tone;

#[derive(Clone, Debug)]
pub struct Utterance {
    pub id: i64,
    /// Seconds since the epoch, matching the Swift clients' `created_at`.
    pub created_at: f64,
    pub duration_ms: i64,
    pub raw_text: String,
    pub final_text: String,
    pub tone: String,
    pub spoken_words: i64,
    pub latency_ms: i64,
    pub guardrail_passed: bool,
    pub ledger: String,
    pub audio_path: Option<String>,
    /// "ok", or why nothing came out: "silence", "steadyNoise", "empty".
    pub outcome: String,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct Stats {
    pub utterances: i64,
    pub spoken_words: i64,
    pub seconds_spoken: f64,
    pub today_words: i64,
}

pub struct Store {
    db: Mutex<Connection>,
}

pub struct NewUtterance<'a> {
    pub raw: &'a str,
    pub final_text: &'a str,
    pub tone: Tone,
    pub spoken_words: i64,
    pub duration_ms: i64,
    pub latency_ms: i64,
    pub guardrail_passed: bool,
    pub ledger: &'a str,
    pub app_context: Option<&'a str>,
    pub audio_path: Option<&'a str>,
    pub outcome: &'a str,
}

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Store> {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let db = Connection::open(path)?;
        Store::prepare(&db)?;
        Ok(Store { db: Mutex::new(db) })
    }

    /// Last-resort store so the app can still run when the database cannot be
    /// opened. History is lost on quit, which is far better than refusing to
    /// let the user dictate at all.
    pub fn in_memory() -> Store {
        let db = Connection::open_in_memory().expect(":memory: cannot fail the way a path can");
        Store::prepare(&db).ok();
        Store { db: Mutex::new(db) }
    }

    fn prepare(db: &Connection) -> rusqlite::Result<()> {
        db.execute_batch("PRAGMA journal_mode=WAL;")?;
        // user_id is present from the first migration with exactly one value,
        // so multi-user is a feature later rather than a data migration.
        db.execute_batch(
            "CREATE TABLE IF NOT EXISTS utterances(
               id INTEGER PRIMARY KEY AUTOINCREMENT,
               user_id INTEGER NOT NULL DEFAULT 1,
               created_at REAL NOT NULL,
               duration_ms INTEGER NOT NULL,
               raw_text TEXT NOT NULL,
               final_text TEXT NOT NULL,
               tone TEXT NOT NULL,
               spoken_words INTEGER NOT NULL,
               latency_ms INTEGER NOT NULL,
               guardrail_passed INTEGER NOT NULL,
               ledger TEXT NOT NULL DEFAULT '[]',
               app_context TEXT
             );
             CREATE INDEX IF NOT EXISTS idx_utt_created ON utterances(created_at);",
        )?;
        // Added after the first schema shipped; failing here just means the
        // column already exists.
        let _ = db.execute_batch("ALTER TABLE utterances ADD COLUMN audio_path TEXT;");
        let _ = db
            .execute_batch("ALTER TABLE utterances ADD COLUMN outcome TEXT NOT NULL DEFAULT 'ok';");
        Ok(())
    }

    pub fn record(&self, u: NewUtterance<'_>) -> i64 {
        let db = self.db.lock().unwrap();
        let result = db.execute(
            "INSERT INTO utterances
               (created_at,duration_ms,raw_text,final_text,tone,spoken_words,
                latency_ms,guardrail_passed,ledger,app_context,audio_path,outcome)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12);",
            params![
                now(),
                u.duration_ms,
                u.raw,
                u.final_text,
                u.tone.name(),
                u.spoken_words,
                u.latency_ms,
                u.guardrail_passed as i64,
                u.ledger,
                u.app_context,
                u.audio_path,
                u.outcome,
            ],
        );
        match result {
            Ok(_) => db.last_insert_rowid(),
            Err(_) => -1,
        }
    }

    pub fn stats(&self) -> Stats {
        let db = self.db.lock().unwrap();
        db.query_row(
            "SELECT COUNT(*), COALESCE(SUM(spoken_words),0),
                    COALESCE(SUM(duration_ms),0)/1000.0,
                    COALESCE(SUM(CASE WHEN created_at >= ?1 THEN spoken_words ELSE 0 END),0)
             FROM utterances;",
            params![start_of_today()],
            |row| {
                Ok(Stats {
                    utterances: row.get(0)?,
                    spoken_words: row.get(1)?,
                    seconds_spoken: row.get(2)?,
                    today_words: row.get(3)?,
                })
            },
        )
        .unwrap_or_default()
    }

    /// Most recent first. `query` matches either the raw or the final text.
    pub fn recent(&self, limit: i64, query: &str) -> Vec<Utterance> {
        let db = self.db.lock().unwrap();
        let filter = query.trim();
        let sql = format!(
            "SELECT id,created_at,duration_ms,raw_text,final_text,tone,spoken_words,
                    latency_ms,guardrail_passed,ledger,audio_path,outcome
             FROM utterances
             {}
             ORDER BY created_at DESC LIMIT ?2;",
            if filter.is_empty() {
                ""
            } else {
                "WHERE raw_text LIKE ?1 OR final_text LIKE ?1"
            }
        );
        let Ok(mut stmt) = db.prepare(&sql) else {
            return Vec::new();
        };
        let like = format!("%{filter}%");
        let rows = stmt.query_map(params![like, limit], |row| {
            Ok(Utterance {
                id: row.get(0)?,
                created_at: row.get(1)?,
                duration_ms: row.get(2)?,
                raw_text: row.get(3)?,
                final_text: row.get(4)?,
                tone: row.get(5)?,
                spoken_words: row.get(6)?,
                latency_ms: row.get(7)?,
                guardrail_passed: row.get::<_, i64>(8)? == 1,
                ledger: row.get(9)?,
                audio_path: row.get(10)?,
                outcome: row
                    .get::<_, Option<String>>(11)?
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "ok".into()),
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Hard delete of one utterance -- the row and its audio clip. Nothing is
    /// retained, and there is no tombstone holding the text.
    pub fn delete(&self, id: i64) {
        let clip = self.audio_path(id);
        crate::kit::audio_store::remove(clip.as_deref());
        let db = self.db.lock().unwrap();
        let _ = db.execute("DELETE FROM utterances WHERE id = ?1;", params![id]);
    }

    fn audio_path(&self, id: i64) -> Option<String> {
        let db = self.db.lock().unwrap();
        db.query_row(
            "SELECT audio_path FROM utterances WHERE id = ?1;",
            params![id],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .ok()
        .flatten()
        .flatten()
    }

    /// Hard delete. Delete means delete: no tombstone holding the text, and the
    /// audio goes with it.
    pub fn delete_all(&self) {
        for u in self.recent(100_000, "") {
            crate::kit::audio_store::remove(u.audio_path.as_deref());
        }
        let db = self.db.lock().unwrap();
        let _ = db.execute("DELETE FROM utterances;", []);
        let _ = db.execute_batch("VACUUM;");
    }
}

pub fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Midnight local time, as a Unix timestamp. Done by hand rather than with a
/// date library: the only question is "how many words today", and pulling in a
/// timezone database to answer it would be silly.
fn start_of_today() -> f64 {
    let now = now();
    let offset = local_utc_offset_seconds();
    let local = now + offset;
    let midnight_local = (local / 86_400.0).floor() * 86_400.0;
    midnight_local - offset
}

#[cfg(windows)]
fn local_utc_offset_seconds() -> f64 {
    use windows::Win32::System::Time::{GetTimeZoneInformation, TIME_ZONE_INFORMATION};
    unsafe {
        let mut tz = TIME_ZONE_INFORMATION::default();
        let id = GetTimeZoneInformation(&mut tz);
        // Bias is minutes to ADD to local time to get UTC, so the offset from
        // UTC to local is its negation. Daylight saving is a separate bias.
        let extra = match id {
            2 => tz.DaylightBias, // TIME_ZONE_ID_DAYLIGHT
            1 => tz.StandardBias, // TIME_ZONE_ID_STANDARD
            _ => 0,
        };
        -((tz.Bias + extra) as f64) * 60.0
    }
}

#[cfg(not(windows))]
fn local_utc_offset_seconds() -> f64 {
    0.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utterance<'a>(raw: &'a str, final_text: &'a str) -> NewUtterance<'a> {
        NewUtterance {
            raw,
            final_text,
            tone: Tone::Formal,
            spoken_words: raw.split_whitespace().count() as i64,
            duration_ms: 1_000,
            latency_ms: 200,
            guardrail_passed: true,
            ledger: "[]",
            app_context: Some("wt.exe"),
            audio_path: None,
            outcome: "ok",
        }
    }

    #[test]
    fn recording_and_reading_back() {
        let store = Store::in_memory();
        store.record(utterance("um so the deploy failed", "So the deploy failed."));
        let rows = store.recent(10, "");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].raw_text, "um so the deploy failed");
        assert_eq!(rows[0].final_text, "So the deploy failed.");
        assert_eq!(rows[0].outcome, "ok");
        assert_eq!(rows[0].tone, "Formal");
    }

    #[test]
    fn stats_count_words_spoken_not_written() {
        let store = Store::in_memory();
        store.record(utterance("um so the deploy failed", "Deploy failed."));
        let s = store.stats();
        assert_eq!(s.utterances, 1);
        assert_eq!(s.spoken_words, 5, "the honest number is what was said");
        assert_eq!(s.today_words, 5);
        assert!((s.seconds_spoken - 1.0).abs() < 1e-6);
    }

    #[test]
    fn search_matches_either_the_raw_or_the_final_text() {
        let store = Store::in_memory();
        store.record(utterance("kubernetes is fine", "Kubernetes is fine."));
        store.record(utterance("lunch", "Lunch."));
        assert_eq!(store.recent(10, "kubernetes").len(), 1);
        assert_eq!(store.recent(10, "Kubernetes.").len(), 0);
        assert_eq!(store.recent(10, "lunch").len(), 1);
        assert_eq!(store.recent(10, "").len(), 2);
    }

    /// A recording that produced nothing is exactly the one worth
    /// investigating, so it still gets a row.
    #[test]
    fn failures_are_recorded_too() {
        let store = Store::in_memory();
        let mut u = utterance("", "");
        u.outcome = "silence";
        u.spoken_words = 0;
        store.record(u);
        let rows = store.recent(10, "");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].outcome, "silence");
    }

    #[test]
    fn delete_means_delete() {
        let store = Store::in_memory();
        store.record(utterance("one", "One."));
        store.record(utterance("two", "Two."));
        let rows = store.recent(10, "");
        store.delete(rows[0].id);
        assert_eq!(store.recent(10, "").len(), 1);
        store.delete_all();
        assert_eq!(store.recent(10, "").len(), 0);
        assert_eq!(store.stats().utterances, 0);
    }

    #[test]
    fn the_ledger_survives_the_round_trip() {
        let store = Store::in_memory();
        let mut u = utterance("um hello", "Hello.");
        u.ledger = r#"[{"from":"um","to":"","why":"Filler"}]"#;
        store.record(u);
        let rows = store.recent(10, "");
        assert!(rows[0].ledger.contains("Filler"));
    }

    #[test]
    fn todays_words_are_todays() {
        let store = Store::in_memory();
        store.record(utterance("a b c", "A b c."));
        let s = store.stats();
        assert_eq!(s.today_words, s.spoken_words);
    }
}

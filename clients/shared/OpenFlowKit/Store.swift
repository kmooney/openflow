import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct Utterance: Sendable {
    public let id: Int64
    public let createdAt: Date
    public let durationMS: Int
    public let rawText: String
    public let finalText: String
    public let tone: String
    public let spokenWords: Int
    public let latencyMS: Int
    public let guardrailPassed: Bool
    public let ledger: String
    public let audioPath: String?
    /// "ok", or why nothing came out: "no-speech", "empty".
    public let outcome: String
    /// Which models produced this. Stored per utterance rather than read from
    /// current settings, because the settings are the ones in force *now* and
    /// the whole point of history is what was true then.
    public let speechModel: String
    public let polishModel: String
    /// What the polish model returned, when it changed anything. The middle of
    /// the pipeline, kept so the history can show all three stages rather than
    /// just the ends.
    public let polishedText: String
    /// Seconds into the recording at which each paragraph break fell, comma
    /// separated. The audit line shows them, so a break in the wrong place can
    /// be traced to the pause that caused it.
    public let breakTimes: String
}

public struct Stats: Sendable {
    public let utterances: Int
    public let spokenWords: Int
    public let secondsSpoken: Double
    public let todayWords: Int
    /// Total milliseconds spent transcribing, across every successful
    /// utterance. Paired with `secondsTranscribed` it gives a throughput the
    /// user can actually feel, rather than a number only a profiler likes.
    public let latencyMS: Int
    /// Seconds of audio those milliseconds covered.
    public let secondsTranscribed: Double

    /// How much faster than real time the machine transcribes. A 10-second
    /// utterance handled in two seconds is 5x.
    public var realtimeFactor: Double {
        latencyMS > 0 ? secondsTranscribed / (Double(latencyMS) / 1000) : 0
    }

    /// Words produced per minute of work. Per minute rather than per second
    /// because dictation is measured against typing, and nobody knows their
    /// own words per second.
    public var wordsPerMinute: Double {
        latencyMS > 0 ? Double(spokenWords) / (Double(latencyMS) / 1000) * 60 : 0
    }
}

/// Local history. On macOS this is the whole persistence layer (standalone
/// mode); when a server is paired it becomes the sync source.
public final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "openflow.store")

    public init(path: String) throws {
        if path != ":memory:" {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "openflow.store", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "could not open \(path)"])
        }
        exec("PRAGMA journal_mode=WAL;")
        // user_id is present from the first migration with exactly one row, so
        // multi-user is a feature later rather than a data migration.
        exec("""
        CREATE TABLE IF NOT EXISTS utterances(
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
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_utt_created ON utterances(created_at);")
        // Added after the first schema shipped; failing here just means the
        // column already exists.
        exec("ALTER TABLE utterances ADD COLUMN audio_path TEXT;")
        exec("ALTER TABLE utterances ADD COLUMN outcome TEXT NOT NULL DEFAULT 'ok';")
        exec("ALTER TABLE utterances ADD COLUMN speech_model TEXT NOT NULL DEFAULT '';")
        exec("ALTER TABLE utterances ADD COLUMN polish_model TEXT NOT NULL DEFAULT '';")
        exec("ALTER TABLE utterances ADD COLUMN polished_text TEXT NOT NULL DEFAULT '';")
        exec("ALTER TABLE utterances ADD COLUMN break_times TEXT NOT NULL DEFAULT '';")
    }

    deinit { if let db { sqlite3_close(db) } }

    /// Last-resort store so the app can still run when the database cannot be
    /// opened. History is lost on quit, which is far better than refusing to
    /// let the user dictate at all.
    public static func inMemory() -> Store {
        // ":memory:" cannot fail the way a file path can.
        try! Store(path: ":memory:")
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    @discardableResult
    public func record(raw: String, final: String, tone: Tone, spokenWords: Int,
                       speechModel: String = "", polishModel: String = "",
                       polishedText: String = "", breakTimes: String = "",
                       durationMS: Int, latencyMS: Int, guardrailPassed: Bool,
                       ledger: String, appContext: String?, audioPath: String? = nil,
                       outcome: String = "ok") -> Int64 {
        queue.sync {
            let sql = """
            INSERT INTO utterances
              (created_at,duration_ms,raw_text,final_text,tone,spoken_words,
               latency_ms,guardrail_passed,ledger,app_context,audio_path,outcome,
               speech_model,polish_model,polished_text,break_times)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_double(st, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int(st, 2, Int32(durationMS))
            sqlite3_bind_text(st, 3, raw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 4, final, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 5, tone.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(st, 6, Int32(spokenWords))
            sqlite3_bind_int(st, 7, Int32(latencyMS))
            sqlite3_bind_int(st, 8, guardrailPassed ? 1 : 0)
            sqlite3_bind_text(st, 9, ledger, -1, SQLITE_TRANSIENT)
            if let appContext {
                sqlite3_bind_text(st, 10, appContext, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(st, 10)
            }
            if let audioPath {
                sqlite3_bind_text(st, 11, audioPath, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(st, 11)
            }
            sqlite3_bind_text(st, 12, outcome, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 13, speechModel, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 14, polishModel, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 15, polishedText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(st, 16, breakTimes, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(st) == SQLITE_DONE else { return -1 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func stats() -> Stats {
        queue.sync {
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let sql = """
            SELECT COUNT(*), COALESCE(SUM(spoken_words),0), COALESCE(SUM(duration_ms),0)/1000.0,
                   COALESCE(SUM(CASE WHEN created_at >= ? THEN spoken_words ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN outcome='ok' THEN latency_ms ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN outcome='ok' THEN duration_ms ELSE 0 END),0)/1000.0
            FROM utterances;
            """
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                return Stats(utterances: 0, spokenWords: 0, secondsSpoken: 0, todayWords: 0,
                             latencyMS: 0, secondsTranscribed: 0)
            }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_double(st, 1, startOfDay)
            guard sqlite3_step(st) == SQLITE_ROW else {
                return Stats(utterances: 0, spokenWords: 0, secondsSpoken: 0, todayWords: 0,
                             latencyMS: 0, secondsTranscribed: 0)
            }
            return Stats(utterances: Int(sqlite3_column_int(st, 0)),
                         spokenWords: Int(sqlite3_column_int(st, 1)),
                         secondsSpoken: sqlite3_column_double(st, 2),
                         todayWords: Int(sqlite3_column_int(st, 3)),
                         latencyMS: Int(sqlite3_column_int64(st, 4)),
                         secondsTranscribed: sqlite3_column_double(st, 5))
        }
    }

    /// Most recent first. `query` matches either the raw or the final text.
    public func recent(limit: Int = 200, offset: Int = 0, query: String = "") -> [Utterance] {
        queue.sync {
            let filter = query.trimmingCharacters(in: .whitespaces)
            let sql = """
            SELECT id,created_at,duration_ms,raw_text,final_text,tone,spoken_words,
                   latency_ms,guardrail_passed,ledger,audio_path,outcome,
                   speech_model,polish_model,polished_text,break_times
            FROM utterances
            \(filter.isEmpty ? "" : "WHERE raw_text LIKE ?1 OR final_text LIKE ?1")
            ORDER BY created_at DESC LIMIT ?2 OFFSET ?3;
            """
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(st) }
            if !filter.isEmpty {
                sqlite3_bind_text(st, 1, "%\(filter)%", -1, SQLITE_TRANSIENT)
            }
            sqlite3_bind_int(st, 2, Int32(limit))
            sqlite3_bind_int(st, 3, Int32(offset))

            var out: [Utterance] = []
            while sqlite3_step(st) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    guard let c = sqlite3_column_text(st, i) else { return "" }
                    return String(cString: c)
                }
                out.append(Utterance(
                    id: sqlite3_column_int64(st, 0),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                    durationMS: Int(sqlite3_column_int(st, 2)),
                    rawText: text(3), finalText: text(4), tone: text(5),
                    spokenWords: Int(sqlite3_column_int(st, 6)),
                    latencyMS: Int(sqlite3_column_int(st, 7)),
                    guardrailPassed: sqlite3_column_int(st, 8) == 1,
                    ledger: text(9),
                    audioPath: sqlite3_column_type(st, 10) == SQLITE_NULL ? nil : text(10),
                    outcome: text(11).isEmpty ? "ok" : text(11),
                    speechModel: text(12), polishModel: text(13),
                    polishedText: text(14), breakTimes: text(15)))
            }
            return out
        }
    }

    /// Hard delete of one utterance -- the row and its audio clip. Nothing is
    /// retained, and there is no tombstone holding the text.
    public func delete(id: Int64) {
        AudioStorage.remove(audioPath(of: id))
        queue.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM utterances WHERE id = ?;", -1, &st, nil)
                    == SQLITE_OK else { return }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int64(st, 1, id)
            sqlite3_step(st)
        }
    }

    private func audioPath(of id: Int64) -> String? {
        queue.sync {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT audio_path FROM utterances WHERE id = ?;",
                                     -1, &st, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int64(st, 1, id)
            guard sqlite3_step(st) == SQLITE_ROW,
                  sqlite3_column_type(st, 0) != SQLITE_NULL,
                  let c = sqlite3_column_text(st, 0) else { return nil }
            return String(cString: c)
        }
    }

    /// Hard delete. Delete means delete: no tombstone holding the text, and the
    /// audio goes with it.
    public func deleteAll() {
        for u in recent(limit: 100_000) { AudioStorage.remove(u.audioPath) }
        queue.sync { exec("DELETE FROM utterances;"); exec("VACUUM;") }
    }
}

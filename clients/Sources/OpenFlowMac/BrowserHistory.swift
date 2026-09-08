import Foundation
import SQLite3
import OpenFlowKit

/// Reads the domains you actually visit out of a browser's history, so the
/// vocabulary can be seeded with real sites instead of waiting for each one to
/// be transcribed wrong first.
///
/// This is the most sensitive thing OpenFlow touches, so the handling is
/// deliberately narrow:
///
/// - **Read-only, and never in place.** The database is copied to a temp file
///   and the copy is opened; the browser holds the original open and a stray
///   write would corrupt it. The copy is deleted before this returns.
/// - **Only hosts leave this function.** Paths, query strings, titles and
///   timestamps are dropped at the source -- the URL column is read but never
///   returned, so nothing downstream can leak a full URL into a file or a log.
/// - **Nothing happens without being asked.** There is no scan on launch; the
///   user presses a button, sees the list, and chooses to write it.
enum BrowserHistory {
    struct Source: Identifiable, Hashable {
        let id: String
        let name: String
        /// Bundle id, so a seeded list lands in the right vocabulary section.
        let bundleID: String
        let path: URL
    }

    /// Browsers with a readable history on this Mac.
    ///
    /// Safari is deliberately absent: its history lives under Full Disk Access,
    /// so asking would fail for most people with a permissions dialog we
    /// cannot resolve from here.
    static func available() -> [Source] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var found: [Source] = []

        let firefox = home.appending(path: "Library/Application Support/Firefox/Profiles")
        if let profiles = try? fm.contentsOfDirectory(at: firefox,
                                                      includingPropertiesForKeys: nil) {
            // Newest profile wins when there are several; "default-release" is
            // the usual one but is not guaranteed to exist.
            let places = profiles
                .map { $0.appending(path: "places.sqlite") }
                .filter { fm.fileExists(atPath: $0.path) }
                .sorted { modified($0) > modified($1) }
            if let p = places.first {
                found.append(Source(id: "firefox", name: "Firefox",
                                    bundleID: "org.mozilla.firefox", path: p))
            }
        }

        for (id, name, bundle, dir) in [
            ("chrome", "Chrome", "com.google.chrome",
             "Library/Application Support/Google/Chrome"),
            ("edge", "Edge", "com.microsoft.edgemac",
             "Library/Application Support/Microsoft Edge"),
            ("brave", "Brave", "com.brave.browser",
             "Library/Application Support/BraveSoftware/Brave-Browser"),
        ] {
            let history = home.appending(path: "\(dir)/Default/History")
            if fm.fileExists(atPath: history.path) {
                found.append(Source(id: id, name: name, bundleID: bundle, path: history))
            }
        }
        return found
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return why
            }
        }
    }

    /// Most-visited domains, highest first. Hosts only -- see the note above.
    static func domains(from source: Source, limit: Int = 400) throws
        -> [(domain: String, count: Int)] {
        let staging = FileManager.default.temporaryDirectory
            .appending(path: "of-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // The write-ahead log holds recent visits; without it a browser that is
        // currently running looks weeks out of date.
        let copy = staging.appending(path: "history.sqlite")
        do {
            try FileManager.default.copyItem(at: source.path, to: copy)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: source.path.path + suffix)
                guard FileManager.default.fileExists(atPath: side.path) else { continue }
                try? FileManager.default.copyItem(
                    at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        } catch {
            throw Failure.unreadable(
                "Could not read \(source.name)'s history: \(error.localizedDescription)")
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw Failure.unreadable("Could not open \(source.name)'s history database.")
        }
        defer { sqlite3_close(db) }

        // Firefox and the Chromium browsers name these differently; try both
        // rather than branching on which browser we think this is.
        let queries = [
            "SELECT url, visit_count FROM moz_places WHERE visit_count > 0 ORDER BY visit_count DESC LIMIT ?;",
            "SELECT url, visit_count FROM urls WHERE visit_count > 0 ORDER BY visit_count DESC LIMIT ?;",
        ]

        for sql in queries {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
                sqlite3_finalize(st)
                continue                      // wrong schema; try the other
            }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int(st, 1, Int32(limit))

            var visits: [(url: String, count: Int)] = []
            while sqlite3_step(st) == SQLITE_ROW {
                guard let c = sqlite3_column_text(st, 0) else { continue }
                visits.append((String(cString: c), Int(sqlite3_column_int(st, 1))))
            }
            // Hosts are extracted here, so the URLs go out of scope with this
            // loop and never reach a caller.
            return Domains.rank(visits)
        }

        throw Failure.unreadable(
            "\(source.name)'s history is not in a layout OpenFlow understands.")
    }
}

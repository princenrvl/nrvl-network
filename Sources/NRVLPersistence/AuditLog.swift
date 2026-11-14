import CryptoKit
import Foundation
import GRDB
import NRVLCore

/// Append-only, hash-chained record of administrative actions.
/// Triggers reject UPDATE/DELETE; the chain detects edits made by bypassing them.
/// shortcut: truncating the newest rows (or replacing the whole file) is not detectable
/// by the chain alone; anchor the head hash in the Keychain if that threat matters.
public struct AuditLog: Sendable {
    let writer: any DatabaseWriter

    @discardableResult
    public func append(
        action: String,
        target: String,
        detail: String = "",
        outcome: AuditEntry.Outcome,
        siteID: Int64 = Site.defaultID,
        actor: String = NSUserName(),
        at timestamp: Date = Date()
    ) async throws -> AuditEntry {
        try await writer.write { db in
            let prev = try String.fetchOne(db, sql: "SELECT hash FROM audit_log ORDER BY id DESC LIMIT 1") ?? ""
            let ms = Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
            let hash = Self.hash(prev: prev, siteID: siteID, ms: ms, actor: actor, action: action,
                                 target: target, detail: detail, outcome: outcome.rawValue)
            try db.execute(
                sql: """
                    INSERT INTO audit_log (site_id, timestamp_ms, actor, action, target, detail, outcome, prev_hash, hash)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [siteID, ms, actor, action, target, detail, outcome.rawValue, prev, hash])
            return AuditEntry(id: db.lastInsertedRowID, siteID: siteID,
                              timestamp: Date(timeIntervalSince1970: Double(ms) / 1000),
                              actor: actor, action: action, target: target, detail: detail, outcome: outcome)
        }
    }

    /// Newest first.
    public func entries(limit: Int = 500) async throws -> [AuditEntry] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", arguments: [limit]).map { row in
                AuditEntry(id: row["id"], siteID: row["site_id"],
                           timestamp: Date(timeIntervalSince1970: Double(row["timestamp_ms"] as Int64) / 1000),
                           actor: row["actor"], action: row["action"], target: row["target"], detail: row["detail"],
                           outcome: AuditEntry.Outcome(rawValue: row["outcome"]) ?? .unverified)
            }
        }
    }

    public func count() async throws -> Int {
        try await writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audit_log") ?? 0 }
    }

    /// Returns the id of the first row whose hash or link is wrong, or nil if the chain is intact.
    public func firstBrokenEntryID() async throws -> Int64? {
        try await writer.read { db in
            var prev = ""
            let rows = try Row.fetchCursor(db, sql: "SELECT * FROM audit_log ORDER BY id")
            while let row = try rows.next() {
                let expected = Self.hash(prev: prev, siteID: row["site_id"], ms: row["timestamp_ms"],
                                         actor: row["actor"], action: row["action"], target: row["target"],
                                         detail: row["detail"], outcome: row["outcome"])
                let stored: String = row["hash"]
                if (row["prev_hash"] as String) != prev || stored != expected { return row["id"] }
                prev = stored
            }
            return nil
        }
    }

    static func hash(prev: String, siteID: Int64, ms: Int64, actor: String, action: String,
                     target: String, detail: String, outcome: String) -> String {
        // Length-prefixed so field boundaries are unambiguous.
        let canonical = [prev, String(siteID), String(ms), actor, action, target, detail, outcome]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

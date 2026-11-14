import Foundation
import GRDB
import NRVLCore

public struct AlertStore: Sendable {
    let writer: any DatabaseWriter

    public func add(_ alerts: [Alert], siteID: Int64 = Site.defaultID) async throws {
        try await writer.write { db in
            for alert in alerts {
                try db.execute(sql: "INSERT INTO alert (site_id, kind, subject, detail, at_ms, acknowledged) VALUES (?, ?, ?, ?, ?, 0)",
                               arguments: [siteID, alert.kind.rawValue, alert.subject, alert.detail, Int64(alert.date.timeIntervalSince1970 * 1000)])
            }
        }
    }

    /// Newest first.
    public func all(since: Date = .distantPast, limit: Int = 500, siteID: Int64 = Site.defaultID) async throws -> [Alert] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM alert WHERE site_id = ? AND at_ms >= ? ORDER BY id DESC LIMIT ?",
                             arguments: [siteID, since == .distantPast ? Int64.min : Int64(since.timeIntervalSince1970 * 1000), limit]).compactMap { row in
                Alert.Kind(rawValue: row["kind"]).map {
                    Alert(id: row["id"], kind: $0, subject: row["subject"], detail: row["detail"],
                          date: Date(timeIntervalSince1970: Double(row["at_ms"] as Int64) / 1000), acknowledged: row["acknowledged"])
                }
            }
        }
    }

    /// Pass nil to acknowledge everything.
    public func acknowledge(id: Alert.ID?) async throws {
        try await writer.write { db in
            if let id { try db.execute(sql: "UPDATE alert SET acknowledged = 1 WHERE id = ?", arguments: [id]) }
            else { try db.execute(sql: "UPDATE alert SET acknowledged = 1") }
        }
    }

    public func setting<T: Decodable>(_ key: String, as type: T.Type) async throws -> T? {
        let json = try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
        return json.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }

    public func setSetting<T: Encodable & Sendable>(_ key: String, to value: T) async throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try await writer.write { try $0.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES (?, ?)", arguments: [key, json]) }
    }
}

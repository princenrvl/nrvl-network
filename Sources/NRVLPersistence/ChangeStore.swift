import Foundation
import GRDB

/// Before/after snapshots of verified configuration changes, newest last. Used for rollback and reports.
public struct ChangeStore: Sendable {
    public struct Record: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var integrationID: Int64
        /// What was changed, e.g. "sqm/eth1".
        public var subject: String
        public var before: Data
        public var after: Data
        public var date: Date
    }

    let writer: any DatabaseWriter

    public func add(integrationID: Int64, subject: String, before: Data, after: Data, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT INTO change_record (integration_id, subject, before_json, after_json, at_ms) VALUES (?, ?, ?, ?, ?)",
                           arguments: [integrationID, subject, String(decoding: before, as: UTF8.self), String(decoding: after, as: UTF8.self),
                                       Int64(date.timeIntervalSince1970 * 1000)])
        }
    }

    public func all(limit: Int = 200) async throws -> [Record] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM (SELECT * FROM change_record ORDER BY id DESC LIMIT ?) ORDER BY id", arguments: [limit]).map {
                Record(id: $0["id"], integrationID: $0["integration_id"], subject: $0["subject"],
                       before: Data(($0["before_json"] as String).utf8), after: Data(($0["after_json"] as String).utf8),
                       date: Date(timeIntervalSince1970: Double($0["at_ms"] as Int64) / 1000))
            }
        }
    }

    public func last(integrationID: Int64, subject: String) async throws -> Record? {
        try await all(limit: 1_000).last { $0.integrationID == integrationID && $0.subject == subject }
    }
}

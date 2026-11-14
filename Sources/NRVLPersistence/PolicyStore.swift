import Foundation
import GRDB
import NRVLCore

public struct PolicyStore: Sendable {
    let writer: any DatabaseWriter

    public func all(siteID: Int64 = Site.defaultID) async throws -> [AccessPolicy] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM access_policy WHERE site_id = ? ORDER BY id", arguments: [siteID]).compactMap { row in
                guard let kind = AccessPolicy.Kind(rawValue: row["kind"]) else { return nil }
                let target: AccessPolicy.Target
                if let device = row["device_id"] as Int64? { target = .device(device) }
                else if let group = row["group_name"] as String? { target = .group(group) }
                else { return nil }
                let days = Set((row["weekdays"] as String).compactMap { $0.wholeNumberValue })
                return AccessPolicy(id: row["id"], kind: kind, target: target,
                                    until: (row["until_ms"] as Int64?).map { Date(timeIntervalSince1970: Double($0) / 1000) },
                                    startMinute: row["start_minute"], endMinute: row["end_minute"], weekdays: days,
                                    createdAt: Date(timeIntervalSince1970: Double(row["created_ms"] as Int64) / 1000))
            }
        }
    }

    public func add(_ policy: AccessPolicy, siteID: Int64 = Site.defaultID) async throws -> AccessPolicy {
        var device: Int64?, group: String?
        switch policy.target {
        case .device(let id): device = id
        case .group(let name): group = name
        }
        return try await writer.write { [device, group] db in
            try db.execute(sql: """
                INSERT INTO access_policy (site_id, kind, device_id, group_name, until_ms, start_minute, end_minute, weekdays, created_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [siteID, policy.kind.rawValue, device, group,
                                 policy.until.map { Int64($0.timeIntervalSince1970 * 1000) }, policy.startMinute, policy.endMinute,
                                 policy.weekdays.sorted().map(String.init).joined(), Int64(policy.createdAt.timeIntervalSince1970 * 1000)])
            var saved = policy
            saved.id = db.lastInsertedRowID
            return saved
        }
    }

    public func remove(id: AccessPolicy.ID) async throws {
        try await writer.write { try $0.execute(sql: "DELETE FROM access_policy WHERE id = ?", arguments: [id]) }
    }

    /// Removes the manual block and any pause for one device. Schedules stay.
    public func clearManual(device: Device.ID) async throws {
        try await writer.write {
            try $0.execute(sql: "DELETE FROM access_policy WHERE device_id = ? AND kind IN ('block', 'pause')", arguments: [device])
        }
    }

    public func removeExpired(now: Date = Date()) async throws {
        try await writer.write {
            try $0.execute(sql: "DELETE FROM access_policy WHERE kind = 'pause' AND until_ms <= ?", arguments: [Int64(now.timeIntervalSince1970 * 1000)])
        }
    }
}

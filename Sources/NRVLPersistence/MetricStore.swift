import Foundation
import GRDB
import NRVLCore

/// Stored history: network measurements and per-device traffic.
// shortcut: one-minute rows are kept for `retention` and aggregated on read; add roll-up tables if charts get slow.
public struct MetricStore: Sendable {
    public static let retention: TimeInterval = 90 * 86_400

    public struct Point: Sendable, Equatable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var value: Double
    }

    public struct DeviceUsage: Sendable, Equatable, Identifiable {
        public var id: Device.ID
        /// Bytes the device received (download) and sent (upload).
        public var received: Int64
        public var sent: Int64
        public var total: Int64 { received + sent }
    }

    let writer: any DatabaseWriter

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    public func add(_ values: [String: Double], at date: Date = Date(), siteID: Int64 = Site.defaultID) async throws {
        try await writer.write { db in
            for (series, value) in values where value.isFinite {
                try db.execute(sql: "INSERT OR REPLACE INTO metric_sample (site_id, series, at_ms, value) VALUES (?, ?, ?, ?)",
                               arguments: [siteID, series, Self.ms(date), value])
            }
        }
    }

    /// Average per bucket, oldest first. Buckets with no samples are absent — gaps are real gaps.
    public func history(_ series: String, since: Date, bucket: TimeInterval, siteID: Int64 = Site.defaultID) async throws -> [Point] {
        let width = max(Int64(bucket * 1000), 1)
        return try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT (at_ms / ?) * ? AS bucket, AVG(value) AS value FROM metric_sample
                WHERE site_id = ? AND series = ? AND at_ms >= ? GROUP BY bucket ORDER BY bucket
                """, arguments: [width, width, siteID, series, Self.ms(since)]).map {
                Point(date: Date(timeIntervalSince1970: Double($0["bucket"] as Int64) / 1000), value: $0["value"])
            }
        }
    }

    /// Number of stored minutes, mean and maximum of a series within a period.
    public func summary(_ series: String, in period: DateInterval, siteID: Int64 = Site.defaultID) async throws -> (count: Int, average: Double?, maximum: Double?) {
        try await writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS n, AVG(value) AS mean, MAX(value) AS peak FROM metric_sample
                WHERE site_id = ? AND series = ? AND at_ms >= ? AND at_ms < ?
                """, arguments: [siteID, series, Self.ms(period.start), Self.ms(period.end)])
            return (row?["n"] ?? 0, row?["mean"], row?["peak"])
        }
    }

    /// Names of stored series starting with `prefix`, sorted.
    public func seriesNames(prefix: String, siteID: Int64 = Site.defaultID) async throws -> [String] {
        try await writer.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT series FROM metric_sample WHERE site_id = ? AND series >= ? AND series < ? ORDER BY series",
                                arguments: [siteID, prefix, prefix + "\u{10FFFF}"])
        }
    }

    /// Bytes per device, by MAC, for one interval.
    public func addDeviceTraffic(_ usage: [(mac: MACAddress, received: UInt64, sent: UInt64)], at date: Date = Date(),
                                 siteID: Int64 = Site.defaultID) async throws {
        let rows = usage.map { ($0.mac.description, Int64(clamping: $0.received), Int64(clamping: $0.sent)) }
        try await writer.write { db in
            for (mac, received, sent) in rows where received > 0 || sent > 0 {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO device_traffic (device_id, at_ms, rx_bytes, tx_bytes)
                    SELECT id, ?, ?, ? FROM device WHERE site_id = ? AND mac = ?
                    """, arguments: [Self.ms(date), received, sent, siteID, mac])
            }
        }
    }

    /// Heaviest first.
    public func usageByDevice(since: Date, until: Date = .distantFuture, siteID: Int64 = Site.defaultID) async throws -> [DeviceUsage] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.device_id, SUM(t.rx_bytes) AS rx, SUM(t.tx_bytes) AS tx
                FROM device_traffic t JOIN device d ON d.id = t.device_id
                WHERE d.site_id = ? AND t.at_ms >= ? AND t.at_ms < ?
                GROUP BY t.device_id ORDER BY rx + tx DESC
                """, arguments: [siteID, Self.ms(since), until == .distantFuture ? Int64.max : Self.ms(until)]).map {
                DeviceUsage(id: $0["device_id"], received: $0["rx"], sent: $0["tx"])
            }
        }
    }

    /// Total bytes (both directions) per bucket for one device, oldest first.
    public func deviceHistory(_ id: Device.ID, since: Date, bucket: TimeInterval) async throws -> [Point] {
        let width = max(Int64(bucket * 1000), 1)
        return try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT (at_ms / ?) * ? AS bucket, SUM(rx_bytes + tx_bytes) AS value FROM device_traffic
                WHERE device_id = ? AND at_ms >= ? GROUP BY bucket ORDER BY bucket
                """, arguments: [width, width, id, Self.ms(since)]).map {
                Point(date: Date(timeIntervalSince1970: Double($0["bucket"] as Int64) / 1000), value: $0["value"])
            }
        }
    }

    public func prune(now: Date = Date()) async throws {
        let cutoff = Self.ms(now.addingTimeInterval(-Self.retention))
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM metric_sample WHERE at_ms < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM device_traffic WHERE at_ms < ?", arguments: [cutoff])
        }
    }
}

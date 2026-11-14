import Foundation
import GRDB
import NRVLCore

/// The device inventory. Devices are identified by MAC address within a site.
public struct DeviceStore: Sendable {
    /// Text the user can set on a device. Raw value is the column name.
    public enum Field: String, Sendable {
        case customName = "custom_name", tags, group = "group_name"
    }

    let writer: any DatabaseWriter

    /// Inserts new devices and refreshes known ones; a sighting never erases a value it does not carry.
    /// Presence `events` are stored in the same transaction, and every brand-new device gets a `discovered` event.
    public func record(_ sightings: [DeviceSighting], events: [(MACAddress, ConnectionEvent.Kind)] = [],
                       at date: Date = Date(), siteID: Int64 = Site.defaultID) async throws {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let events = events.map { ($0.0.description, $0.1.rawValue) }
        try await writer.write { db in
            for sighting in sightings {
                if let ipv4 = sighting.ipv4 {
                    // An address belongs to whoever answers for it now; drop it from a previous holder.
                    try db.execute(sql: "UPDATE device SET ipv4 = NULL WHERE site_id = ? AND ipv4 = ? AND mac != ?",
                                   arguments: [siteID, ipv4, sighting.mac.description])
                }
                try db.execute(
                    sql: """
                        INSERT INTO device (site_id, mac, ipv4, ipv6, hostname, interface, is_this_mac, services, model,
                                            connection, ssid, uplink, vlan, integration_id, is_blocked,
                                            first_seen_ms, last_seen_ms)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT (site_id, mac) DO UPDATE SET
                            ipv4 = COALESCE(excluded.ipv4, ipv4),
                            ipv6 = CASE WHEN excluded.ipv6 = '' THEN ipv6 ELSE excluded.ipv6 END,
                            hostname = COALESCE(excluded.hostname, hostname),
                            interface = CASE WHEN excluded.interface = '' THEN interface ELSE excluded.interface END,
                            -- An integration is the authority for these, including "no longer wireless".
                            connection = CASE WHEN excluded.integration_id IS NULL THEN connection ELSE excluded.connection END,
                            ssid = CASE WHEN excluded.integration_id IS NULL THEN ssid ELSE excluded.ssid END,
                            uplink = CASE WHEN excluded.integration_id IS NULL THEN uplink ELSE excluded.uplink END,
                            vlan = CASE WHEN excluded.integration_id IS NULL THEN vlan ELSE excluded.vlan END,
                            is_blocked = CASE WHEN excluded.integration_id IS NULL THEN is_blocked ELSE excluded.is_blocked END,
                            integration_id = COALESCE(excluded.integration_id, integration_id),
                            is_this_mac = excluded.is_this_mac,
                            services = CASE WHEN excluded.services = '' THEN services ELSE excluded.services END,
                            model = COALESCE(excluded.model, model),
                            last_seen_ms = excluded.last_seen_ms
                        """,
                    arguments: [siteID, sighting.mac.description, sighting.ipv4, sighting.ipv6.joined(separator: " "),
                                sighting.hostname, sighting.interface, sighting.isThisMac,
                                sighting.services.joined(separator: " "), sighting.model,
                                sighting.connection?.rawValue, sighting.ssid, sighting.uplink, sighting.vlan,
                                sighting.integrationID, sighting.isBlocked, ms, ms])
            }
            // Every device gets exactly one `discovered` event, dated at its first sighting (also backfills older rows).
            try db.execute(sql: """
                INSERT INTO connection_event (device_id, kind, at_ms)
                SELECT id, 'discovered', first_seen_ms FROM device d
                WHERE site_id = ? AND NOT EXISTS
                    (SELECT 1 FROM connection_event e WHERE e.device_id = d.id AND e.kind = 'discovered')
                """, arguments: [siteID])
            for (mac, kind) in events {
                try Self.insertEvent(db, kind: kind, mac: mac, ms: ms, siteID: siteID)
            }
        }
    }

    private static func insertEvent(_ db: Database, kind: String, mac: String, ms: Int64, siteID: Int64) throws {
        try db.execute(sql: """
            INSERT INTO connection_event (device_id, kind, at_ms)
            SELECT id, ?, ? FROM device WHERE site_id = ? AND mac = ?
            """, arguments: [kind, ms, siteID, mac])
    }

    /// Newest first.
    public func events(for id: Device.ID, limit: Int = 20) async throws -> [ConnectionEvent] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, at_ms FROM connection_event WHERE device_id = ? ORDER BY at_ms DESC, id DESC LIMIT ?",
                             arguments: [id, limit]).compactMap { row in
                ConnectionEvent.Kind(rawValue: row["kind"]).map {
                    ConnectionEvent(kind: $0, date: Date(timeIntervalSince1970: Double(row["at_ms"] as Int64) / 1000))
                }
            }
        }
    }

    /// Events of every device after `date`, oldest first, with the device they belong to.
    public func events(after date: Date, siteID: Int64 = Site.defaultID) async throws -> [(device: Device.ID, event: ConnectionEvent)] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.device_id, e.kind, e.at_ms FROM connection_event e JOIN device d ON d.id = e.device_id
                WHERE d.site_id = ? AND e.at_ms > ? ORDER BY e.at_ms, e.id
                """, arguments: [siteID, Int64((date.timeIntervalSince1970 * 1000).rounded())]).compactMap { row in
                ConnectionEvent.Kind(rawValue: row["kind"]).map {
                    (row["device_id"], ConnectionEvent(kind: $0, date: Date(timeIntervalSince1970: Double(row["at_ms"] as Int64) / 1000)))
                }
            }
        }
    }

    /// Fills in a name from reverse DNS. Never replaces a name the device announced itself.
    public func setHostname(_ hostname: String, for mac: MACAddress, siteID: Int64 = Site.defaultID) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE device SET hostname = ? WHERE site_id = ? AND mac = ? AND hostname IS NULL",
                           arguments: [hostname, siteID, mac.description])
        }
    }

    /// Empty or nil clears the field. Tags are comma-separated.
    public func set(_ field: Field, to text: String?, id: Device.ID) async throws {
        var value = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if field == .tags {
            value = Self.splitTags(value ?? "").joined(separator: ",")   // column is NOT NULL
        } else if value?.isEmpty == true {
            value = nil
        }
        try await writer.write { [value] db in
            try db.execute(sql: "UPDATE device SET \(field.rawValue) = ? WHERE id = ?", arguments: [value, id])
        }
    }

    /// Records a blocked state that was just verified on the router, so the UI does not wait for the next scan.
    public func setBlocked(_ blocked: Bool, id: Device.ID) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE device SET is_blocked = ? WHERE id = ?", arguments: [blocked, id])
        }
    }

    public func setTrusted(_ trusted: Bool, id: Device.ID) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE device SET is_trusted = ? WHERE id = ?", arguments: [trusted, id])
        }
    }

    public func all(siteID: Int64 = Site.defaultID) async throws -> [Device] {
        try await writer.read { try Self.fetch($0, siteID: siteID) }
    }

    /// Emits the full inventory now and again after every change.
    public func updates(siteID: Int64 = Site.defaultID) -> AsyncThrowingStream<[Device], Error> {
        let observation = ValueObservation.tracking { try Self.fetch($0, siteID: siteID) }
        let writer = writer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await devices in observation.values(in: writer) { continuation.yield(devices) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func splitTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private static func fetch(_ db: Database, siteID: Int64) throws -> [Device] {
        try Row.fetchAll(db, sql: "SELECT * FROM device WHERE site_id = ? ORDER BY id", arguments: [siteID]).compactMap { row in
            guard let mac = MACAddress(string: row["mac"]) else { return nil }
            return Device(
                id: row["id"], mac: mac, ipv4: row["ipv4"],
                ipv6: (row["ipv6"] as String).split(separator: " ").map(String.init),
                hostname: row["hostname"], interface: row["interface"], isThisMac: row["is_this_mac"],
                services: (row["services"] as String).split(separator: " ").map(String.init),
                model: row["model"], customName: row["custom_name"], isTrusted: row["is_trusted"],
                tags: splitTags(row["tags"]), group: row["group_name"],
                connection: (row["connection"] as String?).flatMap(ConnectionType.init(rawValue:)),
                ssid: row["ssid"], uplink: row["uplink"], vlan: row["vlan"],
                integrationID: row["integration_id"], isBlocked: row["is_blocked"],
                firstSeen: Date(timeIntervalSince1970: Double(row["first_seen_ms"] as Int64) / 1000),
                lastSeen: Date(timeIntervalSince1970: Double(row["last_seen_ms"] as Int64) / 1000))
        }
    }
}

import Foundation
import GRDB
import NRVLCore

public struct IntegrationStore: Sendable {
    let writer: any DatabaseWriter

    public func all(siteID: Int64 = Site.defaultID) async throws -> [Integration] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM integration WHERE site_id = ? ORDER BY id", arguments: [siteID]).compactMap { row in
                guard let kind = AdapterKind(rawValue: row["kind"]) else { return nil }
                return Integration(id: row["id"], kind: kind, name: row["name"], host: row["host"], port: row["port"],
                                   username: row["username"], pinnedCertificate: row["pinned_certificate"],
                                   managementEnabled: row["management_enabled"])
            }
        }
    }

    /// Inserts when `id` is 0, otherwise updates. Returns the stored value with its id.
    public func save(_ integration: Integration, siteID: Int64 = Site.defaultID) async throws -> Integration {
        try await writer.write { db in
            var saved = integration
            let values: StatementArguments = [integration.kind.rawValue, integration.name, integration.host, integration.port,
                                              integration.username, integration.pinnedCertificate, integration.managementEnabled]
            if integration.id == 0 {
                try db.execute(sql: """
                    INSERT INTO integration (kind, name, host, port, username, pinned_certificate, management_enabled, site_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: values + [siteID])
                saved.id = db.lastInsertedRowID
            } else {
                try db.execute(sql: """
                    UPDATE integration SET kind = ?, name = ?, host = ?, port = ?, username = ?, pinned_certificate = ?,
                                           management_enabled = ? WHERE id = ?
                    """, arguments: values + [integration.id])
            }
            return saved
        }
    }

    public func delete(id: Integration.ID) async throws {
        try await writer.write { db in
            // Keep the devices; forget only what this integration alone could know.
            try db.execute(sql: """
                UPDATE device SET connection = NULL, ssid = NULL, uplink = NULL, vlan = NULL, is_blocked = NULL, integration_id = NULL
                WHERE integration_id = ?
                """, arguments: [id])
            try db.execute(sql: "DELETE FROM integration WHERE id = ?", arguments: [id])
        }
    }
}

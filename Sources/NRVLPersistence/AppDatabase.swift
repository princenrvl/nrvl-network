import Foundation
import GRDB

public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    /// Opens (creating if needed) the per-user database in Application Support.
    public static func onDisk() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)   // wait for another process's write instead of failing at once
        return try AppDatabase(DatabasePool(path: defaultURL().path, configuration: configuration))
    }

    public static func defaultURL() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("NRVL Network", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nrvl.sqlite")
    }

    public var audit: AuditLog { AuditLog(writer: writer) }
    public var devices: DeviceStore { DeviceStore(writer: writer) }
    public var integrations: IntegrationStore { IntegrationStore(writer: writer) }
    public var metrics: MetricStore { MetricStore(writer: writer) }
    public var policies: PolicyStore { PolicyStore(writer: writer) }
    public var changes: ChangeStore { ChangeStore(writer: writer) }
    public var alerts: AlertStore { AlertStore(writer: writer) }

    // Migrations are append-only: never edit a registered migration, add a new one.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE site (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL
                );
                INSERT INTO site (id, name) VALUES (1, 'Default Site');

                CREATE TABLE audit_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    site_id INTEGER NOT NULL REFERENCES site(id),
                    timestamp_ms INTEGER NOT NULL,
                    actor TEXT NOT NULL,
                    action TEXT NOT NULL,
                    target TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    prev_hash TEXT NOT NULL,
                    hash TEXT NOT NULL
                );
                CREATE TRIGGER audit_log_no_update BEFORE UPDATE ON audit_log
                BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
                CREATE TRIGGER audit_log_no_delete BEFORE DELETE ON audit_log
                BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
                """)
        }
        migrator.registerMigration("v2-devices") { db in
            // Per-source observations get their own table when a second source (router adapters) exists.
            try db.execute(sql: """
                CREATE TABLE device (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    site_id INTEGER NOT NULL REFERENCES site(id),
                    mac TEXT NOT NULL,
                    ipv4 TEXT,
                    ipv6 TEXT NOT NULL DEFAULT '',
                    hostname TEXT,
                    interface TEXT NOT NULL,
                    is_this_mac INTEGER NOT NULL DEFAULT 0,
                    custom_name TEXT,
                    is_trusted INTEGER NOT NULL DEFAULT 0,
                    first_seen_ms INTEGER NOT NULL,
                    last_seen_ms INTEGER NOT NULL,
                    UNIQUE (site_id, mac)
                );
                """)
        }
        migrator.registerMigration("v3-identity-and-history") { db in
            try db.execute(sql: """
                ALTER TABLE device ADD COLUMN services TEXT NOT NULL DEFAULT '';
                ALTER TABLE device ADD COLUMN model TEXT;
                ALTER TABLE device ADD COLUMN tags TEXT NOT NULL DEFAULT '';
                ALTER TABLE device ADD COLUMN group_name TEXT;

                CREATE TABLE connection_event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    device_id INTEGER NOT NULL REFERENCES device(id),
                    kind TEXT NOT NULL,
                    at_ms INTEGER NOT NULL
                );
                CREATE INDEX connection_event_by_device ON connection_event(device_id, at_ms);
                """)
        }
        migrator.registerMigration("v4-integrations") { db in
            // No secret is stored here: passwords, API keys and community strings live in the Keychain.
            try db.execute(sql: """
                CREATE TABLE integration (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    site_id INTEGER NOT NULL REFERENCES site(id),
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL,
                    host TEXT NOT NULL,
                    port INTEGER,
                    username TEXT,
                    pinned_certificate TEXT,
                    management_enabled INTEGER NOT NULL DEFAULT 0
                );
                ALTER TABLE device ADD COLUMN connection TEXT;
                ALTER TABLE device ADD COLUMN ssid TEXT;
                ALTER TABLE device ADD COLUMN uplink TEXT;
                ALTER TABLE device ADD COLUMN vlan INTEGER;
                ALTER TABLE device ADD COLUMN integration_id INTEGER;
                ALTER TABLE device ADD COLUMN is_blocked INTEGER;
                """)
        }
        migrator.registerMigration("v5-history") { db in
            try db.execute(sql: """
                -- One value per series per minute, e.g. "mac.down" (bytes/s) or "internet.latency" (seconds).
                CREATE TABLE metric_sample (
                    site_id INTEGER NOT NULL REFERENCES site(id),
                    series TEXT NOT NULL,
                    at_ms INTEGER NOT NULL,
                    value REAL NOT NULL,
                    PRIMARY KEY (site_id, series, at_ms)
                ) WITHOUT ROWID;

                -- Bytes a device moved during one polling interval, as counted by a router integration.
                CREATE TABLE device_traffic (
                    device_id INTEGER NOT NULL REFERENCES device(id),
                    at_ms INTEGER NOT NULL,
                    rx_bytes INTEGER NOT NULL,
                    tx_bytes INTEGER NOT NULL,
                    PRIMARY KEY (device_id, at_ms)
                ) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("v6-access-policies") { db in
            try db.execute(sql: """
                CREATE TABLE access_policy (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    site_id INTEGER NOT NULL REFERENCES site(id),
                    kind TEXT NOT NULL,
                    device_id INTEGER REFERENCES device(id),
                    group_name TEXT,
                    until_ms INTEGER,
                    start_minute INTEGER,
                    end_minute INTEGER,
                    weekdays TEXT NOT NULL DEFAULT '',
                    created_ms INTEGER NOT NULL,
                    CHECK ((device_id IS NULL) != (group_name IS NULL))
                );
                """)
        }
        migrator.registerMigration("v7-change-records") { db in
            // What a setting was before and after a verified change, so it can be rolled back later.
            try db.execute(sql: """
                CREATE TABLE change_record (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    integration_id INTEGER NOT NULL,
                    subject TEXT NOT NULL,
                    before_json TEXT NOT NULL,
                    after_json TEXT NOT NULL,
                    at_ms INTEGER NOT NULL
                );
                """)
        }
        migrator.registerMigration("v8-alerts") { db in
            try db.execute(sql: """
                CREATE TABLE alert (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    site_id INTEGER NOT NULL REFERENCES site(id),
                    kind TEXT NOT NULL,
                    subject TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    at_ms INTEGER NOT NULL,
                    acknowledged INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                """)
        }
        return migrator
    }
}

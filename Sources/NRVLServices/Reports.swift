import CryptoKit
import Foundation
import NRVLAdapters
import NRVLCore
import NRVLPersistence

/// What the app recorded about the network during one period. Every figure comes from stored data;
/// `observedFraction` says how much of the period the app was actually watching.
public struct NetworkReport: Sendable, Equatable {
    public struct Count: Sendable, Equatable, Identifiable {
        public var id: String { label }
        public var label: String
        public var count: Int
    }
    public struct Usage: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var received: Int64
        public var sent: Int64
    }
    public struct Change: Sendable, Equatable, Identifiable {
        public var id: Int64
        public var date: Date
        public var summary: String
    }

    public var period: DateInterval
    /// Share of the period's minutes for which measurements exist (0…1).
    public var observedFraction = 0.0
    /// Share of internet checks answered, among the observed minutes. Nil when nothing was observed.
    public var internetAvailability: Double?
    public var averageLatency: TimeInterval?
    public var worstMinuteLatency: TimeInterval?
    public var averageDownload: Double?
    public var averageUpload: Double?
    public var devicesKnown = 0
    public var devicesDiscovered: [String] = []
    public var connectionEvents: [Count] = []
    public var usage: [Usage] = []
    public var alerts: [Count] = []
    public var securityEvents: [Alert] = []
    public var changes: [Change] = []
    public var auditActions: [Count] = []
}

public enum ReportBuilder {
    public static func build(period: DateInterval, database: AppDatabase) async throws -> NetworkReport {
        var report = NetworkReport(period: period)
        let metrics = database.metrics

        let loss = try await metrics.summary("internet.loss", in: period)
        let minutes = max(period.duration / 60, 1)
        report.observedFraction = min(Double(loss.count) / minutes, 1)
        report.internetAvailability = loss.average.map { 1 - $0 }
        let latency = try await metrics.summary("internet.latency", in: period)
        report.averageLatency = latency.average
        report.worstMinuteLatency = latency.maximum
        report.averageDownload = try await metrics.summary("mac.down", in: period).average
        report.averageUpload = try await metrics.summary("mac.up", in: period).average

        let devices = try await database.devices.all()
        func name(_ device: Device) -> String { device.customName ?? device.hostname ?? device.mac.description }
        let names = Dictionary(devices.map { ($0.id, name($0)) }, uniquingKeysWith: { first, _ in first })
        report.devicesKnown = devices.count { $0.firstSeen < period.end }
        report.devicesDiscovered = devices.filter { period.contains($0.firstSeen) }.map(name).sorted()

        let events = try await database.devices.events(after: period.start).filter { $0.event.date < period.end }
        report.connectionEvents = count(events.map { $0.event.kind.rawValue.capitalized })

        report.usage = try await metrics.usageByDevice(since: period.start, until: period.end).map {
            NetworkReport.Usage(name: names[$0.id] ?? "Device \($0.id)", received: $0.received, sent: $0.sent)
        }

        let alerts = try await database.alerts.all(since: period.start, limit: 5_000).filter { $0.date < period.end }
        report.alerts = count(alerts.map(\.kind.title))
        report.securityEvents = alerts.filter(\.kind.isSecurity)

        report.changes = try await database.changes.all(limit: 1_000).filter { period.contains($0.date) }.map {
            NetworkReport.Change(id: $0.id, date: $0.date, summary: "\($0.subject): \(describe($0.before)) → \(describe($0.after))")
        }
        let audit = try await database.audit.entries(limit: 10_000).filter { period.contains($0.timestamp) }
        report.auditActions = count(audit.map { "\($0.action) — \($0.outcome.rawValue)" })
        return report
    }

    private static func count(_ labels: [String]) -> [NetworkReport.Count] {
        Dictionary(grouping: labels, by: { $0 }).map { NetworkReport.Count(label: $0.key, count: $0.value.count) }
            .sorted { ($1.count, $0.label) < ($0.count, $1.label) }
    }

    private static func describe(_ json: Data) -> String {
        (try? JSONDecoder().decode(ShapingQueue.self, from: json)).map(QoSEngine.describe) ?? String(decoding: json, as: UTF8.self)
    }
}

public enum CSV {
    /// RFC 4180 output. Cells come partly from the network (device names), so anything a spreadsheet
    /// would run as a formula is neutralised with a leading apostrophe.
    public static func encode(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func cell(_ value: String) -> String {
        var text = value
        // Unicode scalars, not Characters: Swift treats "\r\n" as one Character, which would miss a lone "\n".
        if let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) { text = "'" + text }
        guard text.unicodeScalars.contains(where: { ",\"\r\n".unicodeScalars.contains($0) }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Encrypted configuration snapshots of integrations that can export their configuration.
/// Files are AES-256-GCM; the key lives in the Keychain and never on disk.
public struct BackupService: Sendable {
    public struct Backup: Sendable, Equatable, Identifiable {
        public var id: URL { url }
        public var url: URL
        public var integrationName: String
        public var date: Date
        public var size: Int
    }

    let directory: URL
    let credentials: CredentialStore
    let audit: AuditLog?
    private static let keyAccount = "configuration-backup-key"

    public init(directory: URL, credentials: CredentialStore = CredentialStore(), audit: AuditLog? = nil) {
        self.directory = directory
        self.credentials = credentials
        self.audit = audit
    }

    private func key() throws -> SymmetricKey {
        if let stored = try credentials.get(account: Self.keyAccount), let data = Data(base64Encoded: stored), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try credentials.set(key.withUnsafeBytes { Data($0) }.base64EncodedString(), account: Self.keyAccount)
        return key
    }

    @discardableResult
    public func create(for integration: Integration, adapter: any InfrastructureAdapter, at date: Date = Date()) async throws -> Backup {
        guard let exporter = adapter as? any ConfigurationExporting else {
            throw AdapterError.unsupported("\(integration.kind.title) offers no documented way to export its configuration.")
        }
        let plain = try await exporter.exportConfiguration()
        guard let sealed = try AES.GCM.seal(plain, using: try key()).combined else { throw AdapterError.protocolError("encryption failed") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = integration.name.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
        let url = directory.appendingPathComponent("\(safeName)_\(Int(date.timeIntervalSince1970)).nrvlbackup")
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try await audit?.append(action: "backup.create", target: integration.name, detail: "bytes=\(plain.count)", outcome: .succeeded)
        return Backup(url: url, integrationName: integration.name, date: date, size: sealed.count)
    }

    /// Newest first.
    public func all() -> [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "nrvlbackup" }.compactMap { url in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard parts.count >= 2, let stamp = TimeInterval(parts.last!) else { return nil }
            return Backup(url: url, integrationName: parts.dropLast().joined(separator: "_"), date: Date(timeIntervalSince1970: stamp),
                          size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        .sorted { $0.date > $1.date }
    }

    /// The decrypted configuration. Fails if the file was altered or the key is gone.
    public func decrypt(_ backup: Backup) async throws -> Data {
        let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: try Data(contentsOf: backup.url)), using: try key())
        try await audit?.append(action: "backup.decrypt", target: backup.integrationName, detail: backup.url.lastPathComponent, outcome: .succeeded)
        return plain
    }
}

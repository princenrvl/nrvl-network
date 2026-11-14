import Foundation
import NRVLAdapters
import NRVLCore
import NRVLPersistence
import Testing
@testable import NRVLServices

@Test func csvEscapesAndNeutralisesFormulas() {
    let csv = CSV.encode(header: ["Name", "Note"], rows: [
        ["Printer, office", "says \"hi\""],
        ["=HYPERLINK(\"http://evil\")", "+1"],          // a device could announce a name like this
        ["line\nbreak", "@cmd"], ["-5", "plain"],
    ])
    #expect(csv == "Name,Note\r\n\"Printer, office\",\"says \"\"hi\"\"\"\r\n\"'=HYPERLINK(\"\"http://evil\"\")\",'+1\r\n\"line\nbreak\",'@cmd\r\n'-5,plain\r\n")
}

@Test func reportSummarisesOnlyThePeriod() async throws {
    let db = try AppDatabase.inMemory()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let period = DateInterval(start: start, duration: 3_600)

    // 30 of 60 minutes observed; one of them had total loss.
    for minute in 0..<30 {
        try await db.metrics.add(["internet.loss": minute == 5 ? 1 : 0, "internet.latency": minute == 7 ? 0.2 : 0.02,
                                  "mac.down": 1_000, "mac.up": 100], at: start + Double(minute) * 60)
    }
    try await db.metrics.add(["internet.loss": 1], at: start - 600)             // before the period: ignored

    let printer = MACAddress(string: "00:00:00:00:00:01")!, old = MACAddress(string: "00:00:00:00:00:02")!
    try await db.devices.record([DeviceSighting(mac: old, hostname: "old-nas")], at: start - 86_400)
    try await db.devices.record([DeviceSighting(mac: printer, hostname: "printer")], events: [(old, .disappeared)], at: start + 120)
    try await db.metrics.addDeviceTraffic([(printer, 5_000, 500)], at: start + 180)
    try await db.alerts.add([Alert(kind: .newDevice, subject: "printer", detail: "first seen", date: start + 120),
                             Alert(kind: .highLatency, subject: "internet", detail: "200 ms", date: start + 420),
                             Alert(kind: .gatewayOffline, subject: "gw", detail: "later", date: start + 7_200)])
    try await db.audit.append(action: "access.block", target: "x", outcome: .failed, at: start + 300)
    try await db.audit.append(action: "app.launch", target: "x", outcome: .succeeded, at: start + 9_000)

    let report = try await ReportBuilder.build(period: period, database: db)
    #expect(report.observedFraction == 0.5)
    #expect(abs(report.internetAvailability! - 29.0 / 30) < 1e-9)
    #expect(report.worstMinuteLatency == 0.2 && abs(report.averageLatency! - 0.026) < 1e-9)
    #expect(report.averageDownload == 1_000)
    #expect(report.devicesKnown == 2 && report.devicesDiscovered == ["printer"])
    #expect(report.connectionEvents == [.init(label: "Disappeared", count: 1), .init(label: "Discovered", count: 1)])
    #expect(report.usage == [.init(name: "printer", received: 5_000, sent: 500)])
    #expect(report.alerts.map(\.label) == ["High latency", "New device"])
    #expect(report.securityEvents.map(\.kind) == [.newDevice])
    #expect(report.auditActions == [.init(label: "access.block — failed", count: 1)])

    let empty = try await ReportBuilder.build(period: DateInterval(start: start + 86_400, duration: 3_600), database: db)
    #expect(empty.observedFraction == 0 && empty.internetAvailability == nil && empty.alerts.isEmpty)   // nothing observed, nothing claimed
}

private struct ExportingRouter: ConfigurationExporting {
    func identify() async throws -> AdapterIdentity { AdapterIdentity(name: "r", model: "m") }
    func capabilities() async throws -> CapabilitySet { [:] }
    func clients() async throws -> [DeviceSighting] { [] }
    func infrastructureDevices() async throws -> [InfrastructureDevice] { [] }
    func networks() async throws -> [NetworkRecord] { [] }
    func exportConfiguration() async throws -> Data { Data("wifi-key=hunter2".utf8) }
}

@Test func backupsAreEncryptedAndTamperEvident() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nrvl-backup-test-\(UUID().uuidString)")
    let credentials = CredentialStore(service: "com.nrvl.network.tests.backup")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? credentials.delete(account: "configuration-backup-key")
    }
    let service = BackupService(directory: directory, credentials: credentials)
    let integration = Integration(id: 1, kind: .openwrt, name: "Attic Router!", host: "192.0.2.1")

    let backup = try await service.create(for: integration, adapter: ExportingRouter())
    let stored = try Data(contentsOf: backup.url)
    #expect(stored.range(of: Data("hunter2".utf8)) == nil)                          // the secret is not on disk in the clear
    #expect(try FileManager.default.attributesOfItem(atPath: backup.url.path)[.posixPermissions] as? Int == 0o600)
    #expect(service.all().map(\.integrationName) == ["Attic-Router-"])
    #expect(try await service.decrypt(backup) == Data("wifi-key=hunter2".utf8))

    var tampered = stored
    tampered[tampered.count - 1] ^= 0xFF
    try tampered.write(to: backup.url)
    await #expect(throws: (any Error).self) { try await service.decrypt(backup) }

    await #expect(throws: AdapterError.self) { try await service.create(for: integration, adapter: FakeRouter()) }   // cannot export: says so
}

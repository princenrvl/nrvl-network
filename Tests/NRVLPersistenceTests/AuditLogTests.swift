import Foundation
import GRDB
import NRVLCore
import Testing
@testable import NRVLPersistence

@Test func migrationCreatesDefaultSite() async throws {
    let db = try AppDatabase.inMemory()
    let name = try await db.writer.read { try String.fetchOne($0, sql: "SELECT name FROM site WHERE id = 1") }
    #expect(name == "Default Site")
}

@Test func appendedEntriesFormAnIntactChain() async throws {
    let audit = try AppDatabase.inMemory().audit
    try await audit.append(action: "device.block", target: "aa:bb:cc:dd:ee:ff", outcome: .succeeded)
    try await audit.append(action: "device.unblock", target: "aa:bb:cc:dd:ee:ff", outcome: .failed)
    let last = try await audit.append(action: "qos.apply", target: "policy 3", detail: "{}", outcome: .unverified)

    #expect(try await audit.count() == 3)
    #expect(try await audit.firstBrokenEntryID() == nil)
    #expect(try await audit.entries().first == last)
}

@Test func updateAndDeleteAreRejected() async throws {
    let db = try AppDatabase.inMemory()
    try await db.audit.append(action: "a", target: "t", outcome: .succeeded)

    await #expect(throws: DatabaseError.self) {
        try await db.writer.write { try $0.execute(sql: "UPDATE audit_log SET outcome = 'succeeded'") }
    }
    await #expect(throws: DatabaseError.self) {
        try await db.writer.write { try $0.execute(sql: "DELETE FROM audit_log") }
    }
    #expect(try await db.audit.count() == 1)
}

@Test func tamperingThatBypassesTriggersIsDetected() async throws {
    let db = try AppDatabase.inMemory()
    try await db.audit.append(action: "a", target: "t", outcome: .failed)
    let second = try await db.audit.append(action: "b", target: "t", outcome: .failed)
    try await db.audit.append(action: "c", target: "t", outcome: .failed)

    // Simulates someone editing the file directly with the trigger removed.
    try await db.writer.write { db in
        try db.execute(sql: "DROP TRIGGER audit_log_no_update")
        try db.execute(sql: "UPDATE audit_log SET outcome = 'succeeded' WHERE id = ?", arguments: [second.id])
    }
    #expect(try await db.audit.firstBrokenEntryID() == second.id)
}

@Test func deviceSightingsUpsertWithoutErasingKnownValues() async throws {
    let store = try AppDatabase.inMemory().devices
    let mac = MACAddress(string: "a4:83:e7:01:02:03")!
    let first = Date(timeIntervalSince1970: 1_000)
    let second = Date(timeIntervalSince1970: 2_000)

    try await store.record([DeviceSighting(mac: mac, ipv4: "192.168.1.9", ipv6: ["fe80::9"], interface: "en0")], at: first)
    try await store.setHostname("printer.lan", for: mac)
    // Second sighting has no IPv4, no IPv6 and no hostname: the known ones must survive.
    try await store.record([DeviceSighting(mac: mac, interface: "en0")], at: second)

    var devices = try await store.all()
    #expect(devices.count == 1)
    #expect(devices[0].ipv4 == "192.168.1.9")
    #expect(devices[0].ipv6 == ["fe80::9"])
    #expect(devices[0].hostname == "printer.lan")
    #expect(devices[0].firstSeen == first)
    #expect(devices[0].lastSeen == second)

    try await store.set(.customName, to: "  Office Printer ", id: devices[0].id)
    try await store.set(.tags, to: "office, Printers ,,office", id: devices[0].id)
    try await store.set(.group, to: "Ground floor", id: devices[0].id)
    try await store.setTrusted(true, id: devices[0].id)
    devices = try await store.all()
    #expect(devices[0].customName == "Office Printer")
    #expect(devices[0].tags == ["office", "Printers"])
    #expect(devices[0].group == "Ground floor")
    #expect(devices[0].isTrusted)

    try await store.set(.customName, to: "   ", id: devices[0].id)
    try await store.set(.tags, to: nil, id: devices[0].id)
    devices = try await store.all()
    #expect(devices[0].customName == nil)
    #expect(devices[0].tags.isEmpty)

    // A hostname the device announced (carried by a sighting) is not replaced by reverse DNS.
    try await store.setHostname("other.lan", for: mac)
    #expect(try await store.all()[0].hostname == "printer.lan")
}

@Test func connectionEventsAreRecordedOncePerCause() async throws {
    let store = try AppDatabase.inMemory().devices
    let mac = MACAddress(string: "a4:83:e7:01:02:03")!
    let sighting = DeviceSighting(mac: mac, ipv4: "192.168.1.9", interface: "en0", services: ["_ipp._tcp"], model: "X1")

    try await store.record([sighting], at: Date(timeIntervalSince1970: 1_000))
    try await store.record([sighting], at: Date(timeIntervalSince1970: 2_000))   // must not add a second "discovered"
    try await store.record([], events: [(mac, .disappeared)], at: Date(timeIntervalSince1970: 3_000))

    let device = try #require(try await store.all().first)
    #expect(device.services == ["_ipp._tcp"])
    #expect(device.model == "X1")
    #expect(try await store.events(for: device.id) == [
        ConnectionEvent(kind: .disappeared, date: Date(timeIntervalSince1970: 3_000)),
        ConnectionEvent(kind: .discovered, date: Date(timeIntervalSince1970: 1_000)),
    ])
}

@Test func addressMovesToItsNewHolder() async throws {
    let store = try AppDatabase.inMemory().devices
    let old = MACAddress(string: "00:00:00:00:00:01")!, new = MACAddress(string: "00:00:00:00:00:02")!
    try await store.record([DeviceSighting(mac: old, ipv4: "192.168.1.30", interface: "en0")])
    try await store.record([DeviceSighting(mac: new, ipv4: "192.168.1.30", interface: "en0")])

    let devices = try await store.all()
    #expect(devices.first { $0.mac == old }?.ipv4 == nil)
    #expect(devices.first { $0.mac == new }?.ipv4 == "192.168.1.30")
}

@Test func integrationFieldsFollowTheIntegration() async throws {
    let db = try AppDatabase.inMemory()
    let mac = MACAddress(string: "00:00:00:00:00:09")!
    let saved = try await db.integrations.save(Integration(kind: .snmp, name: "Switch", host: "192.168.1.2"))
    #expect(saved.id != 0)

    try await db.devices.record([DeviceSighting(mac: mac, ipv4: "192.168.1.9", interface: "en0", connection: .wireless,
                                                ssid: "Office", uplink: "Hall AP", vlan: 20, integrationID: saved.id)])
    // A local-only sighting must not wipe integration data, and must not blank the interface.
    try await db.devices.record([DeviceSighting(mac: mac, ipv4: "192.168.1.9")])
    var device = try #require(try await db.devices.all().first)
    #expect(device.ssid == "Office" && device.vlan == 20 && device.connection == .wireless && device.interface == "en0")

    // The integration now says the device is wired: wireless details are cleared.
    try await db.devices.record([DeviceSighting(mac: mac, connection: .wired, uplink: "Switch port 3", integrationID: saved.id)])
    device = try #require(try await db.devices.all().first)
    #expect(device.connection == .wired && device.ssid == nil && device.uplink == "Switch port 3")

    var edited = saved
    edited.pinnedCertificate = "abcd"
    #expect(try await db.integrations.save(edited).id == saved.id)
    #expect(try await db.integrations.all() == [edited])

    try await db.integrations.delete(id: saved.id)
    device = try #require(try await db.devices.all().first)
    #expect(device.connection == nil && device.uplink == nil && device.integrationID == nil)
    #expect(try await db.integrations.all().isEmpty)
}

@Test func metricHistoryBucketsAndPrunes() async throws {
    let db = try AppDatabase.inMemory()
    let start = Date(timeIntervalSince1970: 1_000_000_020)   // 20 s past an exact minute
    for (offset, value) in [(0.0, 10.0), (60, 20), (120, 60), (7_200, 5)] {
        try await db.metrics.add(["mac.down": value, "ignored": .nan], at: start + offset)
    }
    let hourly = try await db.metrics.history("mac.down", since: start - 1, bucket: 3_600)
    #expect(hourly.map(\.value) == [30, 5])                       // mean of 10, 20, 60, then the later hour
    #expect(try await db.metrics.history("ignored", since: .distantPast, bucket: 60).isEmpty)
    #expect(try await db.metrics.history("mac.down", since: start + 100, bucket: 60).count == 2)

    try await db.metrics.prune(now: start + MetricStore.retention + 200)
    #expect(try await db.metrics.history("mac.down", since: .distantPast, bucket: 60).map(\.value) == [5])
}

@Test func deviceTrafficSumsPerDevice() async throws {
    let db = try AppDatabase.inMemory()
    let heavy = MACAddress(string: "00:00:00:00:00:01")!, light = MACAddress(string: "00:00:00:00:00:02")!
    let unknown = MACAddress(string: "00:00:00:00:00:03")!
    try await db.devices.record([DeviceSighting(mac: heavy), DeviceSighting(mac: light)])
    let start = Date(timeIntervalSince1970: 1_000_000)
    try await db.metrics.addDeviceTraffic([(heavy, 1_000, 100), (light, 10, 5), (unknown, 99, 99)], at: start)
    try await db.metrics.addDeviceTraffic([(heavy, 2_000, 200), (light, 0, 0)], at: start + 60)

    let usage = try await db.metrics.usageByDevice(since: start)
    #expect(usage.map(\.total) == [3_300, 15])                    // unknown MAC is dropped, not invented
    #expect(try await db.metrics.usageByDevice(since: start + 30).map(\.total) == [2_200])
    #expect(try await db.metrics.deviceHistory(usage[0].id, since: start, bucket: 3_600).map(\.value) == [3_300])
}

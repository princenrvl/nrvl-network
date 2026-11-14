import Foundation
import NRVLAdapters
import NRVLCore
import NRVLPersistence
import Testing
@testable import NRVLServices

/// A pretend router whose block list lives in memory. Test-only.
final class FakeRouter: AccessControlling, LinkShaping, AdapterProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var blocked: Set<MACAddress> = []
    var integration = Integration(id: 1, kind: .openwrt, name: "Test Router", host: "192.0.2.1", managementEnabled: true)
    var failApply = false
    var ignoreApply = false
    var support: Support = .supported
    private(set) var applyCount = 0
    private var queue = ShapingQueue(id: "wan", interface: "eth1", enabled: true, downloadKbps: 100_000, uploadKbps: 20_000)

    func shapingQueues() async throws -> [ShapingQueue] { lock.withLock { [queue] } }
    func apply(_ desired: ShapingQueue) async throws {
        try lock.withLock {
            applyCount += 1
            if failApply { throw AdapterError.timeout }
            if !ignoreApply { queue = desired }
        }
    }

    func all() async throws -> [Integration] { [integration] }
    func adapter(for integration: Integration) async throws -> any InfrastructureAdapter { self }
    func identify() async throws -> AdapterIdentity { AdapterIdentity(name: "fake", model: "fake") }
    func capabilities() async throws -> CapabilitySet { [.accessControl: support] }
    func clients() async throws -> [DeviceSighting] { [] }
    func infrastructureDevices() async throws -> [InfrastructureDevice] { [] }
    func networks() async throws -> [NetworkRecord] { [] }
    func isBlocked(mac: MACAddress) async throws -> Bool { lock.withLock { blocked.contains(mac) } }
    func setBlocked(_ value: Bool, mac: MACAddress) async throws {
        try lock.withLock {
            applyCount += 1
            if failApply { throw AdapterError.timeout }
            if ignoreApply { return }
            if value { blocked.insert(mac) } else { blocked.remove(mac) }
        }
    }
}

private func setUp() async throws -> (AppDatabase, FakeRouter, AccessControlEngine, Device) {
    let db = try AppDatabase.inMemory()
    let router = FakeRouter()
    try await db.devices.record([DeviceSighting(mac: MACAddress(string: "a4:83:e7:00:00:10")!, ipv4: "192.168.1.10",
                                                connection: .wireless, integrationID: 1, isBlocked: false)])
    return (db, router, AccessControlEngine(database: db, provider: router), try #require(try await db.devices.all().first))
}

@Test func blockIsVerifiedAndAudited() async throws {
    let (db, router, engine, device) = try await setUp()

    #expect(await engine.setBlocked(true, device: device, initiator: "tester") == .succeeded)
    #expect(try await router.isBlocked(mac: device.mac))
    #expect(try await db.devices.all().first?.isBlocked == true)

    let entry = try #require(try await db.audit.entries().first)
    #expect(entry.action == "access.block" && entry.outcome == .succeeded && entry.actor == "tester")
    #expect(entry.detail.contains("before=allowed after=blocked"))
    #expect(try await db.audit.firstBrokenEntryID() == nil)
}

@Test func failuresAndUnverifiedChangesAreNeverReportedAsSuccess() async throws {
    let (db, router, engine, device) = try await setUp()

    router.failApply = true
    guard case .failed = await engine.setBlocked(true, device: device) else { Issue.record("a thrown error must be a failure"); return }
    #expect(try await db.audit.entries().first?.outcome == .failed)

    router.failApply = false
    router.ignoreApply = true   // the router says OK but does nothing
    guard case .unverified = await engine.setBlocked(true, device: device) else { Issue.record("must be unverified"); return }
    #expect(try await db.audit.entries().first?.outcome == .unverified)
    #expect(try await db.devices.all().first?.isBlocked == false)   // local state is not changed on an unverified result
}

@Test func unavailableCasesExplainThemselvesAndTouchNothing() async throws {
    let (db, router, engine, device) = try await setUp()

    router.integration.managementEnabled = false
    guard case .unavailable(let readOnly) = await engine.availability(for: device) else { Issue.record("read-only must be unavailable"); return }
    #expect(readOnly.contains("read-only"))
    guard case .failed = await engine.setBlocked(true, device: device) else { Issue.record("must fail"); return }
    #expect(router.applyCount == 0)
    #expect(try await db.audit.entries().first?.outcome == .failed)   // the refused attempt is still on record

    router.integration.managementEnabled = true
    router.support = .unsupported("Firmware too old.")
    #expect(await engine.availability(for: device) == .unavailable("Firmware too old."))

    router.support = .supported
    guard case .unavailable = await engine.availability(for: device, gateway: "192.168.1.10") else { Issue.record("gateway must be protected"); return }

    var local = device
    local.integrationID = nil
    guard case .unavailable = await engine.availability(for: local) else { Issue.record("no integration, no control"); return }
    var own = device
    own.isThisMac = true
    guard case .unavailable = await engine.availability(for: own) else { Issue.record("this Mac must be protected"); return }
    #expect(router.applyCount == 0)
}

@Test func schedulesAndPausesDriveReconciliation() async throws {
    let (db, router, engine, device) = try await setUp()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // 2026-11-11 is a Wednesday (weekday 4).
    func at(_ hour: Int, _ minute: Int = 0, day: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    func current() async throws -> [Device] { try await db.devices.all() }

    // Overnight schedule on Wednesdays: 22:00 → 06:00.
    let schedule = try await engine.add(AccessPolicy(kind: .schedule, target: .device(device.id), startMinute: 22 * 60, endMinute: 6 * 60, weekdays: [4]))
    #expect(!schedule.isActive(at: at(21, 59), calendar: calendar))
    #expect(schedule.isActive(at: at(22), calendar: calendar))
    #expect(schedule.isActive(at: at(5, 59, day: 12), calendar: calendar))    // Thursday morning still belongs to Wednesday night
    #expect(!schedule.isActive(at: at(6, 0, day: 12), calendar: calendar))
    #expect(!schedule.isActive(at: at(23, 0, day: 12), calendar: calendar))   // Thursday night is not scheduled

    #expect(await engine.reconcile(devices: try await current(), now: at(12), calendar: calendar).isEmpty)
    #expect(await engine.reconcile(devices: try await current(), now: at(22, 30), calendar: calendar) == [device.id: .succeeded])
    #expect(try await router.isBlocked(mac: device.mac))
    #expect(await engine.reconcile(devices: try await current(), now: at(23), calendar: calendar).isEmpty)       // already as desired
    #expect(await engine.reconcile(devices: try await current(), now: at(7, 0, day: 12), calendar: calendar) == [device.id: .succeeded])
    #expect(try await router.isBlocked(mac: device.mac) == false)
    #expect(try await db.audit.entries().contains { $0.actor == "policy #\(schedule.id)" && $0.action == "access.block" })

    // A pause ends by itself.
    try await engine.remove(schedule)
    _ = try await engine.add(AccessPolicy(kind: .pause, target: .device(device.id), until: at(13)))
    _ = await engine.reconcile(devices: try await current(), now: at(12), calendar: calendar)
    #expect(try await router.isBlocked(mac: device.mac))
    _ = await engine.reconcile(devices: try await current(), now: at(13, 1), calendar: calendar)
    #expect(try await router.isBlocked(mac: device.mac) == false)
    #expect(try await engine.allPolicies().isEmpty)                                                              // expired pause removed
}

@Test func groupPoliciesSkipTrustedDevices() {
    let policy = AccessPolicy(kind: .block, target: .group("Kids"))
    var device = Device(id: 5, mac: MACAddress(string: "00:00:00:00:00:05")!, interface: "", group: "Kids", firstSeen: .now, lastSeen: .now)
    #expect(AccessPolicy.blocking(device, among: [policy], at: .now) == policy)
    device.isTrusted = true
    #expect(AccessPolicy.blocking(device, among: [policy], at: .now) == nil)
    device.isTrusted = false
    device.group = "Guests"
    #expect(AccessPolicy.blocking(device, among: [policy], at: .now) == nil)
}

@Test func shapingChangeIsVerifiedRecordedAndReversible() async throws {
    let db = try AppDatabase.inMemory()
    let router = FakeRouter()
    let engine = QoSEngine(database: db, provider: router)
    let original = try #require(try await router.shapingQueues().first)
    var slower = original
    slower.downloadKbps = 40_000

    #expect(await engine.rollbackTarget(for: original, on: router.integration) == nil)
    #expect(await engine.apply(slower, on: router.integration) == .succeeded)
    #expect(try await router.shapingQueues() == [slower])
    #expect(try await db.audit.entries().first?.detail.contains("before=100000↓/20000↑") == true)

    // Roll back to what the router had before.
    let target = try #require(await engine.rollbackTarget(for: slower, on: router.integration))
    #expect(target == original)
    #expect(await engine.apply(target, on: router.integration, isRollback: true) == .succeeded)
    #expect(try await router.shapingQueues() == [original])
    #expect(try await db.audit.entries().first?.action == "qos.rollback")

    router.ignoreApply = true
    guard case .unverified = await engine.apply(slower, on: router.integration) else { Issue.record("must be unverified"); return }
    #expect(try await db.changes.all().count == 2)                       // unverified changes are not recorded as changes

    router.ignoreApply = false
    router.integration.managementEnabled = false
    let applied = router.applyCount
    guard case .failed = await engine.apply(slower, on: router.integration) else { Issue.record("read-only must fail"); return }
    #expect(router.applyCount == applied)
}

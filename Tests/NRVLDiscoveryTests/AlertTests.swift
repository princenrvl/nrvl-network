import Foundation
import NRVLCore
import NRVLPersistence
import Testing

private func snapshot(_ change: (inout NetworkSnapshot) -> Void = { _ in }) -> NetworkSnapshot {
    var value = NetworkSnapshot()
    value.gatewayAddress = "192.168.1.1"
    value.gatewayMAC = MACAddress(string: "b0:be:76:00:00:01")
    value.dnsServers = ["192.168.1.1"]
    value.gatewayLoss = 0
    value.internetLoss = 0
    value.internetLatency = 0.012
    change(&value)
    return value
}

private func kinds(_ previous: NetworkSnapshot?, _ current: NetworkSnapshot, _ settings: AlertSettings = AlertSettings()) -> [Alert.Kind] {
    AlertRules.evaluate(previous: previous, current: current, settings: settings).map(\.kind)
}

@Test func quietNetworkRaisesNothing() {
    #expect(kinds(nil, snapshot()).isEmpty)
    #expect(kinds(snapshot(), snapshot()).isEmpty)
}

@Test func conditionsAlertWhenTheyBeginNotWhileTheyLast() {
    let down = snapshot { $0.gatewayLoss = 1; $0.internetLoss = 1 }
    #expect(kinds(snapshot(), down) == [.gatewayOffline])          // the internet is not blamed when the gateway is down
    #expect(kinds(down, down).isEmpty)                             // still down: no repeat
    #expect(kinds(down, snapshot()).isEmpty)
    #expect(kinds(nil, down) == [.gatewayOffline])                 // already down at launch still alerts once

    let noInternet = snapshot { $0.internetLoss = 1 }
    #expect(kinds(snapshot(), noInternet) == [.internetOffline])

    let lossy = snapshot { $0.internetLoss = 0.2 }
    #expect(kinds(snapshot(), lossy) == [.packetLoss])
    #expect(kinds(snapshot(), snapshot { $0.internetLoss = 0.04 }).isEmpty)

    let slow = snapshot { $0.internetLatency = 0.3 }
    #expect(kinds(snapshot(), slow) == [.highLatency])
    var relaxed = AlertSettings()
    relaxed.latencyMilliseconds = 500
    #expect(kinds(snapshot(), slow, relaxed).isEmpty)

    var settings = AlertSettings()
    #expect(kinds(snapshot(), snapshot { $0.throughput = 50_000_000 }, settings).isEmpty)   // bandwidth check is off by default
    settings.bandwidthMbps = 100
    #expect(kinds(snapshot(), snapshot { $0.throughput = 50_000_000 }, settings) == [.bandwidth])   // 400 Mbit/s
}

@Test func securityObservationsCarryTheirEvidence() {
    let swapped = snapshot { $0.gatewayMAC = MACAddress(string: "de:ad:be:ef:00:01") }
    let alert = AlertRules.evaluate(previous: snapshot(), current: swapped, settings: AlertSettings()).first
    #expect(alert?.kind == .gatewayChanged)
    #expect(alert?.detail.contains("de:ad:be:ef:00:01") == true && alert?.detail.contains("b0:be:76:00:00:01") == true)
    #expect(kinds(nil, swapped).isEmpty)                           // nothing to compare with on the first scan

    #expect(kinds(snapshot(), snapshot { $0.gatewayAddress = "10.0.0.1"; $0.gatewayMAC = nil }) == [.gatewayChanged])
    #expect(kinds(snapshot(), snapshot { $0.dnsServers = ["9.9.9.9"] }) == [.dnsChanged])
    #expect(kinds(snapshot(), snapshot { $0.dnsServers = [] }).isEmpty)                      // offline is not a DNS change

    let conflict = snapshot { $0.conflicts = ["192.168.1.50"] }
    #expect(kinds(snapshot(), conflict) == [.addressConflict])
    #expect(kinds(conflict, conflict).isEmpty)

    let rules = snapshot { $0.firewallDigests = ["Router": "aaa"] }
    #expect(kinds(snapshot(), rules).isEmpty)                      // first sight of the rules is a baseline
    #expect(kinds(rules, snapshot { $0.firewallDigests = ["Router": "bbb"] }) == [.firewallChanged])

    let cert = snapshot { $0.certificateChanges = ["Router": "ffff"]; $0.integrationErrors = ["Router": "certificate changed"] }
    #expect(Set(kinds(snapshot(), cert)) == [.certificateChanged, .integrationDown])
    #expect(kinds(cert, cert).isEmpty)

    #expect(kinds(snapshot(), snapshot { $0.discovered = ["Printer"]; $0.disappeared = ["Phone"] }) == [.newDevice])   // "left" is off by default
    var all = AlertSettings()
    all.disabled = []
    #expect(kinds(snapshot(), snapshot { $0.disappeared = ["Phone"] }, all) == [.deviceLeft])
}

@Test func alertsAndSettingsPersist() async throws {
    let store = try AppDatabase.inMemory().alerts
    try await store.add([Alert(kind: .newDevice, subject: "Printer", detail: "first seen", date: Date(timeIntervalSince1970: 100)),
                         Alert(kind: .gatewayOffline, subject: "192.168.1.1", detail: "no reply", date: Date(timeIntervalSince1970: 200))])
    var alerts = try await store.all()
    #expect(alerts.map(\.kind) == [.gatewayOffline, .newDevice])
    try await store.acknowledge(id: alerts[0].id)
    alerts = try await store.all()
    #expect(alerts.map(\.acknowledged) == [true, false])
    try await store.acknowledge(id: nil)
    #expect(try await store.all().allSatisfy(\.acknowledged))
    #expect(try await store.all(since: Date(timeIntervalSince1970: 150)).count == 1)

    #expect(try await store.setting("alerts", as: AlertSettings.self) == nil)
    var settings = AlertSettings()
    settings.lossPercent = 12
    settings.disabled = [.bandwidth]
    try await store.setSetting("alerts", to: settings)
    #expect(try await store.setting("alerts", as: AlertSettings.self) == settings)
}

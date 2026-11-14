import Foundation
import NRVLCore
import Testing
@testable import NRVLAdapters

// These tests run the adapters against simulated devices. The replies are built from the vendors'
// published API descriptions, not recorded from real hardware.

/// Serves canned HTTP replies per host. Test-only.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Any)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func http(host: String, _ handler: @escaping Handler) throws -> PinnedHTTP {
        lock.withLock { handlers[host] = handler }
        return try PinnedHTTP(host: host, port: nil, pinnedCertificate: nil, protocolClasses: [StubProtocol.self])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {   // URLSession hands uploads over as a stream
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let handler = Self.lock.withLock { Self.handlers[request.url?.host ?? ""] }
        let (status, json) = handler?(request, body) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: UniFi

private func unifiClients() -> [[String: Any]] {
    var clients: [[String: Any]] = []
    for index in 0..<450 {
        let wireless = index % 2 == 0
        var client: [String: Any] = ["id": "c\(index)", "name": "client-\(index)", "access": ["type": "DEFAULT"]]
        client["type"] = wireless ? "WIRELESS" : "WIRED"
        client["ipAddress"] = "10.0.\(index / 250).\(index % 250 + 1)"
        client["macAddress"] = String(format: "a4:83:e7:00:%02x:%02x", index / 256, index % 256)
        client["uplinkDeviceId"] = wireless ? "d-ap" : "d-sw"
        clients.append(client)
    }
    clients.append(["id": "vpn", "name": "remote-user", "type": "VPN", "access": ["type": "DEFAULT"]])
    return clients
}

private func unifiDevices() -> [[String: Any]] {
    [
        ["id": "d-ap", "name": "Hall AP", "model": "U6 Pro", "macAddress": "f4:92:bf:00:00:01", "ipAddress": "10.0.0.2",
         "state": "ONLINE", "features": ["accessPoint"], "interfaces": ["radios"]],
        ["id": "d-sw", "name": "Core Switch", "model": "USW 24", "macAddress": "f4:92:bf:00:00:02", "ipAddress": "10.0.0.3",
         "state": "ONLINE", "features": ["switching"], "interfaces": ["ports"]],
    ]
}

private func simulatedUniFi(host: String, key: String = "good-key") throws -> PinnedHTTP {
    return try StubProtocol.http(host: host) { request, _ in
        guard request.value(forHTTPHeaderField: "X-API-Key") == key else { return (401, [:]) }
        let url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let path = url.path.replacingOccurrences(of: "/proxy/network/integration/v1", with: "")
        func page(_ items: [[String: Any]]) -> (Int, Any) {
            let offset = Int(url.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
            let limit = min(Int(url.queryItems?.first { $0.name == "limit" }?.value ?? "25") ?? 25, 200)
            let slice = Array(items.dropFirst(offset).prefix(limit))
            return (200, ["offset": offset, "limit": limit, "count": slice.count, "totalCount": items.count, "data": slice])
        }
        switch path {
        case "/info": return (200, ["applicationVersion": "9.1.0"])
        case "/sites": return page([["id": "s1", "internalReference": "default", "name": "Main Office"]])
        case "/sites/s1/clients": return page(unifiClients())
        case "/sites/s1/devices": return page(unifiDevices())
        default: return (404, ["statusCode": 404])
        }
    }
}

@Test func unifiReadsAllPagesAndMapsClients() async throws {
    let adapter = UniFiAdapter(http: try simulatedUniFi(host: "unifi-ok.test"), apiKey: "good-key", site: nil)
    #expect(try await adapter.identify() == AdapterIdentity(name: "Main Office", model: "UniFi Network", firmware: "9.1.0"))

    let clients = try await adapter.clients()
    #expect(clients.count == 450)                                   // three pages; the VPN client has no MAC and is skipped
    #expect(clients[0].connection == .wireless && clients[0].uplink == "Hall AP")
    #expect(clients[1].connection == .wired && clients[1].uplink == "Core Switch")
    #expect(clients[0].ipv4 == "10.0.0.1" && clients[0].hostname == "client-0")

    let devices = try await adapter.infrastructureDevices()
    #expect(devices.map(\.role) == ["Access point", "Switch"])

    // Nothing the official API cannot do may be advertised as possible.
    let capabilities = try await adapter.capabilities()
    for feature in [Feature.accessControl, .qos, .trafficStatistics] {
        if case .unsupported = capabilities[feature] {} else { Issue.record("\(feature) must be unsupported on UniFi") }
    }
}

@Test func unifiFailuresAreSpecific() async throws {
    let wrongKey = UniFiAdapter(http: try simulatedUniFi(host: "unifi-key.test"), apiKey: "bad", site: nil)
    await #expect(throws: AdapterError.authenticationFailed) { try await wrongKey.identify() }

    let wrongSite = UniFiAdapter(http: try simulatedUniFi(host: "unifi-site.test"), apiKey: "good-key", site: "Nowhere")
    await #expect(throws: AdapterError.self) { try await wrongSite.clients() }

    let garbage = try StubProtocol.http(host: "unifi-garbage.test") { _, _ in (200, ["unexpected": true]) }
    await #expect(throws: AdapterError.self) { try await UniFiAdapter(http: garbage, apiKey: "k", site: nil).identify() }
}

@Test func httpRefusesOtherHosts() async throws {
    let http = try StubProtocol.http(host: "pinned.test") { _, _ in (200, [:]) }
    await #expect(throws: AdapterError.self) { try await http.send("GET", "https://elsewhere.test/steal") }
    #expect(try await http.send("GET", "/fine").1.statusCode == 200)
}

// MARK: OpenWrt

/// A simulated OpenWrt router: sessions, read methods, and a firewall config with staged changes.
final class SimulatedOpenWrt: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: Set<String> = []
    private var firewall: [String: [String: Any]] = [
        "cfg01": [".type": "defaults", ".index": 0],
        "cfg02": [".type": "rule", ".index": 1, "name": "Allow-DHCP-Renew", "src": "wan", "proto": "udp", "dest_port": "68", "target": "ACCEPT"],
    ]
    private var sqm: [String: [String: Any]] = [
        "eth1": [".type": "queue", ".index": 0, "interface": "eth1", "enabled": "1", "download": "85000", "upload": "10000", "qdisc": "cake"],
    ]
    private var stagedSQM: [String: [String: Any]]?
    var hasSQM = true
    private var staged: [String: [String: Any]]?
    private(set) var applied = 0
    private(set) var confirmed = 0
    var readOnlyAccount = false
    var expireNextCall = false

    func handle(_ body: Data) -> (Int, Any) {
        lock.withLock {
            guard let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let params = request["params"] as? [Any], params.count == 4,
                  let session = params[0] as? String, let object = params[1] as? String, let method = params[2] as? String,
                  let arguments = params[3] as? [String: Any] else { return (400, [:]) }
            func ok(_ data: [String: Any] = [:]) -> (Int, Any) { (200, ["jsonrpc": "2.0", "id": 1, "result": [0, data]]) }
            let denied: (Int, Any) = (200, ["jsonrpc": "2.0", "id": 1, "error": ["code": -32002, "message": "Access denied"]])

            if object == "session", method == "login" {
                guard arguments["username"] as? String == "root", arguments["password"] as? String == "secret" else {
                    return (200, ["jsonrpc": "2.0", "id": 1, "result": [6]])
                }
                let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                sessions.insert(token)
                return ok(["ubus_rpc_session": token, "timeout": 300])
            }
            if expireNextCall {
                expireNextCall = false
                sessions.removeAll()
            }
            guard sessions.contains(session) else { return denied }

            switch (object, method) {
            case ("system", "board"):
                return ok(["hostname": "attic-router", "model": "Simulated AX3000", "release": ["distribution": "OpenWrt", "version": "24.10.0"]])
            case ("luci-rpc", "getHostHints"):
                return ok(["A4:83:E7:00:00:10": ["ipaddrs": ["192.168.1.10"], "ip6addrs": ["fd00::10"], "name": "laptop"],
                           "A4:83:E7:00:00:11": ["ipaddrs": ["192.168.1.11"], "ip6addrs": []]])
            case ("luci-rpc", "getDHCPLeases"):
                return ok(["dhcp_leases": [["macaddr": "A4:83:E7:00:00:11", "ipaddr": "192.168.1.11", "hostname": "phone", "expires": 100],
                                           ["macaddr": "A4:83:E7:00:00:12", "ipaddr": "192.168.1.12", "expires": 100]], "dhcp6_leases": []])
            case ("luci-rpc", "getWirelessDevices"):
                return ok(["radio0": ["up": true, "interfaces": [["ifname": "phy0-ap0", "config": ["mode": "ap", "ssid": "Attic"]]]]])
            case ("iwinfo", "assoclist"):
                return ok(["results": arguments["device"] as? String == "phy0-ap0" ? [["mac": "A4:83:E7:00:00:11", "signal": -51]] : []])
            case ("network.interface", "dump"):
                return ok(["interface": [
                    ["interface": "loopback", "ipv4-address": [["address": "127.0.0.1", "mask": 8]]],
                    ["interface": "lan", "device": "br-lan", "ipv4-address": [["address": "192.168.1.1", "mask": 24]]],
                    ["interface": "wan6"],
                ]])
            case ("uci", "get") where arguments["config"] as? String == "sqm":
                return hasSQM ? ok(["values": stagedSQM ?? sqm]) : (200, ["jsonrpc": "2.0", "id": 1, "result": [4]])
            case ("uci", "set") where arguments["config"] as? String == "sqm":
                if readOnlyAccount { return denied }
                var next = stagedSQM ?? sqm
                let section = arguments["section"] as? String ?? ""
                for (key, value) in arguments["values"] as? [String: Any] ?? [:] { next[section]?[key] = value }
                stagedSQM = next
                return ok()
            case ("uci", "get"):
                return ok(["values": staged ?? firewall])
            case ("uci", "add"), ("uci", "delete"):
                if readOnlyAccount { return denied }
                var next = staged ?? firewall
                if method == "add" {
                    var section = arguments["values"] as? [String: Any] ?? [:]
                    section[".type"] = arguments["type"]
                    section[".index"] = next.count
                    next["cfg\(next.count + 10)"] = section
                } else {
                    next[arguments["section"] as? String ?? ""] = nil
                }
                staged = next
                return ok()
            case ("uci", "apply"):
                guard arguments["rollback"] as? Bool == true else { return (200, ["jsonrpc": "2.0", "id": 1, "result": [2]]) }
                applied += 1
                return ok()
            case ("uci", "confirm"):
                if let staged { firewall = staged }
                staged = nil
                if let stagedSQM { sqm = stagedSQM }
                stagedSQM = nil
                confirmed += 1
                return ok()
            default:
                return (200, ["jsonrpc": "2.0", "id": 1, "result": [3]])   // not found
            }
        }
    }

    func adapter(host: String, password: String = "secret") throws -> OpenWrtAdapter {
        OpenWrtAdapter(http: try StubProtocol.http(host: host) { [self] _, body in handle(body) }, username: "root", password: password)
    }
}

@Test func openwrtReadsClientsNetworksAndRules() async throws {
    let router = SimulatedOpenWrt()
    let adapter = try router.adapter(host: "openwrt-read.test")

    #expect(try await adapter.identify() == AdapterIdentity(name: "attic-router", model: "Simulated AX3000", firmware: "OpenWrt 24.10.0"))

    let clients = try await adapter.clients()
    #expect(clients.map(\.mac.description) == ["a4:83:e7:00:00:10", "a4:83:e7:00:00:11", "a4:83:e7:00:00:12"])
    #expect(clients[0].hostname == "laptop" && clients[0].ipv6 == ["fd00::10"] && clients[0].connection == nil)   // wired is not assumed
    #expect(clients[1].hostname == "phone" && clients[1].connection == .wireless && clients[1].ssid == "Attic")
    #expect(clients[1].uplink == "attic-router phy0-ap0")
    #expect(clients[2].ipv4 == "192.168.1.12" && clients[2].hostname == nil)
    #expect(clients.allSatisfy { $0.isBlocked == false })

    #expect(try await adapter.networks() == [NetworkRecord(name: "lan", cidr: "192.168.1.0/24")])
    let rules = try await adapter.firewallRules()
    #expect(rules.map(\.name) == ["Allow-DHCP-Renew"] && rules[0].action == "ACCEPT")
    #expect(try await adapter.capabilities()[.accessControl] == .supported)
}

@Test func openwrtBlockAndUnblockRoundTrip() async throws {
    let router = SimulatedOpenWrt()
    let adapter = try router.adapter(host: "openwrt-block.test")
    let mac = MACAddress(string: "a4:83:e7:00:00:10")!

    #expect(try await adapter.isBlocked(mac: mac) == false)
    try await adapter.setBlocked(true, mac: mac)
    #expect(try await adapter.isBlocked(mac: mac))
    #expect(router.applied == 1 && router.confirmed == 1)           // applied with rollback, then confirmed

    let rule = try #require(try await adapter.firewallRules().first { $0.name == "nrvl-block-a483e7000010" })
    #expect(rule.action == "REJECT" && rule.summary.contains("A4:83:E7:00:00:10"))

    try await adapter.setBlocked(true, mac: mac)                    // already blocked: no second rule, no second apply
    #expect(router.applied == 1)
    #expect(try await adapter.firewallRules().count == 2)

    try await adapter.setBlocked(false, mac: mac)
    #expect(try await adapter.isBlocked(mac: mac) == false)
    #expect(try await adapter.firewallRules().map(\.name) == ["Allow-DHCP-Renew"])   // the router's own rule is untouched
}

@Test func openwrtFailuresAreSpecific() async throws {
    await #expect(throws: AdapterError.authenticationFailed) {
        try await SimulatedOpenWrt().adapter(host: "openwrt-pw.test", password: "wrong").identify()
    }

    let expiring = SimulatedOpenWrt()
    let adapter = try expiring.adapter(host: "openwrt-expire.test")
    _ = try await adapter.identify()
    expiring.expireNextCall = true
    #expect(try await adapter.identify().name == "attic-router")    // logs in again by itself

    let readOnly = SimulatedOpenWrt()
    readOnly.readOnlyAccount = true
    let limited = try readOnly.adapter(host: "openwrt-ro.test")
    await #expect(throws: AdapterError.self) { try await limited.setBlocked(true, mac: MACAddress(string: "a4:83:e7:00:00:10")!) }
    #expect(try await limited.isBlocked(mac: MACAddress(string: "a4:83:e7:00:00:10")!) == false)   // and nothing was applied
    #expect(readOnly.applied == 0)

    let notOpenWrt = try StubProtocol.http(host: "openwrt-404.test") { _, _ in (404, [:]) }
    await #expect(throws: AdapterError.self) { try await OpenWrtAdapter(http: notOpenWrt, username: "root", password: "x").identify() }
}

@Test func openwrtShapingReadAndChange() async throws {
    let router = SimulatedOpenWrt()
    let adapter = try router.adapter(host: "openwrt-sqm.test")

    let queue = try #require(try await adapter.shapingQueues().first)
    #expect(queue == ShapingQueue(id: "eth1", interface: "eth1", enabled: true, downloadKbps: 85_000, uploadKbps: 10_000, discipline: "cake"))
    #expect(try await adapter.capabilities()[.qos] == .supported)

    var changed = queue
    changed.downloadKbps = 50_000
    changed.enabled = false
    try await adapter.apply(changed)
    #expect(try await adapter.shapingQueues() == [changed])
    #expect(router.applied == 1 && router.confirmed == 1)

    var missing = queue
    missing.id = "nope"
    await #expect(throws: AdapterError.self) { try await adapter.apply(missing) }      // never creates queues
    var absurd = queue
    absurd.uploadKbps = -5
    await #expect(throws: AdapterError.self) { try await adapter.apply(absurd) }
    #expect(router.applied == 1)

    let bare = SimulatedOpenWrt()
    bare.hasSQM = false
    if case .unsupported = try await bare.adapter(host: "openwrt-nosqm.test").capabilities()[.qos] {} else { Issue.record("no SQM must be unsupported") }
}

import Foundation
import NRVLCore

/// OpenWrt through ubus JSON-RPC over HTTPS (`uhttpd-mod-ubus` + `rpcd`, the interface LuCI itself uses).
/// Reads leases, host hints, Wi-Fi associations, interfaces and firewall rules. Blocking a client adds a
/// firewall rule through `uci`, applied with the router's own timed rollback.
public actor OpenWrtAdapter: InfrastructureAdapter, AccessControlling, FirewallInspecting, LinkShaping, ConfigurationExporting {
    private let http: PinnedHTTP
    private let username: String
    private let password: String
    private var session: String?

    private static let nullSession = String(repeating: "0", count: 32)
    static let rulePrefix = "nrvl-block-"

    init(http: PinnedHTTP, username: String, password: String) {
        self.http = http
        self.username = username
        self.password = password
    }

    // MARK: Transport

    private enum CallError: Error { case accessDenied }

    private func raw(_ session: String, _ object: String, _ method: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "call", "params": [session, object, method, arguments],
        ])
        let (data, response) = try await http.send("POST", "/ubus", headers: ["Content-Type": "application/json"], body: body)
        guard response.statusCode == 200, let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterError.protocolError("HTTP \(response.statusCode) from /ubus — is uhttpd-mod-ubus installed?")
        }
        if let error = reply["error"] as? [String: Any] {
            if error["code"] as? Int == -32002 { throw CallError.accessDenied }
            throw AdapterError.protocolError("ubus \(object).\(method): \(error["message"] as? String ?? "error")")
        }
        guard let result = reply["result"] as? [Any], let code = result.first as? Int else {
            throw AdapterError.protocolError("ubus \(object).\(method): malformed reply")
        }
        switch code {
        case 0: return result.count > 1 ? (result[1] as? [String: Any] ?? [:]) : [:]
        case 6: throw CallError.accessDenied
        case 3, 4: throw AdapterError.unsupported("This router has no ubus \(object).\(method).")
        default: throw AdapterError.protocolError("ubus \(object).\(method) failed with status \(code)")
        }
    }

    private func login() async throws -> String {
        do {
            let reply = try await raw(Self.nullSession, "session", "login", ["username": username, "password": password])
            guard let token = reply["ubus_rpc_session"] as? String else { throw AdapterError.authenticationFailed }
            return token
        } catch CallError.accessDenied {
            throw AdapterError.authenticationFailed
        }
    }

    /// Calls a ubus method, logging in first and once more if the session has expired.
    private func call(_ object: String, _ method: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        for attempt in 0..<2 {
            let token: String
            if let session { token = session } else { token = try await login() }
            session = token
            do {
                return try await raw(token, object, method, arguments)
            } catch CallError.accessDenied where attempt == 0 {
                session = nil   // expired, or really forbidden: the fresh login decides
            } catch CallError.accessDenied {
                break
            }
        }
        throw AdapterError.permissionDenied("ubus \(object).\(method)")
    }

    // MARK: Reading

    public func identify() async throws -> AdapterIdentity {
        let board = try await call("system", "board")
        let release = board["release"] as? [String: Any]
        return AdapterIdentity(name: board["hostname"] as? String ?? "OpenWrt",
                               model: board["model"] as? String ?? "OpenWrt device",
                               firmware: [release?["distribution"], release?["version"]].compactMap { $0 as? String }.joined(separator: " "))
    }

    public func capabilities() async throws -> CapabilitySet {
        var set: CapabilitySet = [
            .infrastructureDevices: .readOnly,
            .trafficStatistics: .unsupported("OpenWrt does not count traffic per client without an add-on such as nlbwmon, which is not read yet."),
            .configurationBackup: .readOnly,
        ]
        set[.clientInventory] = await permitted("luci-rpc", "getHostHints") ? .readOnly
            : .unsupported("The account may not read host information (luci-rpc getHostHints).")
        set[.networks] = await permitted("network.interface", "dump") ? .readOnly
            : .unsupported("The account may not read interfaces (network.interface dump).")
        let firewall = await permitted("uci", "get", ["config": "firewall"])
        set[.firewall] = firewall ? .readOnly : .unsupported("The account may not read the firewall configuration.")
        set[.qos] = ((try? await shapingQueues()) ?? []).isEmpty
            ? .unsupported("No SQM queue is configured. Install sqm-scripts on the router and create a queue for the WAN interface. Per-device limits are not available on OpenWrt without unofficial add-ons.")
            : .supported
        set[.accessControl] = firewall ? .supported : .unsupported("Blocking needs read and write access to the firewall configuration.")
        return set
    }

    private func permitted(_ object: String, _ method: String, _ arguments: [String: Any] = [:]) async -> Bool {
        (try? await call(object, method, arguments)) != nil
    }

    public func clients() async throws -> [DeviceSighting] {
        var byMAC: [MACAddress: DeviceSighting] = [:]

        // Known hosts: { "AA:BB:…": { "ipaddrs": […], "ip6addrs": […], "name": "…" } }
        for (key, value) in try await call("luci-rpc", "getHostHints") {
            guard let mac = MACAddress(string: key), !mac.isMulticast, let hint = value as? [String: Any] else { continue }
            byMAC[mac] = DeviceSighting(mac: mac, ipv4: (hint["ipaddrs"] as? [String])?.first,
                                        ipv6: hint["ip6addrs"] as? [String] ?? [], hostname: hint["name"] as? String)
        }
        // DHCP leases carry the name the client asked for. Optional: needs its own permission.
        if let leases = try? await call("luci-rpc", "getDHCPLeases") {
            for lease in leases["dhcp_leases"] as? [[String: Any]] ?? [] {
                guard let mac = (lease["macaddr"] as? String).flatMap(MACAddress.init(string:)) else { continue }
                var entry = byMAC[mac] ?? DeviceSighting(mac: mac)
                entry.ipv4 = entry.ipv4 ?? lease["ipaddr"] as? String
                entry.hostname = entry.hostname ?? lease["hostname"] as? String
                byMAC[mac] = entry
            }
        }
        // Wi-Fi associations: the only clients whose connection type the router can state.
        let router = (try? await identify().name) ?? "OpenWrt"
        if let radios = try? await call("luci-rpc", "getWirelessDevices") {
            for radio in radios.values {
                for interface in (radio as? [String: Any])?["interfaces"] as? [[String: Any]] ?? [] {
                    guard let name = interface["ifname"] as? String,
                          let stations = try? await call("iwinfo", "assoclist", ["device": name]) else { continue }
                    let ssid = (interface["config"] as? [String: Any])?["ssid"] as? String
                    for station in stations["results"] as? [[String: Any]] ?? [] {
                        guard let mac = (station["mac"] as? String).flatMap(MACAddress.init(string:)) else { continue }
                        var entry = byMAC[mac] ?? DeviceSighting(mac: mac)
                        entry.connection = .wireless
                        entry.ssid = ssid
                        entry.uplink = "\(router) \(name)"
                        byMAC[mac] = entry
                    }
                }
            }
        }
        if let blocked = try? await blockedMACs() {
            for mac in byMAC.keys { byMAC[mac]?.isBlocked = blocked.contains(mac) }
        }
        return byMAC.values.sorted { $0.mac.description < $1.mac.description }
    }

    public func infrastructureDevices() async throws -> [InfrastructureDevice] {
        let identity = try await identify()
        return [InfrastructureDevice(name: identity.name, model: identity.model, role: "Router", ipv4: http.baseURL.host,
                                     firmware: identity.firmware)]
    }

    public func networks() async throws -> [NetworkRecord] {
        let dump = try await call("network.interface", "dump")
        return (dump["interface"] as? [[String: Any]] ?? []).compactMap { interface in
            guard let name = interface["interface"] as? String, name != "loopback",
                  let address = (interface["ipv4-address"] as? [[String: Any]])?.first,
                  let ip = address["address"] as? String, let prefix = address["mask"] as? Int, (0...32).contains(prefix),
                  let value = IPv4.parse(ip) else { return nil }
            let mask: UInt32 = prefix == 0 ? 0 : ~0 << (32 - UInt32(prefix))
            return NetworkRecord(name: name, cidr: "\(IPv4.string(value & mask))/\(prefix)")
        }
    }

    // MARK: Firewall and blocking

    private func sections(of config: String) async throws -> [String: [String: Any]] {
        let reply = try await call("uci", "get", ["config": config])
        return (reply["values"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    private func firewallSections() async throws -> [String: [String: Any]] { try await sections(of: "firewall") }

    /// A JSON snapshot of the main UCI configurations, as the router reports them. It contains secrets
    /// (Wi-Fi keys), so callers must encrypt it. It is a record for comparison and manual restore, not a flashable backup.
    public func exportConfiguration() async throws -> Data {
        var snapshot: [String: Any] = [:]
        for config in ["network", "wireless", "firewall", "dhcp", "system", "sqm"] {
            if let sections = try? await sections(of: config), !sections.isEmpty { snapshot[config] = sections }
        }
        guard !snapshot.isEmpty else { throw AdapterError.permissionDenied("reading the router's configuration") }
        return try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Traffic shaping (SQM)

    public func shapingQueues() async throws -> [ShapingQueue] {
        try await sections(of: "sqm")
            .filter { $0.value[".type"] as? String == "queue" }
            .map { id, queue in
                func number(_ key: String) -> Int { Int(queue[key] as? String ?? "") ?? 0 }
                return ShapingQueue(id: id, interface: queue["interface"] as? String ?? "?", enabled: queue["enabled"] as? String == "1",
                                    downloadKbps: number("download"), uploadKbps: number("upload"), discipline: queue["qdisc"] as? String)
            }
            .sorted { $0.id < $1.id }
    }

    /// Changes only `enabled`, `download` and `upload` of an existing SQM queue, with the router's timed rollback.
    public func apply(_ queue: ShapingQueue) async throws {
        guard try await shapingQueues().contains(where: { $0.id == queue.id }) else {
            throw AdapterError.unsupported("The router has no SQM queue \"\(queue.id)\".")
        }
        guard (0...10_000_000).contains(queue.downloadKbps), (0...10_000_000).contains(queue.uploadKbps) else {
            throw AdapterError.unsupported("Rates must be between 0 and 10,000,000 kbit/s.")
        }
        _ = try await call("uci", "set", ["config": "sqm", "section": queue.id, "values": [
            "enabled": queue.enabled ? "1" : "0", "download": String(queue.downloadKbps), "upload": String(queue.uploadKbps),
        ]])
        _ = try await call("uci", "apply", ["rollback": true, "timeout": 30])
        _ = try await call("uci", "confirm")
    }

    public func firewallRules() async throws -> [FirewallRule] {
        try await firewallSections()
            .filter { $0.value[".type"] as? String == "rule" }
            .sorted { ($0.value[".index"] as? Int ?? 0) < ($1.value[".index"] as? Int ?? 0) }
            .map { id, rule in
                func text(_ key: String) -> String? { rule[key] as? String ?? (rule[key] as? [String])?.joined(separator: ",") }
                let summary = [("from", "src"), ("to", "dest"), ("proto", "proto"), ("port", "dest_port"), ("mac", "src_mac")]
                    .compactMap { label, key in text(key).map { "\(label) \($0)" } }.joined(separator: " · ")
                return FirewallRule(id: id, name: text("name") ?? id, action: text("target") ?? "—", summary: summary,
                                    enabled: text("enabled") != "0")
            }
    }

    private func blockRuleName(_ mac: MACAddress) -> String { Self.rulePrefix + mac.description.replacingOccurrences(of: ":", with: "") }

    private func blockedMACs() async throws -> Set<MACAddress> {
        Set(try await firewallSections().values.compactMap { rule in
            guard (rule["name"] as? String)?.hasPrefix(Self.rulePrefix) == true, rule["enabled"] as? String != "0" else { return nil }
            return (rule["src_mac"] as? String ?? (rule["src_mac"] as? [String])?.first).flatMap(MACAddress.init(string:))
        })
    }

    public func isBlocked(mac: MACAddress) async throws -> Bool {
        try await blockedMACs().contains(mac)
    }

    /// Adds or removes one rule named `nrvl-block-<mac>` that rejects the device's traffic from zone "lan" to zone "wan".
    /// The device keeps local access. Only rules this app created are ever touched.
    // shortcut: assumes the default zone names "lan" and "wan"; make them configurable for routers that rename them.
    public func setBlocked(_ blocked: Bool, mac: MACAddress) async throws {
        let name = blockRuleName(mac)
        let existing = try await firewallSections().filter { $0.value["name"] as? String == name }.map(\.key)
        if blocked {
            guard existing.isEmpty else { return }
            _ = try await call("uci", "add", ["config": "firewall", "type": "rule", "values": [
                "name": name, "src": "lan", "dest": "wan", "src_mac": mac.description.uppercased(), "proto": "all", "target": "REJECT",
            ]])
        } else {
            guard !existing.isEmpty else { return }
            for section in existing { _ = try await call("uci", "delete", ["config": "firewall", "section": section]) }
        }
        // The router applies the change and reverts it by itself unless confirmed within the timeout —
        // so a change that cuts off this session cannot stick.
        _ = try await call("uci", "apply", ["rollback": true, "timeout": 30])
        _ = try await call("uci", "confirm")
    }
}

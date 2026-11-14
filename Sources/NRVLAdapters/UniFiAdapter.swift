import Foundation
import NRVLCore

/// Ubiquiti UniFi through the official local Network Integration API (`/proxy/network/integration/v1`, API key).
/// Read-only: that API documents no way to block a client or shape its traffic, and the undocumented
/// controller API is deliberately not used.
public struct UniFiAdapter: InfrastructureAdapter {
    let http: PinnedHTTP
    let apiKey: String
    /// Site name or internal reference; nil picks the first site.
    let site: String?

    private static let base = "/proxy/network/integration/v1"
    private static let pageSize = 200   // the API's maximum

    private struct Page<Item: Decodable>: Decodable {
        let count: Int
        let totalCount: Int
        let data: [Item]
    }
    private struct Info: Decodable { let applicationVersion: String }
    private struct Site: Decodable { let id: String; let name: String; let internalReference: String? }
    private struct Client: Decodable {
        let name: String?
        let type: String
        let ipAddress: String?
        let macAddress: String?
        let uplinkDeviceId: String?
    }
    private struct Device: Decodable {
        let id: String
        let name: String
        let model: String?
        let macAddress: String?
        let ipAddress: String?
        let features: [String]?
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        try await http.json(type, "GET", Self.base + path, headers: ["X-API-Key": apiKey, "Accept": "application/json"])
    }

    private func all<Item: Decodable>(_ type: Item.Type, _ path: String) async throws -> [Item] {
        var items: [Item] = []
        for _ in 0..<100 {   // hard stop: 20,000 entries
            let page = try await get(Page<Item>.self, "\(path)?offset=\(items.count)&limit=\(Self.pageSize)")
            items += page.data
            if page.data.isEmpty || items.count >= page.totalCount { break }
        }
        return items
    }

    private func selectedSite() async throws -> Site {
        let sites = try await all(Site.self, "/sites")
        if let site, let match = sites.first(where: { $0.name == site || $0.internalReference == site }) { return match }
        if let site, !site.isEmpty { throw AdapterError.protocolError("The console has no site named \"\(site)\".") }
        guard let first = sites.first else { throw AdapterError.protocolError("The console reports no sites.") }
        return first
    }

    public func identify() async throws -> AdapterIdentity {
        let info = try await get(Info.self, "/info")
        return AdapterIdentity(name: try await selectedSite().name, model: "UniFi Network", firmware: info.applicationVersion)
    }

    public func capabilities() async throws -> CapabilitySet {
        let noOfficialWay = "The official UniFi Integration API does not offer this. NRVL Network does not use the undocumented controller API."
        return [
            .clientInventory: .readOnly,
            .infrastructureDevices: .readOnly,
            .networks: .unsupported("Networks and VLANs are not read from UniFi yet."),
            .trafficStatistics: .unsupported("The official UniFi Integration API does not report per-client traffic."),
            .accessControl: .unsupported(noOfficialWay),
            .qos: .unsupported(noOfficialWay),
            .firewall: .unsupported("Firewall rules are not read from UniFi yet."),
            .configurationBackup: .unsupported(noOfficialWay),
        ]
    }

    public func clients() async throws -> [DeviceSighting] {
        let site = try await selectedSite()
        let devices = Dictionary(try await all(Device.self, "/sites/\(site.id)/devices").map { ($0.id, $0.name) },
                                 uniquingKeysWith: { first, _ in first })
        return try await all(Client.self, "/sites/\(site.id)/clients").compactMap { client in
            // VPN and Teleport clients have no MAC address on this network.
            guard let mac = client.macAddress.flatMap(MACAddress.init(string:)) else { return nil }
            let connection: ConnectionType? = client.type == "WIRED" ? .wired : client.type == "WIRELESS" ? .wireless : nil
            return DeviceSighting(mac: mac, ipv4: client.ipAddress.flatMap { IPv4.parse($0) == nil ? nil : $0 },
                                  hostname: client.name.flatMap { $0.isEmpty ? nil : $0 }, connection: connection,
                                  uplink: client.uplinkDeviceId.flatMap { devices[$0] })
        }
    }

    public func infrastructureDevices() async throws -> [InfrastructureDevice] {
        let site = try await selectedSite()
        let roles = ["gateway": "Gateway", "switching": "Switch", "accessPoint": "Access point"]
        return try await all(Device.self, "/sites/\(site.id)/devices").map { device in
            let role = (device.features ?? []).compactMap { roles[$0] }.sorted().joined(separator: " + ")
            return InfrastructureDevice(name: device.name, model: device.model, role: role.isEmpty ? "UniFi device" : role,
                                        mac: device.macAddress.flatMap(MACAddress.init(string:)), ipv4: device.ipAddress)
        }
    }

    public func networks() async throws -> [NetworkRecord] { [] }
}

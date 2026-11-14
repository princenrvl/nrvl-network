import Foundation
import LocalAuthentication
import NRVLAdapters
import NRVLCore
import NRVLPersistence

/// The outcome of one attempted change on real infrastructure.
public enum ChangeOutcome: Sendable, Equatable {
    case succeeded
    case failed(String)
    /// The device accepted the request but its state, read back, is not what was asked for.
    case unverified(String)

    var audit: AuditEntry.Outcome {
        switch self {
        case .succeeded: .succeeded
        case .failed: .failed
        case .unverified: .unverified
        }
    }
}

/// Blocks and unblocks devices through a router integration — never by any other means.
/// Every attempt is checked for capability first, verified by reading the router back, and written to the audit log.
public actor AccessControlEngine {
    public enum Availability: Sendable, Equatable {
        case available(Integration)
        case unavailable(String)
    }

    private let provider: any AdapterProviding
    private let devices: DeviceStore
    private let policies: PolicyStore
    private let audit: AuditLog

    public init(database: AppDatabase, provider: any AdapterProviding) {
        self.provider = provider
        devices = database.devices
        policies = database.policies
        audit = database.audit
    }

    /// Whether this device can be blocked right now, and if not, exactly why.
    public func availability(for device: Device, gateway: String? = nil) async -> Availability {
        if device.isThisMac { return .unavailable("This is the Mac running NRVL Network.") }
        if let gateway, device.ipv4 == gateway { return .unavailable("This is your default gateway. Blocking it would cut off the whole network.") }
        guard let id = device.integrationID else {
            return .unavailable("No router integration reports this device. Only a router can block a device; this Mac cannot.")
        }
        guard let integration = (try? await provider.all())?.first(where: { $0.id == id }) else {
            return .unavailable("The integration that reported this device no longer exists.")
        }
        guard integration.managementEnabled else {
            return .unavailable("\(integration.name) is read-only. Turn on management for it in Access Control first.")
        }
        do {
            let adapter = try await provider.adapter(for: integration)
            guard adapter is any AccessControlling else {
                return .unavailable("\(integration.kind.title) offers no documented way to block a device.")
            }
            switch try await adapter.capabilities()[.accessControl] {
            case .supported?: return .available(integration)
            case .unsupported(let reason)?: return .unavailable(reason)
            default: return .unavailable("\(integration.name) does not allow access control with this account.")
            }
        } catch {
            return .unavailable("\(integration.name) cannot be reached: \(error.localizedDescription)")
        }
    }

    /// Applies one change and verifies it. `initiator` is the macOS user, or the policy that triggered it.
    public func setBlocked(_ blocked: Bool, device: Device, gateway: String? = nil, initiator: String = NSUserName()) async -> ChangeOutcome {
        let action = blocked ? "access.block" : "access.unblock"
        let target = "\(device.mac) \(device.customName ?? device.hostname ?? "")".trimmingCharacters(in: .whitespaces)
        var detail = ""
        let outcome: ChangeOutcome
        switch await availability(for: device, gateway: gateway) {
        case .unavailable(let reason):
            outcome = .failed(reason)
        case .available(let integration):
            detail = "integration=\(integration.name) "
            do {
                guard let adapter = try await provider.adapter(for: integration) as? any AccessControlling else {
                    throw AdapterError.unsupported("access control")
                }
                let before = try await adapter.isBlocked(mac: device.mac)
                try await adapter.setBlocked(blocked, mac: device.mac)
                let after = try await adapter.isBlocked(mac: device.mac)
                detail += "before=\(before ? "blocked" : "allowed") after=\(after ? "blocked" : "allowed")"
                if after == blocked {
                    try? await devices.setBlocked(after, id: device.id)
                    outcome = .succeeded
                } else {
                    outcome = .unverified("\(integration.name) accepted the request but still reports the device as \(after ? "blocked" : "allowed").")
                }
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
        if case .failed(let reason) = outcome { detail += "error=\(reason)" }
        if case .unverified(let reason) = outcome { detail += " note=\(reason)" }
        // If even the audit write fails, report failure rather than a change with no record.
        do {
            try await audit.append(action: action, target: target, detail: detail, outcome: outcome.audit, actor: initiator)
        } catch {
            return .failed("The change could not be recorded in the audit log: \(error.localizedDescription)")
        }
        return outcome
    }

    public func allPolicies() async throws -> [AccessPolicy] { try await policies.all() }

    public func add(_ policy: AccessPolicy) async throws -> AccessPolicy {
        let saved = try await policies.add(policy)
        try await audit.append(action: "access.policy.add", target: Self.describe(saved.target),
                               detail: "kind=\(saved.kind.rawValue) id=\(saved.id)", outcome: .succeeded)
        return saved
    }

    public func remove(_ policy: AccessPolicy) async throws {
        try await policies.remove(id: policy.id)
        try await audit.append(action: "access.policy.remove", target: Self.describe(policy.target),
                               detail: "kind=\(policy.kind.rawValue) id=\(policy.id)", outcome: .succeeded)
    }

    /// Removes the manual block and pause for a device, so reconciliation lets it back in (unless a schedule still applies).
    public func clearManualBlock(for device: Device) async throws {
        try await policies.clearManual(device: device.id)
    }

    /// Brings routers in line with the policies: blocks what should be blocked now and releases what should not.
    /// Only devices whose router state is known, on integrations with management enabled, are touched.
    @discardableResult
    public func reconcile(devices current: [Device], gateway: String? = nil, now: Date = Date(),
                          calendar: Calendar = .current) async -> [Device.ID: ChangeOutcome] {
        try? await policies.removeExpired(now: now)
        guard let all = try? await policies.all() else { return [:] }
        var results: [Device.ID: ChangeOutcome] = [:]
        for device in current {
            guard let isBlocked = device.isBlocked else { continue }
            let policy = AccessPolicy.blocking(device, among: all, at: now, calendar: calendar)
            guard (policy != nil) != isBlocked else { continue }
            guard case .available = await availability(for: device, gateway: gateway) else { continue }
            results[device.id] = await setBlocked(policy != nil, device: device, gateway: gateway,
                                                  initiator: policy.map { "policy #\($0.id)" } ?? "policy ended")
        }
        return results
    }

    private static func describe(_ target: AccessPolicy.Target) -> String {
        switch target {
        case .device(let id): "device #\(id)"
        case .group(let name): "group \(name)"
        }
    }
}

public enum Authenticator {
    /// Asks macOS to confirm the person at the keyboard (Touch ID, Apple Watch or account password).
    public static func confirm(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        // A Mac with no password set cannot authenticate; refuse rather than wave the change through.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

import Foundation
import NRVLAdapters
import NRVLCore
import NRVLPersistence

/// Changes link shaping on a router integration: capability check, apply, verify by reading back, audit, and
/// a stored before/after record that makes rollback possible.
public actor QoSEngine {
    private let provider: any AdapterProviding
    private let changes: ChangeStore
    private let audit: AuditLog

    public init(database: AppDatabase, provider: any AdapterProviding) {
        self.provider = provider
        changes = database.changes
        audit = database.audit
    }

    /// Current queues of an integration, or the reason they cannot be read.
    public func queues(of integration: Integration) async -> Result<[ShapingQueue], AdapterError> {
        do {
            guard let adapter = try await provider.adapter(for: integration) as? any LinkShaping else {
                return .failure(.unsupported("\(integration.kind.title) offers no documented traffic shaping."))
            }
            return .success(try await adapter.shapingQueues())
        } catch {
            return .failure(error as? AdapterError ?? .protocolError(error.localizedDescription))
        }
    }

    /// The queue as it was before the most recent verified change, if there is one to go back to.
    public func rollbackTarget(for queue: ShapingQueue, on integration: Integration) async -> ShapingQueue? {
        guard let record = try? await changes.last(integrationID: integration.id, subject: Self.subject(queue)),
              let before = try? JSONDecoder().decode(ShapingQueue.self, from: record.before), before != queue else { return nil }
        return before
    }

    public func apply(_ desired: ShapingQueue, on integration: Integration, initiator: String = NSUserName(),
                      isRollback: Bool = false) async -> ChangeOutcome {
        let action = isRollback ? "qos.rollback" : "qos.apply"
        let target = "\(integration.name) \(Self.subject(desired))"
        var detail = ""
        let outcome: ChangeOutcome
        do {
            guard integration.managementEnabled else {
                throw AdapterError.permissionDenied("\(integration.name) is read-only. Enable management for it in Access Control first.")
            }
            guard let adapter = try await provider.adapter(for: integration) as? any LinkShaping else {
                throw AdapterError.unsupported("traffic shaping")
            }
            guard let before = try await adapter.shapingQueues().first(where: { $0.id == desired.id }) else {
                throw AdapterError.unsupported("queue \(desired.id) does not exist on the router")
            }
            detail = "before=\(Self.describe(before)) requested=\(Self.describe(desired))"
            try await adapter.apply(desired)
            let after = try await adapter.shapingQueues().first { $0.id == desired.id }
            detail += " after=\(after.map(Self.describe) ?? "missing")"
            if let after, after.enabled == desired.enabled, after.downloadKbps == desired.downloadKbps, after.uploadKbps == desired.uploadKbps {
                try await changes.add(integrationID: integration.id, subject: Self.subject(desired),
                                      before: try JSONEncoder().encode(before), after: try JSONEncoder().encode(after))
                outcome = .succeeded
            } else {
                outcome = .unverified("The router accepted the request but reports \(after.map(Self.describe) ?? "no such queue").")
            }
        } catch {
            outcome = .failed(error.localizedDescription)
            detail += " error=\(error.localizedDescription)"
        }
        do {
            try await audit.append(action: action, target: target, detail: detail, outcome: outcome.audit, actor: initiator)
        } catch {
            return .failed("The change could not be recorded in the audit log: \(error.localizedDescription)")
        }
        return outcome
    }

    static func subject(_ queue: ShapingQueue) -> String { "sqm/\(queue.id)" }

    public static func describe(_ queue: ShapingQueue) -> String {
        queue.enabled ? "\(queue.downloadKbps)↓/\(queue.uploadKbps)↑ kbit/s" : "off (\(queue.downloadKbps)↓/\(queue.uploadKbps)↑ kbit/s)"
    }
}

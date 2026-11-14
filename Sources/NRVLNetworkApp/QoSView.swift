import NRVLAdapters
import NRVLCore
import NRVLServices
import NRVLTelemetry
import Observation
import SwiftUI

@MainActor @Observable
final class QoSModel {
    struct Entry: Identifiable {
        var id: Integration.ID { integration.id }
        let integration: Integration
        let queues: Result<[ShapingQueue], AdapterError>
        /// Queue id → what it was before the last verified change.
        let rollback: [String: ShapingQueue]
    }

    struct Edit {
        let integration: Integration
        let current: ShapingQueue
        var enabled: Bool
        var download: String
        var upload: String
        var isRollback = false

        var desired: ShapingQueue? {
            guard let down = Int(download), let up = Int(upload), down >= 0, up >= 0 else { return nil }
            var queue = current
            queue.enabled = enabled
            queue.downloadKbps = down
            queue.uploadKbps = up
            return queue
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var message: (text: String, isError: Bool)?
    private(set) var isWorking = false
    var edit: Edit?

    let engine: QoSEngine
    let integrations: IntegrationsModel

    init(engine: QoSEngine, integrations: IntegrationsModel) {
        self.engine = engine
        self.integrations = integrations
    }

    func refresh() async {
        await integrations.refresh()
        var result: [Entry] = []
        for integration in integrations.integrations {
            let queues = await engine.queues(of: integration)
            var rollback: [String: ShapingQueue] = [:]
            for queue in (try? queues.get()) ?? [] { rollback[queue.id] = await engine.rollbackTarget(for: queue, on: integration) }
            result.append(Entry(integration: integration, queues: queues, rollback: rollback))
        }
        entries = result
    }

    func beginEdit(_ queue: ShapingQueue, on integration: Integration) {
        edit = Edit(integration: integration, current: queue, enabled: queue.enabled,
                    download: String(queue.downloadKbps), upload: String(queue.uploadKbps))
    }

    func beginRollback(_ queue: ShapingQueue, to previous: ShapingQueue, on integration: Integration) {
        edit = Edit(integration: integration, current: queue, enabled: previous.enabled,
                    download: String(previous.downloadKbps), upload: String(previous.uploadKbps), isRollback: true)
    }

    func confirmEdit() async {
        guard let edit, let desired = edit.desired else { return }
        self.edit = nil
        guard await Authenticator.confirm("change traffic shaping on \(edit.integration.name)") else {
            message = ("Not authenticated — nothing was changed.", true)
            return
        }
        isWorking = true
        defer { isWorking = false }
        switch await engine.apply(desired, on: edit.integration, isRollback: edit.isRollback) {
        case .succeeded: message = ("Shaping on \(desired.interface) is now \(QoSEngine.describe(desired)) — confirmed by the router.", false)
        case .failed(let reason): message = ("Change failed: \(reason)", true)
        case .unverified(let reason): message = ("Change could not be confirmed: \(reason)", true)
        }
        await refresh()
    }
}

struct QoSView: View {
    @Bindable var model: QoSModel
    let telemetry: TelemetryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = model.message {
                    Banner(symbol: message.isError ? "exclamationmark.triangle" : "checkmark.circle", color: message.isError ? .red : .green, text: message.text)
                }
                if model.entries.isEmpty {
                    Card("Traffic Shaping", symbol: "speedometer") {
                        Text("No integration is configured. QoS is applied by the router, so it needs a router integration that supports it.").foregroundStyle(.secondary)
                    }
                }
                ForEach(model.entries) { entry in shapingCard(entry) }
                qualityCard
                unavailableCard
            }
            .padding(20)
        }
        .task { await model.refresh() }
        .sheet(isPresented: Binding(get: { model.edit != nil }, set: { if !$0 { model.edit = nil } })) { editSheet }
    }

    private func shapingCard(_ entry: QoSModel.Entry) -> some View {
        Card("Link Shaping — \(entry.integration.name)", symbol: "speedometer",
             badge: Badge(text: entry.integration.managementEnabled ? "Management on" : "Read-only", color: entry.integration.managementEnabled ? .orange : .secondary)) {
            switch entry.queues {
            case .failure(let error):
                Text(error.localizedDescription).foregroundStyle(.secondary)
            case .success(let queues) where queues.isEmpty:
                Text("The router has no shaping queue configured. On OpenWrt, install sqm-scripts and create a queue for the WAN interface; it will then appear here.")
                    .foregroundStyle(.secondary)
            case .success(let queues):
                ForEach(queues) { queue in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Interface \(queue.interface)").font(.headline)
                            Text(QoSEngine.describe(queue) + (queue.discipline.map { " · \($0)" } ?? "")).monospacedDigit()
                        }
                        Spacer()
                        if let previous = entry.rollback[queue.id] {
                            Button("Roll Back to \(QoSEngine.describe(previous))…") { model.beginRollback(queue, to: previous, on: entry.integration) }
                        }
                        Button("Change…") { model.beginEdit(queue, on: entry.integration) }
                    }
                    .disabled(model.isWorking || !entry.integration.managementEnabled)
                }
                if !entry.integration.managementEnabled {
                    Text("Read-only. Enable management for this integration in Access Control to change shaping.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Shaping limits the whole link to slightly below its real speed so the router, not your provider, decides what waits. That is what keeps latency low for calls and games while others download.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var qualityCard: some View {
        Card("Latency, Jitter and Loss Right Now", symbol: "waveform.path.ecg", badge: Freshness.live.badge) {
            LabeledContent("Internet latency", value: telemetry.internet.averageLatency.map { String(format: "%.1f ms", $0 * 1000) } ?? "No reply")
            LabeledContent("Jitter", value: telemetry.internet.jitter.map { String(format: "%.1f ms", $0 * 1000) } ?? "—")
            LabeledContent("Packet loss", value: telemetry.internet.lossFraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
            Text("Measured from this Mac over the last minute. Watch these while the link is busy to judge whether shaping is helping; history is under Traffic Analytics.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var unavailableCard: some View {
        Card("Not Available with the Connected Integrations", symbol: "nosign") {
            let none = "Neither the official UniFi API nor stock OpenWrt offers a documented way to do this."
            ForEach(["Per-device download and upload limits", "Device prioritisation", "Application-category, gaming and video-call prioritisation",
                     "Scheduled QoS policies", "Queue statistics"], id: \.self) { feature in
                LabeledContent(feature) { Badge(text: "Unsupported", color: .secondary) }
            }
            Text(none + " These appear here when an integration that supports them is added (MikroTik queues are the planned first source). Nothing is simulated in the meantime.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var editSheet: some View {
        if model.edit != nil {
            let edit = Binding(get: { model.edit! }, set: { model.edit = $0 })
            VStack(alignment: .leading, spacing: 12) {
                Text(edit.wrappedValue.isRollback ? "Roll Back Shaping" : "Change Shaping").font(.title3.bold())
                Text("\(edit.wrappedValue.integration.name) · interface \(edit.wrappedValue.current.interface)").foregroundStyle(.secondary)
                Form {
                    Toggle("Shaping enabled", isOn: edit.enabled)
                    TextField("Download (kbit/s)", text: edit.download)
                    TextField("Upload (kbit/s)", text: edit.upload)
                }
                .disabled(edit.wrappedValue.isRollback)
                GroupBox("Preview") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Now", value: QoSEngine.describe(edit.wrappedValue.current))
                        LabeledContent("After", value: edit.wrappedValue.desired.map(QoSEngine.describe) ?? "Enter whole numbers of kbit/s")
                    }
                    .padding(4)
                }
                Text("The router applies the change with its own 30-second rollback, then it is read back to confirm. Connections may pause briefly. You will be asked to authenticate.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.edit = nil }
                    Button("Apply") { Task { await model.confirmEdit() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(edit.wrappedValue.desired == nil || edit.wrappedValue.desired == edit.wrappedValue.current)
                }
            }
            .padding(20).frame(width: 460)
        }
    }
}

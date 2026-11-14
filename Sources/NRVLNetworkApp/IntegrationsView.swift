import NRVLAdapters
import NRVLCore
import NRVLServices
import Observation
import SwiftUI

@MainActor @Observable
final class IntegrationsModel {
    struct Draft {
        var kind = AdapterKind.snmp
        var name = ""
        var host = ""
        var port = ""
        var username = ""
        var secret = ""

        var integration: Integration {
            Integration(kind: kind, name: name.isEmpty ? host : name, host: host.trimmingCharacters(in: .whitespaces),
                        port: Int(port), username: username.isEmpty ? nil : username)
        }
        var isComplete: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty && !secret.isEmpty }
    }

    private(set) var integrations: [Integration] = []
    private(set) var statuses: [Integration.ID: IntegrationService.Status] = [:]
    private(set) var errorMessage: String?
    private(set) var testMessage: String?
    private(set) var isBusy = false
    var draft = Draft()
    var showAddSheet = false
    var removalTarget: Integration?

    let service: IntegrationService
    private let rescan: () async -> Void

    init(service: IntegrationService, rescan: @escaping () async -> Void) {
        self.service = service
        self.rescan = rescan
    }

    func refresh() async {
        do {
            integrations = try await service.all()
            statuses = await service.status()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testDraft() async {
        isBusy = true
        defer { isBusy = false }
        switch await service.test(draft.integration, secret: draft.secret) {
        case .success(let identity): testMessage = "Connected to \(identity.name) — \(identity.model)"
        case .failure(let error): testMessage = error.localizedDescription
        }
    }

    func addDraft() async {
        await change {
            _ = try await self.service.add(self.draft.integration, secret: self.draft.secret)
            self.draft = Draft()
            self.testMessage = nil
            self.showAddSheet = false
        }
    }

    func remove(_ integration: Integration) async {
        await change { try await self.service.remove(integration) }
    }

    func trust(_ fingerprint: String, _ integration: Integration) async {
        await change { try await self.service.trust(fingerprint: fingerprint, for: integration) }
    }

    /// Runs a change, then polls again so the screen shows the result rather than the intent.
    private func change(_ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await rescan()
        await refresh()
    }
}

struct IntegrationsView: View {
    @Bindable var model: IntegrationsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = model.errorMessage { Banner(symbol: "xmark.octagon", color: .red, text: error) }
                if model.integrations.isEmpty {
                    ContentUnavailableView {
                        Label("No Integrations", systemImage: "cable.connector")
                    } description: {
                        Text("Connect a router, switch or access point you administer. Per-device traffic, VLANs, access control and QoS all come from integrations. New integrations are read-only.")
                    } actions: {
                        Button("Add Integration…") { model.showAddSheet = true }
                    }
                    .padding(.top, 40)
                }
                ForEach(model.integrations) { integration in
                    IntegrationCard(integration: integration, status: model.statuses[integration.id], model: model)
                }
                availability
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Button { model.showAddSheet = true } label: { Label("Add Integration", systemImage: "plus") }
            }
            ToolbarItem {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $model.showAddSheet) { AddIntegrationSheet(model: model) }
        .confirmationDialog("Remove \(model.removalTarget?.name ?? "integration")?",
                            isPresented: Binding(get: { model.removalTarget != nil }, set: { if !$0 { model.removalTarget = nil } })) {
            Button("Remove", role: .destructive) {
                if let target = model.removalTarget { Task { await model.remove(target) } }
            }
        } message: {
            Text("Its saved credential is deleted from the Keychain. Devices stay in the inventory; nothing changes on the device itself.")
        }
        .task {
            while !Task.isCancelled {   // statuses change with every scan
                await model.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var availability: some View {
        Card("Supported Platforms", symbol: "shippingbox") {
            ForEach(AdapterKind.allCases) { kind in
                LabeledContent(kind.title) {
                    AdapterFactory.available.contains(kind) ? Badge(text: "Available", color: .green) : Badge(text: "Not in this build", color: .secondary)
                }
            }
        }
    }
}

private struct IntegrationCard: View {
    let integration: Integration
    let status: IntegrationService.Status?
    let model: IntegrationsModel

    var body: some View {
        Card {
            HStack {
                StatusDot(color: status == nil ? .gray : status!.isConnected ? .green : .red).scaleEffect(1.3)
                VStack(alignment: .leading) {
                    Text(integration.name).font(.headline)
                    Text("\(integration.kind.title) · \(integration.host)\(integration.port.map { ":\($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Badge(text: integration.managementEnabled ? "Management on" : "Read-only", color: integration.managementEnabled ? .orange : .secondary)
                Button("Remove…", role: .destructive) { model.removalTarget = integration }
            }
            if let status {
                if let identity = status.identity {
                    LabeledContent("Device", value: [identity.name, identity.model, identity.firmware].compactMap { $0 }.joined(separator: " · "))
                }
                if let checked = status.checkedAt {
                    LabeledContent("Last checked", value: checked.formatted(date: .omitted, time: .standard))
                }
                if status.isConnected { LabeledContent("Clients reported", value: "\(status.clientCount)") }
                if let error = status.error { failure(error) }
                if !status.capabilities.isEmpty { capabilities(status.capabilities) }
                if !status.devices.isEmpty {
                    LabeledContent("Infrastructure") {
                        Text(status.devices.map { [$0.name, $0.role, $0.model].compactMap { $0 }.joined(separator: " · ") }.joined(separator: "\n"))
                            .multilineTextAlignment(.trailing)
                    }
                }
                if !status.networks.isEmpty {
                    LabeledContent("Networks") {
                        Text(status.networks.map { [$0.name, $0.vlan.map { "VLAN \($0)" }, $0.dhcpRange.map { "DHCP \($0)" }].compactMap { $0 }.joined(separator: " · ") }
                            .joined(separator: "\n")).multilineTextAlignment(.trailing)
                    }
                }
            } else {
                Text("Not checked yet — it is polled with the next scan.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func failure(_ error: AdapterError) -> some View {
        Label(error.localizedDescription, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        switch error {
        case .tlsUntrusted(let fingerprint), .tlsChanged(let fingerprint):
            VStack(alignment: .leading, spacing: 6) {
                Text("Certificate SHA-256 fingerprint presented by \(integration.host):").font(.caption)
                Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                Text("Compare it with the fingerprint shown on the device itself. Approve only if they match — after that, any other certificate is refused.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(integration.pinnedCertificate == nil ? "Trust This Certificate" : "Replace Trusted Certificate") {
                    Task { await model.trust(fingerprint, integration) }
                }
            }
        default:
            EmptyView()
        }
    }

    private func capabilities(_ set: CapabilitySet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Capabilities").font(.caption).foregroundStyle(.secondary)
            ForEach(Feature.allCases) { feature in
                HStack(alignment: .firstTextBaseline) {
                    Text(feature.title).frame(width: 190, alignment: .leading)
                    switch set[feature] {
                    case .supported?: Badge(text: "Supported", color: .green)
                    case .readOnly?: Badge(text: "Read-only", color: .nrvlAccent)
                    case .unsupported(let why)?:
                        Badge(text: "Unsupported", color: .secondary)
                        Text(why).font(.caption).foregroundStyle(.secondary)
                    case nil:
                        Badge(text: "Not reported", color: .secondary)
                    }
                }
            }
        }
    }
}

private struct AddIntegrationSheet: View {
    @Bindable var model: IntegrationsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Integration").font(.title2.bold())
            Form {
                Picker("Platform", selection: $model.draft.kind) {
                    ForEach(AdapterKind.allCases.filter(AdapterFactory.available.contains)) { Text($0.title).tag($0) }
                }
                TextField("Name", text: $model.draft.name, prompt: Text("Optional"))
                TextField("Address", text: $model.draft.host, prompt: Text("192.168.1.1 or router.lan"))
                TextField("Port", text: $model.draft.port, prompt: Text("Default"))
                if model.draft.kind == .unifi {
                    TextField("Site", text: $model.draft.username, prompt: Text("Optional — first site if empty"))
                } else if model.draft.kind != .snmp {
                    TextField("User name", text: $model.draft.username, prompt: Text("root"))
                }
                SecureField(secretLabel, text: $model.draft.secret)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
            if let message = model.testMessage { Text(message).font(.callout) }
            HStack {
                Button("Test Connection") { Task { await model.testDraft() } }.disabled(!model.draft.isComplete || model.isBusy)
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { model.showAddSheet = false }
                Button("Add") { Task { await model.addDraft() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.draft.isComplete || model.isBusy)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var secretLabel: String {
        switch model.draft.kind {
        case .snmp: "Community string"
        case .unifi, .opnsense: "API key"
        default: "Password"
        }
    }

    private var hint: String {
        switch model.draft.kind {
        case .snmp: "SNMP v2c, read-only. The community string is stored in your Keychain. Note that v2c sends it over the network unencrypted, so use a read-only community."
        case .unifi: "Create an API key in the UniFi console under Settings → Control Plane → Integrations. Read-only: the official API offers no blocking or QoS. The key is stored in your Keychain."
        case .openwrt: "Needs the uhttpd-mod-ubus package and HTTPS on the router. The password is stored in your Keychain. The integration starts read-only."
        default: "The secret is stored in your Keychain, never in the app's database. The integration starts read-only."
        }
    }
}

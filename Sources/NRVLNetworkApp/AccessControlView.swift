import NRVLCore
import NRVLServices
import Observation
import SwiftUI

@MainActor @Observable
final class AccessControlModel {
    enum Action: Equatable {
        case block, unblock
        case pause(hours: Int)

        var verb: String {
            switch self {
            case .block: "Block"
            case .unblock: "Unblock"
            case .pause(let hours): "Pause for \(hours) h"
            }
        }
    }

    struct ScheduleDraft {
        var deviceID: Device.ID?
        var group = ""
        var weekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
        var start = Calendar.current.date(from: DateComponents(hour: 22))!
        var end = Calendar.current.date(from: DateComponents(hour: 6))!
    }

    private(set) var availability: [Device.ID: AccessControlEngine.Availability] = [:]
    private(set) var policies: [AccessPolicy] = []
    private(set) var message: (text: String, isError: Bool)?
    private(set) var isWorking = false
    var pending: (device: Device, action: Action)?
    var pendingManagement: Integration?
    var showScheduleSheet = false
    var draft = ScheduleDraft()

    let engine: AccessControlEngine
    let inventory: InventoryModel
    let integrations: IntegrationsModel

    init(engine: AccessControlEngine, inventory: InventoryModel, integrations: IntegrationsModel) {
        self.engine = engine
        self.inventory = inventory
        self.integrations = integrations
    }

    private var gateway: String? { inventory.report?.configuration.gateway }

    /// Devices some router integration reports — the only ones that can possibly be controlled.
    var manageable: [InventoryModel.Row] { inventory.allRows.filter { $0.device.integrationID != nil } }

    func refresh() async {
        await integrations.refresh()
        policies = (try? await engine.allPolicies()) ?? []
        var result: [Device.ID: AccessControlEngine.Availability] = [:]
        for row in manageable { result[row.id] = await engine.availability(for: row.device, gateway: gateway) }
        availability = result
    }

    /// Called after every scan: applies schedules and ended pauses.
    func reconcile() async {
        let outcomes = await engine.reconcile(devices: inventory.devices, gateway: gateway)
        if let failed = outcomes.values.first(where: { $0 != .succeeded }) { report(failed, verb: "A scheduled change") }
    }

    func confirmPending() async {
        guard let (device, action) = pending else { return }
        pending = nil
        guard await Authenticator.confirm("\(action.verb.lowercased()) network access for a device") else {
            message = ("Not authenticated — nothing was changed.", true)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            switch action {
            case .block: _ = try await engine.add(AccessPolicy(kind: .block, target: .device(device.id)))
            case .pause(let hours): _ = try await engine.add(AccessPolicy(kind: .pause, target: .device(device.id), until: Date().addingTimeInterval(Double(hours) * 3_600)))
            case .unblock: try await engine.clearManualBlock(for: device)
            }
        } catch {
            message = ("Could not save the policy: \(error.localizedDescription). Nothing was changed on the router.", true)
            return
        }
        report(await engine.setBlocked(action != .unblock, device: device, gateway: gateway), verb: action.verb)
        await refresh()
    }

    func confirmManagement() async {
        guard let integration = pendingManagement else { return }
        pendingManagement = nil
        let enable = !integration.managementEnabled
        guard await Authenticator.confirm("\(enable ? "allow" : "stop allowing") NRVL Network to change settings on \(integration.name)") else {
            message = ("Not authenticated — nothing was changed.", true)
            return
        }
        do {
            try await integrations.service.setManagement(enable, for: integration)
            message = ("Management \(enable ? "enabled" : "disabled") for \(integration.name).", false)
        } catch {
            message = (error.localizedDescription, true)
        }
        await refresh()
    }

    func addSchedule() async {
        let minutes = { (date: Date) in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        let target: AccessPolicy.Target? = draft.deviceID.map { .device($0) } ?? (draft.group.isEmpty ? nil : .group(draft.group))
        guard let target, !draft.weekdays.isEmpty, minutes(draft.start) != minutes(draft.end) else {
            message = ("Choose a device or group, at least one day, and different start and end times.", true)
            return
        }
        guard await Authenticator.confirm("add an access schedule") else { return }
        do {
            _ = try await engine.add(AccessPolicy(kind: .schedule, target: target, startMinute: minutes(draft.start),
                                                  endMinute: minutes(draft.end), weekdays: draft.weekdays))
            showScheduleSheet = false
            draft = ScheduleDraft()
        } catch {
            message = (error.localizedDescription, true)
        }
        await refresh()
        await reconcile()
    }

    func remove(_ policy: AccessPolicy) async {
        do { try await engine.remove(policy) } catch { message = (error.localizedDescription, true) }
        await refresh()
        await reconcile()
    }

    private func report(_ outcome: ChangeOutcome, verb: String) {
        switch outcome {
        case .succeeded: message = ("\(verb): done and confirmed by the router.", false)
        case .failed(let reason): message = ("\(verb) failed: \(reason)", true)
        case .unverified(let reason): message = ("\(verb) could not be confirmed: \(reason)", true)
        }
    }

    func describe(_ policy: AccessPolicy) -> String {
        let target: String = switch policy.target {
        case .device(let id): inventory.allRows.first { $0.id == id }?.name ?? "Device #\(id)"
        case .group(let name): "Group \"\(name)\" (trusted devices excepted)"
        }
        let clock = { (minute: Int) in String(format: "%02d:%02d", minute / 60, minute % 60) }
        let when: String = switch policy.kind {
        case .block: "blocked until removed"
        case .pause: "paused until \(policy.until?.formatted(date: .abbreviated, time: .shortened) ?? "?")"
        case .schedule:
            "blocked \(clock(policy.startMinute ?? 0))–\(clock(policy.endMinute ?? 0)) on " +
                policy.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " ")
        }
        return "\(target): \(when)"
    }
}

struct AccessControlView: View {
    @Bindable var model: AccessControlModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = model.message {
                    Banner(symbol: message.isError ? "exclamationmark.triangle" : "checkmark.circle", color: message.isError ? .red : .green, text: message.text)
                }
                integrationsCard
                devicesCard
                policiesCard
                Card("Quarantine", symbol: "shield.lefthalf.filled", badge: Badge(text: "Unavailable", color: .secondary)) {
                    Text("Quarantine moves a device to an isolated VLAN. None of the supported integrations offers a documented way to do that yet, so it is not available. Use Block instead.")
                        .foregroundStyle(.secondary)
                }
                Text("Devices are blocked only by asking your router through its own interface. NRVL Network never disconnects devices by deauthentication, ARP spoofing or any other attack technique. Every attempt, including refused and failed ones, is written to the audit log.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .task { await model.refresh() }
        .sheet(isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } })) { confirmation }
        .sheet(isPresented: Binding(get: { model.pendingManagement != nil }, set: { if !$0 { model.pendingManagement = nil } })) { managementConfirmation }
        .sheet(isPresented: $model.showScheduleSheet) { scheduleSheet }
    }

    private var integrationsCard: some View {
        Card("Integrations", symbol: "cable.connector") {
            if model.integrations.integrations.isEmpty {
                Text("No integration is configured. Access control needs a router integration that supports it — add one under Integrations.").foregroundStyle(.secondary)
            }
            ForEach(model.integrations.integrations) { integration in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(integration.name)
                        switch model.integrations.statuses[integration.id]?.capabilities[.accessControl] {
                        case .supported?: Text("Can block and unblock devices").font(.caption).foregroundStyle(.secondary)
                        case .unsupported(let why)?: Text(why).font(.caption).foregroundStyle(.secondary)
                        default: Text("Capability not known yet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Badge(text: integration.managementEnabled ? "Management on" : "Read-only", color: integration.managementEnabled ? .orange : .secondary)
                    Button(integration.managementEnabled ? "Make Read-only…" : "Enable Management…") { model.pendingManagement = integration }
                }
            }
        }
    }

    private var devicesCard: some View {
        Card("Devices", symbol: "lock.shield") {
            let rows = model.manageable
            if rows.isEmpty {
                Text("No device is reported by a router integration yet, so none can be controlled.").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text([row.ipv4, row.mac].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if case .unavailable(let why)? = model.availability[row.id] { Text(why).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    switch row.device.isBlocked {
                    case true?: Badge(text: "Blocked", color: .red)
                    case false?: Badge(text: "Allowed", color: .green)
                    case nil: Badge(text: "State unknown", color: .secondary)
                    }
                    if case .available? = model.availability[row.id] {
                        if row.device.isBlocked == true {
                            Button("Unblock…") { model.pending = (row.device, .unblock) }
                        } else {
                            Menu("Block…") {
                                Button("Block until I unblock it") { model.pending = (row.device, .block) }
                                Button("Pause for 1 hour") { model.pending = (row.device, .pause(hours: 1)) }
                                Button("Pause for 8 hours") { model.pending = (row.device, .pause(hours: 8)) }
                            }
                            .fixedSize()
                        }
                    }
                }
                .disabled(model.isWorking)
            }
            let others = model.inventory.devices.count - rows.count
            if others > 0 {
                Text("\(others) other devices are known only from this Mac's own discovery. A Mac cannot block another device, so they are not listed.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var policiesCard: some View {
        Card("Policies and Schedules", symbol: "calendar.badge.clock") {
            if model.policies.isEmpty { Text("No policies.").foregroundStyle(.secondary) }
            ForEach(model.policies) { policy in
                HStack {
                    Text(model.describe(policy))
                    Spacer()
                    if policy.isActive(at: Date()) { Badge(text: "Active now", color: .orange) }
                    Button("Remove") { Task { await model.remove(policy) } }
                }
            }
            Button("Add Schedule…") { model.showScheduleSheet = true }
            Text("Schedules are applied when the app scans (about once a minute) and only while it is running. To allowlist a device, mark it Trusted in Devices: group schedules skip trusted devices.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var confirmation: some View {
        if let (device, action) = model.pending {
            let name = device.customName ?? device.hostname ?? device.mac.description
            VStack(alignment: .leading, spacing: 12) {
                Text("\(action.verb): \(name)").font(.title3.bold())
                LabeledContent("Device", value: "\(device.mac)  \(device.ipv4 ?? "")")
                if case .available(let integration)? = model.availability[device.id] {
                    LabeledContent("Changed on", value: "\(integration.name) (\(integration.kind.title))")
                }
                Text(action == .unblock
                     ? "The router will be asked to allow this device again. If a schedule applies right now, it will be blocked again at the next scan."
                     : "The router will be asked to stop this device reaching the internet. The device stays connected to the local network. You can undo this with Unblock.")
                Text("After the change the router is read back to confirm it. You will be asked to authenticate.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.pending = nil }
                    Button(action.verb) { Task { await model.confirmPending() } }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 460)
        }
    }

    @ViewBuilder
    private var managementConfirmation: some View {
        if let integration = model.pendingManagement {
            VStack(alignment: .leading, spacing: 12) {
                Text(integration.managementEnabled ? "Make \(integration.name) read-only?" : "Enable management for \(integration.name)?").font(.title3.bold())
                Text(integration.managementEnabled
                     ? "NRVL Network will stop making changes on this device. Existing blocks stay as they are on the router; schedules for its devices stop being applied."
                     : "NRVL Network will be allowed to change settings on this device when you ask it to, or when a schedule you created says so. Each change is confirmed, verified and logged.")
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.pendingManagement = nil }
                    Button(integration.managementEnabled ? "Make Read-only" : "Enable") { Task { await model.confirmManagement() } }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 460)
        }
    }

    private var scheduleSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Access Schedule").font(.title3.bold())
            Form {
                Picker("Device", selection: $model.draft.deviceID) {
                    Text("None — use a group").tag(Device.ID?.none)
                    ForEach(model.manageable) { Text($0.name).tag(Device.ID?.some($0.id)) }
                }
                if model.draft.deviceID == nil {
                    Picker("Group", selection: $model.draft.group) {
                        Text("Choose…").tag("")
                        ForEach(Array(Set(model.inventory.devices.compactMap(\.group))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                DatePicker("Block from", selection: $model.draft.start, displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: $model.draft.end, displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                            get: { model.draft.weekdays.contains(day) },
                            set: { if $0 { model.draft.weekdays.insert(day) } else { model.draft.weekdays.remove(day) } }))
                            .toggleStyle(.button)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                    }
                }
            }
            Text("If the end time is earlier than the start time, the block runs overnight into the next morning.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.showScheduleSheet = false }
                Button("Add") { Task { await model.addSchedule() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 480)
    }
}

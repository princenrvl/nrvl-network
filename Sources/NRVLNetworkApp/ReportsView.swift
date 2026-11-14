import AppKit
import NRVLCore
import NRVLPersistence
import NRVLServices
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class ReportsModel {
    enum Period: String, CaseIterable, Identifiable {
        case today = "Today", yesterday = "Yesterday", week = "Last 7 Days", month = "Last 30 Days"
        var id: Self { self }

        func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
            let midnight = calendar.startOfDay(for: now)
            switch self {
            case .today: return DateInterval(start: midnight, end: now)
            case .yesterday: return DateInterval(start: calendar.date(byAdding: .day, value: -1, to: midnight)!, end: midnight)
            case .week: return DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
            case .month: return DateInterval(start: now.addingTimeInterval(-30 * 86_400), end: now)
            }
        }
    }

    enum Dataset: String, CaseIterable, Identifiable {
        case devices = "Device Inventory", events = "Connection History", alerts = "Alerts", audit = "Audit Log", usage = "Per-device Usage"
        var id: Self { self }
    }

    var period = Period.today { didSet { Task { await reload() } } }
    private(set) var report: NetworkReport?
    private(set) var audit: [AuditEntry] = []
    private(set) var brokenAuditEntry: Int64?
    private(set) var backups: [BackupService.Backup] = []
    private(set) var message: (text: String, isError: Bool)?

    private let database: AppDatabase
    private let integrations: IntegrationsModel
    private let backupService: BackupService

    init(database: AppDatabase, integrations: IntegrationsModel) {
        self.database = database
        self.integrations = integrations
        let directory = (try? AppDatabase.defaultURL().deletingLastPathComponent().appendingPathComponent("Configuration Backups")) ?? FileManager.default.temporaryDirectory
        backupService = BackupService(directory: directory, audit: database.audit)
    }

    var integrationList: [Integration] { integrations.integrations }

    func reload() async {
        await integrations.refresh()
        report = try? await ReportBuilder.build(period: period.interval(), database: database)
        audit = (try? await database.audit.entries(limit: 200)) ?? []
        brokenAuditEntry = try? await database.audit.firstBrokenEntryID()
        backups = backupService.all()
    }

    // MARK: Export

    private func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    func csv(_ dataset: Dataset) async throws -> String {
        let interval = period.interval()
        let devices = try await database.devices.all()
        func name(_ device: Device) -> String { device.customName ?? device.hostname ?? "" }
        switch dataset {
        case .devices:
            return CSV.encode(header: ["Name", "MAC", "IPv4", "IPv6", "Hostname", "Model", "Connection", "SSID", "Attached to", "VLAN", "Trusted", "Group", "Tags", "First seen", "Last seen"],
                              rows: devices.map { [name($0), $0.mac.description, $0.ipv4 ?? "", $0.ipv6.joined(separator: " "), $0.hostname ?? "", $0.model ?? "",
                                                   $0.connection?.rawValue ?? "", $0.ssid ?? "", $0.uplink ?? "", $0.vlan.map(String.init) ?? "",
                                                   $0.isTrusted ? "yes" : "no", $0.group ?? "", $0.tags.joined(separator: " "), stamp($0.firstSeen), stamp($0.lastSeen)] })
        case .events:
            let names = Dictionary(devices.map { ($0.id, ($0.mac.description, name($0))) }, uniquingKeysWith: { first, _ in first })
            let events = try await database.devices.events(after: interval.start).filter { $0.event.date < interval.end }
            return CSV.encode(header: ["Time", "Event", "MAC", "Name"],
                              rows: events.map { [stamp($0.event.date), $0.event.kind.rawValue, names[$0.device]?.0 ?? "", names[$0.device]?.1 ?? ""] })
        case .alerts:
            let alerts = try await database.alerts.all(since: interval.start, limit: 10_000).filter { $0.date < interval.end }
            return CSV.encode(header: ["Time", "Kind", "Subject", "Detail", "Acknowledged"],
                              rows: alerts.map { [stamp($0.date), $0.kind.title, $0.subject, $0.detail, $0.acknowledged ? "yes" : "no"] })
        case .audit:
            let entries = try await database.audit.entries(limit: 100_000).filter { interval.contains($0.timestamp) }
            return CSV.encode(header: ["Entry", "Time", "User", "Action", "Target", "Detail", "Outcome"],
                              rows: entries.map { [String($0.id), stamp($0.timestamp), $0.actor, $0.action, $0.target, $0.detail, $0.outcome.rawValue] })
        case .usage:
            return CSV.encode(header: ["Device", "Received bytes", "Sent bytes"],
                              rows: (report?.usage ?? []).map { [$0.name, String($0.received), String($0.sent)] })
        }
    }

    func export(_ dataset: Dataset) async {
        do {
            let text = try await csv(dataset)
            save(Data(text.utf8), name: "NRVL \(dataset.rawValue) \(period.rawValue).csv", type: .commaSeparatedText)
        } catch {
            message = (error.localizedDescription, true)
        }
    }

    func exportPDF() {
        guard let report else { return }
        let renderer = ImageRenderer(content: ReportContent(report: report, title: period.rawValue).frame(width: 700).padding(30).environment(\.colorScheme, .light))
        let data = NSMutableData()
        // shortcut: one continuous page sized to the content; paginate to A4/Letter if reports need printing.
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        guard data.length > 0 else { return message = ("The PDF could not be created.", true) }
        save(data as Data, name: "NRVL Network Report \(period.rawValue).pdf", type: .pdf)
    }

    private func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            message = ("Saved \(url.lastPathComponent).", false)
        } catch {
            message = (error.localizedDescription, true)
        }
    }

    // MARK: Backups

    func backUp(_ integration: Integration) async {
        do {
            let adapter = try await integrations.service.adapter(for: integration)
            let backup = try await backupService.create(for: integration, adapter: adapter)
            message = ("Encrypted configuration snapshot of \(integration.name) saved (\(backup.size) bytes).", false)
        } catch {
            message = ("Backup of \(integration.name) failed: \(error.localizedDescription)", true)
        }
        backups = backupService.all()
    }

    func exportDecrypted(_ backup: BackupService.Backup) async {
        guard await Authenticator.confirm("export a decrypted router configuration, which contains passwords") else {
            return message = ("Not authenticated — nothing was exported.", true)
        }
        do {
            save(try await backupService.decrypt(backup), name: "\(backup.integrationName) configuration.json", type: .json)
        } catch {
            message = ("This backup cannot be opened: it was altered, or its key is no longer in the Keychain.", true)
        }
    }
}

/// The report body. Used on screen and rendered as-is into the PDF.
struct ReportContent: View {
    let report: NetworkReport
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NRVL Network Report — \(title)").font(.title2.bold())
            Text("\(report.period.start.formatted(date: .abbreviated, time: .shortened)) – \(report.period.end.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)

            section("Coverage") {
                row("Period observed by the app", report.observedFraction.formatted(.percent.precision(.fractionLength(0))))
                Text("Figures below describe only the observed part. The app records while it is running.").font(.caption).foregroundStyle(.secondary)
            }
            section("Internet") {
                row("Checks answered (uptime while observed)", report.internetAvailability.map { $0.formatted(.percent.precision(.fractionLength(2))) } ?? "No data")
                row("Average latency", report.averageLatency.map { String(format: "%.1f ms", $0 * 1000) } ?? "No data")
                row("Worst one-minute average", report.worstMinuteLatency.map { String(format: "%.1f ms", $0 * 1000) } ?? "No data")
            }
            section("This Mac's Traffic") {
                row("Average download", report.averageDownload.map { Int64($0).formatted(.byteCount(style: .binary)) + "/s" } ?? "No data")
                row("Average upload", report.averageUpload.map { Int64($0).formatted(.byteCount(style: .binary)) + "/s" } ?? "No data")
            }
            section("Devices") {
                row("Known devices", "\(report.devicesKnown)")
                row("First seen in this period", report.devicesDiscovered.isEmpty ? "None" : report.devicesDiscovered.joined(separator: ", "))
                ForEach(report.connectionEvents) { row("\($0.label) events", "\($0.count)") }
            }
            section("Per-device Consumption") {
                if report.usage.isEmpty { Text("No integration reports per-device traffic.").foregroundStyle(.secondary) }
                ForEach(report.usage.prefix(20)) { row($0.name, "↓ \($0.received.formatted(.byteCount(style: .binary)))  ↑ \($0.sent.formatted(.byteCount(style: .binary)))") }
            }
            section("Alerts and Security Events") {
                if report.alerts.isEmpty { Text("None.").foregroundStyle(.secondary) }
                ForEach(report.alerts) { row($0.label, "\($0.count)") }
                ForEach(report.securityEvents.prefix(20)) { event in
                    Text("• \(event.date.formatted(date: .abbreviated, time: .shortened)) — \(event.detail)").font(.caption)
                }
            }
            section("QoS and Configuration Changes") {
                if report.changes.isEmpty { Text("None.").foregroundStyle(.secondary) }
                ForEach(report.changes) { row($0.date.formatted(date: .abbreviated, time: .shortened), $0.summary) }
            }
            section("Administrative Actions (Audit Log)") {
                if report.auditActions.isEmpty { Text("None.").foregroundStyle(.secondary) }
                ForEach(report.auditActions) { row($0.label, "\($0.count)") }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
            Divider()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 16)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

struct ReportsView: View {
    @Bindable var model: ReportsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = model.message {
                    Banner(symbol: message.isError ? "exclamationmark.triangle" : "checkmark.circle", color: message.isError ? .red : .green, text: message.text)
                }
                HStack {
                    Picker("Period", selection: $model.period) { ForEach(ReportsModel.Period.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 460)
                    Spacer()
                    Button("Export PDF…") { model.exportPDF() }.disabled(model.report == nil)
                    Menu("Export CSV") {
                        ForEach(ReportsModel.Dataset.allCases) { dataset in Button(dataset.rawValue + "…") { Task { await model.export(dataset) } } }
                    }
                    .fixedSize()
                }
                if let report = model.report {
                    Card { ReportContent(report: report, title: model.period.rawValue) }
                } else {
                    ProgressView()
                }
                auditCard
                backupsCard
            }
            .padding(20)
        }
        .task { await model.reload() }
    }

    private var auditCard: some View {
        Card("Audit Log", symbol: "list.bullet.rectangle",
             badge: model.brokenAuditEntry == nil ? Badge(text: "Chain intact", color: .green) : Badge(text: "Altered at entry \(model.brokenAuditEntry!)", color: .red)) {
            Text("Every administrative action, including refused and failed ones. Entries cannot be edited or deleted through the app, and each one is chained to the one before so changes made outside the app are detected.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(model.audit.prefix(60)) { entry in
                    GridRow {
                        Text(entry.timestamp.formatted(date: .numeric, time: .standard)).font(.caption.monospacedDigit())
                        Text(entry.actor).font(.caption)
                        Text(entry.action).font(.caption.monospaced())
                        Text(entry.target).font(.caption).lineLimit(1)
                        Badge(text: entry.outcome.rawValue, color: entry.outcome == .succeeded ? .green : entry.outcome == .failed ? .red : .orange)
                    }
                    .help(entry.detail)
                }
            }
            if model.audit.count > 60 { Text("Showing the latest 60. Export the Audit Log CSV for the full period.").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private var backupsCard: some View {
        Card("Configuration Backups", symbol: "externaldrive.badge.timemachine") {
            if model.integrationList.isEmpty { Text("No integrations configured.").foregroundStyle(.secondary) }
            ForEach(model.integrationList) { integration in
                HStack {
                    Text(integration.name)
                    Spacer()
                    Button("Back Up Now") { Task { await model.backUp(integration) } }
                }
            }
            ForEach(model.backups) { backup in
                HStack {
                    Text("\(backup.integrationName) — \(backup.date.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    Text(Int64(backup.size).formatted(.byteCount(style: .file))).foregroundStyle(.secondary)
                    Button("Export Decrypted…") { Task { await model.exportDecrypted(backup) } }
                }
            }
            Text("A backup is a snapshot of the router's settings as it reports them, encrypted on this Mac with a key kept in your Keychain. It is a record for comparison and manual restore — NRVL Network does not write a whole configuration back to a router. Only integrations that can export their configuration (currently OpenWrt) can be backed up.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

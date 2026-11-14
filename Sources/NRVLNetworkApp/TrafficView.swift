import Charts
import NRVLCore
import NRVLPersistence
import NRVLTelemetry
import Observation
import SwiftUI

@MainActor @Observable
final class TrafficModel {
    enum Range: String, CaseIterable, Identifiable {
        case hour = "1 Hour", day = "24 Hours", week = "7 Days", month = "30 Days"
        var id: Self { self }
        var seconds: TimeInterval { [.hour: 3_600, .day: 86_400, .week: 604_800, .month: 2_592_000][self]! }
        /// About 120 points per chart.
        var bucket: TimeInterval { max(60, seconds / 120) }
    }

    /// A pair of stored series drawn together: download/upload or receive/transmit.
    struct Source: Hashable, Identifiable {
        var id: String { down }
        let title: String
        let down: String
        let up: String
    }

    static let thisMac = Source(title: "This Mac", down: "mac.down", up: "mac.up")

    var range = Range.day { didSet { Task { await reload() } } }
    var source = TrafficModel.thisMac { didSet { Task { await reload() } } }
    private(set) var sources = [TrafficModel.thisMac]
    private(set) var down: [MetricStore.Point] = []
    private(set) var up: [MetricStore.Point] = []
    private(set) var latency: [MetricStore.Point] = []
    private(set) var loss: [MetricStore.Point] = []
    private(set) var usage: [MetricStore.DeviceUsage] = []

    let collector = FlowCollector()
    private(set) var flows: FlowSummary?
    private(set) var collectorError: String?

    private let metrics: MetricStore

    init(metrics: MetricStore) {
        self.metrics = metrics
    }

    func reload(integrationNames: [Int64: String] = [:]) async {
        let since = Date().addingTimeInterval(-range.seconds)
        down = (try? await metrics.history(source.down, since: since, bucket: range.bucket)) ?? []
        up = (try? await metrics.history(source.up, since: since, bucket: range.bucket)) ?? []
        latency = (try? await metrics.history("internet.latency", since: since, bucket: range.bucket)) ?? []
        loss = (try? await metrics.history("internet.loss", since: since, bucket: range.bucket)) ?? []
        usage = (try? await metrics.usageByDevice(since: since)) ?? []
        if collector.isRunning { flows = collector.snapshot() }

        // Interfaces of SNMP devices: series "if.<integration id>.<interface>.rx" and ".tx".
        let names = (try? await metrics.seriesNames(prefix: "if.")) ?? []
        let interfaces = Set(names.compactMap { $0.hasSuffix(".rx") ? String($0.dropLast(3)) : nil }).sorted()
        sources = [Self.thisMac] + interfaces.map { key in
            let parts = key.split(separator: ".", maxSplits: 2).map(String.init)
            let device = parts.count == 3 ? (Int64(parts[1]).flatMap { integrationNames[$0] } ?? "Integration \(parts[1])") : key
            return Source(title: "\(device) — \(parts.last ?? key)", down: key + ".rx", up: key + ".tx")
        }
    }

    func toggleCollector() {
        if collector.isRunning {
            collector.stop()
        } else {
            do {
                try collector.start()
                collectorError = nil
                flows = collector.snapshot()
            } catch {
                collectorError = "Could not listen on UDP port \(FlowCollector.defaultPort): \(error.localizedDescription)"
            }
        }
    }
}

struct TrafficView: View {
    @Bindable var model: TrafficModel
    let inventory: InventoryModel
    let integrations: IntegrationsModel?
    let telemetry: TelemetryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("Range", selection: $model.range) { ForEach(TrafficModel.Range.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 380)
                    Spacer()
                    Picker("Source", selection: $model.source) { ForEach(model.sources) { Text($0.title).tag($0) } }.frame(maxWidth: 320)
                }
                throughputCard
                qualityCard
                devicesCard
                flowsCard
            }
            .padding(20)
        }
        .task {
            while !Task.isCancelled {
                await model.reload(integrationNames: Dictionary((integrations?.integrations ?? []).map { ($0.id, $0.name) },
                                                                uniquingKeysWith: { first, _ in first }))
                try? await Task.sleep(for: .seconds(collectorIsRunning ? 5 : 60))
            }
        }
    }

    private var collectorIsRunning: Bool { model.collector.isRunning }

    private var throughputCard: some View {
        Card("Throughput — \(model.source.title)", symbol: "chart.xyaxis.line", badge: Freshness.historical.badge) {
            if model.down.isEmpty && model.up.isEmpty {
                Text("No stored samples in this range yet. One sample is stored per minute while the app is running.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.down) { LineMark(x: .value("Time", $0.date), y: .value("Bytes/s", $0.value), series: .value("Direction", "In")).foregroundStyle(by: .value("Direction", inLabel)) }
                    ForEach(model.up) { LineMark(x: .value("Time", $0.date), y: .value("Bytes/s", $0.value), series: .value("Direction", "Out")).foregroundStyle(by: .value("Direction", outLabel)) }
                }
                .chartForegroundStyleScale([inLabel: Color.nrvlAccent, outLabel: Color.orange])
                .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let bytes = value.as(Double.self) { Text(rate(bytes)) } } } }
                .frame(height: 200)
            }
            Text(model.source == TrafficModel.thisMac
                 ? "This Mac's own traffic only — not the network's. Gaps mean the app was not running."
                 : "Total traffic through this interface of the device, read over SNMP. Gaps mean the app was not running or the device did not answer.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var inLabel: String { model.source == TrafficModel.thisMac ? "Download" : "Received" }
    private var outLabel: String { model.source == TrafficModel.thisMac ? "Upload" : "Sent" }

    private var qualityCard: some View {
        Card("Internet Latency and Loss", symbol: "waveform.path.ecg", badge: Freshness.historical.badge) {
            if model.latency.isEmpty && model.loss.isEmpty {
                Text("No stored samples in this range yet.").foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(model.latency) { LineMark(x: .value("Time", $0.date), y: .value("Latency (ms)", $0.value * 1000)).foregroundStyle(Color.nrvlAccent) }
                    ForEach(model.loss.filter { $0.value > 0 }) { BarMark(x: .value("Time", $0.date), y: .value("Loss (%)", $0.value * 100)).foregroundStyle(Color.red.opacity(0.6)) }
                }
                .frame(height: 140)
                Text("Line: average ping time to \(TelemetryModel.internetTarget) in ms. Red bars: percentage of pings lost in that period.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var devicesCard: some View {
        Card("Traffic per Device", symbol: "list.number") {
            if model.usage.isEmpty {
                Text("No per-device traffic recorded. A Mac cannot see other devices' traffic; this needs a router integration that reports byte counts per client. None of the connected integrations does: the official UniFi API and stock OpenWrt do not expose them, and SNMP counts per interface, not per client.")
                    .foregroundStyle(.secondary)
            } else {
                let names = Dictionary(inventory.allRows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                ForEach(model.usage.prefix(15)) { usage in
                    LabeledContent(names[usage.id] ?? "Device \(usage.id)") {
                        Text("↓ \(usage.received.formatted(.byteCount(style: .binary)))   ↑ \(usage.sent.formatted(.byteCount(style: .binary)))").monospacedDigit()
                    }
                }
                Text("Top devices by bytes counted by the router in this range.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var flowsCard: some View {
        Card("Flow Records (NetFlow v5)", symbol: "arrow.left.arrow.right.square", badge: collectorIsRunning ? Freshness.live.badge : nil) {
            HStack {
                Button(collectorIsRunning ? "Stop Listening" : "Start Listening") { model.toggleCollector() }
                Text("UDP port \(FlowCollector.defaultPort)").foregroundStyle(.secondary)
            }
            if let error = model.collectorError { Text(error).foregroundStyle(.red) }
            if let flows = model.flows, flows.flows > 0 {
                let names = Dictionary(inventory.allRows.filter { !$0.ipv4.isEmpty }.map { ($0.ipv4, $0.name) }, uniquingKeysWith: { first, _ in first })
                LabeledContent("Since", value: flows.since.formatted(date: .omitted, time: .standard))
                LabeledContent("Exporters", value: flows.exporters.sorted().joined(separator: ", "))
                LabeledContent("Flows / bytes", value: "\(flows.flows) / \(Int64(clamping: flows.totalBytes).formatted(.byteCount(style: .binary)))")
                top("Protocols", flows.byProtocol.map { ($0.key, $0.value) })
                top("Destination ports", flows.byDestinationPort.map { (String($0.key), $0.value) })
                top("Destinations", flows.byDestination.map { (names[$0.key] ?? $0.key, $0.value) })
                top("Sources", flows.bySource.map { entry in (names[entry.key].map { "\($0) — \(entry.key)" } ?? entry.key, entry.value) })
            } else {
                Text(collectorIsRunning
                     ? "Listening. Nothing received yet — configure your router to export NetFlow version 5 to \(telemetry.primaryInterface?.ipv4 ?? "this Mac's address"), UDP port \(FlowCollector.defaultPort)."
                     : "Protocol, port and destination breakdowns need flow records from your router. Start listening, then configure the router to export NetFlow version 5 to this Mac. Totals are kept for the current session only.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func top(_ title: String, _ items: [(String, UInt64)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(Array(items.sorted { $0.1 > $1.1 }.prefix(8).enumerated()), id: \.offset) { _, item in
                LabeledContent(item.0) { Text(Int64(clamping: item.1).formatted(.byteCount(style: .binary))).monospacedDigit() }
            }
        }
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        Int64(bytesPerSecond).formatted(.byteCount(style: .binary)) + "/s"
    }
}

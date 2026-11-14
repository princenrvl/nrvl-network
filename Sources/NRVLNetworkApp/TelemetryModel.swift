import Foundation
import NRVLCore
import NRVLDiscovery
import NRVLPersistence
import NRVLTelemetry
import Observation

/// Live measurements taken from this Mac. Everything here is in memory for the current app run;
/// stored history arrives with Phase 7.
@MainActor @Observable
final class TelemetryModel {
    struct ThroughputPoint: Identifiable {
        let id: Date
        let down: Double   // bytes per second
        let up: Double
    }

    enum Health: Equatable {
        case measuring
        case healthy
        case degraded(String)
        case offline(String)
    }

    // shortcut: fixed public target for the internet check; make it a setting when Settings gains preferences.
    static let internetTarget = "1.1.1.1"
    static let interval: Duration = .seconds(2)
    private static let historyLimit = 150   // 5 minutes at one sample per 2 s

    private(set) var configuration = NetworkConfiguration()
    private(set) var interfaces: [NetworkInterface] = []
    private(set) var throughput: [ThroughputPoint] = []
    private(set) var gateway = PingWindow()
    private(set) var internet = PingWindow()
    private(set) var internetChecks = 0
    private(set) var internetReplies = 0
    let startedAt = Date()

    /// Set once the database is open; from then on one averaged row per series is stored every minute.
    var metrics: MetricStore?
    private var minute: [String: [Double]] = [:]
    private var minuteStart = Date()

    private func accumulate(_ series: String, _ value: Double?) {
        if let value { minute[series, default: []].append(value) }
    }

    private func flushIfMinuteEnded() async {
        guard Date().timeIntervalSince(minuteStart) >= 60 else { return }
        let averages = minute.mapValues { $0.reduce(0, +) / Double($0.count) }
        minute = [:]
        let stamp = minuteStart
        minuteStart = Date()
        try? await metrics?.add(averages, at: stamp)
    }

    enum PublicIP: Equatable { case notRequested, loading, known(String), failed(String) }
    private(set) var publicIP = PublicIP.notRequested

    /// Asks an outside service which address this network appears as. Only runs when the user clicks.
    func lookUpPublicIP() async {
        publicIP = .loading
        do {
            var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
            request.timeoutInterval = 8
            let (data, _) = try await URLSession.shared.data(for: request)
            let text = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // Trust nothing from the network: accept only something shaped like an IP address.
            let looksLikeAddress = !text.isEmpty && text.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
            publicIP = looksLikeAddress ? .known(text) : .failed("Unexpected answer from the lookup service.")
        } catch {
            publicIP = .failed(error.localizedDescription)
        }
    }

    var primaryInterface: NetworkInterface? {
        interfaces.first { $0.name == configuration.primaryInterface }
    }

    var health: Health {
        guard internet.samples.count >= 3 else { return .measuring }
        if configuration.gateway == nil { return .offline("This Mac has no default gateway.") }
        if gateway.lossFraction == 1 { return .offline("The gateway is not answering.") }
        if internet.lossFraction == 1 { return .offline("The gateway answers but the internet check does not.") }
        if let loss = internet.lossFraction, loss > 0.05 {
            return .degraded("Internet packet loss is \(Int((loss * 100).rounded()))% over the last minute.")
        }
        if let latency = internet.averageLatency, latency > 0.15 {
            return .degraded("Internet latency averages \(Int(latency * 1000)) ms.")
        }
        return .healthy
    }

    /// Samples every two seconds for the life of the app.
    func run() async {
        let clock = ContinuousClock()
        var previous: (interface: String, counters: InterfaceCounters, at: ContinuousClock.Instant)?

        while !Task.isCancelled {
            configuration = InterfaceReader.configuration()
            interfaces = InterfaceReader.interfaces()

            if let name = configuration.primaryInterface, let counters = InterfaceStatistics.read()[name] {
                let now = clock.now
                if let previous, previous.interface == name,
                   let rate = counters.rate(since: previous.counters, seconds: (now - previous.at) / .seconds(1)) {
                    throughput.append(ThroughputPoint(id: Date(), down: rate.down, up: rate.up))
                    accumulate("mac.down", rate.down)
                    accumulate("mac.up", rate.up)
                    if throughput.count > Self.historyLimit { throughput.removeFirst(throughput.count - Self.historyLimit) }
                }
                previous = (name, counters, now)
            } else {
                previous = nil
            }

            async let internetReply = Pinger.ping(Self.internetTarget)
            if let address = configuration.gateway {
                let reply = await Pinger.ping(address)
                gateway.add(reply)
                accumulate("gateway.latency", reply)
                accumulate("gateway.loss", reply == nil ? 1 : 0)
            } else {
                gateway = PingWindow()
            }
            let reply = await internetReply
            internet.add(reply)
            internetChecks += 1
            if reply != nil { internetReplies += 1 }
            accumulate("internet.latency", reply)
            accumulate("internet.loss", reply == nil ? 1 : 0)
            await flushIfMinuteEnded()

            try? await Task.sleep(for: Self.interval)
        }
    }
}

import Testing
@testable import NRVLTelemetry

@Test func checksumMatchesRFC1071Example() {
    // RFC 1071 §3 example words 0001 f203 f4f5 f6f7 sum to ddf2; the checksum is its complement.
    #expect(Pinger.checksum([0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]) == 0x220D)
    #expect(Pinger.checksum([0xFF]) == 0x00FF)   // odd length pads with zero
}

@Test func echoRequestIsWellFormed() {
    let packet = Pinger.echoRequest(identifier: 0x1234, sequence: 0xABCD)
    #expect(packet[0] == 8 && packet[1] == 0)
    #expect(Array(packet[4..<8]) == [0x12, 0x34, 0xAB, 0xCD])
    #expect(Pinger.checksum(packet) == 0)   // a packet carrying its own checksum sums to zero
}

@Test func pingWindowStatistics() {
    var window = PingWindow(capacity: 4)
    #expect(window.lossFraction == nil && window.averageLatency == nil && window.jitter == nil)

    for sample in [0.010, nil, 0.020, 0.014] as [Double?] { window.add(sample) }
    #expect(window.lossFraction == 0.25)
    #expect(abs(window.averageLatency! - 0.0146667) < 1e-6)
    #expect(abs(window.jitter! - 0.008) < 1e-9)   // |20−10| and |14−20| → mean 8 ms

    window.add(nil)   // pushes the first sample out
    #expect(window.samples.count == 4)
    #expect(window.lossFraction == 0.5)
}

@Test func throughputRate() {
    let earlier = InterfaceCounters(received: 1_000, sent: 500)
    let rate = InterfaceCounters(received: 5_000, sent: 1_500).rate(since: earlier, seconds: 2)
    #expect(rate?.down == 2_000 && rate?.up == 500)
    #expect(InterfaceCounters(received: 10, sent: 10).rate(since: earlier, seconds: 2) == nil)   // counters reset
    #expect(earlier.rate(since: earlier, seconds: 0) == nil)
}

@Test func liveCountersIncludeLoopback() {
    #expect(InterfaceStatistics.read()["lo0"] != nil)
}

@Test func liveLoopbackPingReplies() async {
    let time = await Pinger.ping("127.0.0.1", timeout: 1)
    #expect(time != nil && time! < 0.5)
    #expect(await Pinger.ping("not-an-address") == nil)
}

// MARK: NetFlow

import Darwin
import Foundation

private func netflowPacket(_ flows: [(src: [UInt8], dst: [UInt8], dport: UInt16, proto: UInt8, bytes: UInt32)]) -> [UInt8] {
    var packet: [UInt8] = [0, 5, UInt8(flows.count >> 8), UInt8(flows.count & 0xFF)] + [UInt8](repeating: 0, count: 20)
    for flow in flows {
        var record = [UInt8](repeating: 0, count: 48)
        record.replaceSubrange(0..<4, with: flow.src)
        record.replaceSubrange(4..<8, with: flow.dst)
        record[19] = 3                                                           // packets
        record.replaceSubrange(20..<24, with: withUnsafeBytes(of: flow.bytes.bigEndian) { Array($0) })
        record[32] = 0xC0; record[33] = 0x01                                     // source port 49153
        record[34] = UInt8(flow.dport >> 8); record[35] = UInt8(flow.dport & 0xFF)
        record[38] = flow.proto
        packet += record
    }
    return packet
}

@Test func netflowV5Parsing() {
    let packet = netflowPacket([([192, 168, 1, 20], [1, 1, 1, 1], 443, 6, 70_000), ([192, 168, 1, 21], [8, 8, 8, 8], 53, 17, 120)])
    let records = NetFlowV5.parse(packet)
    #expect(records.count == 2)
    #expect(records[0] == FlowRecord(source: "192.168.1.20", destination: "1.1.1.1", sourcePort: 49153, destinationPort: 443,
                                     protocolNumber: 6, packets: 3, bytes: 70_000))
    #expect(NetFlowV5.protocolName(records[1].protocolNumber) == "UDP")

    for length in 0..<packet.count { #expect(NetFlowV5.parse(Array(packet.prefix(length))).isEmpty) }   // truncated
    var wrongVersion = packet
    wrongVersion[1] = 9
    #expect(NetFlowV5.parse(wrongVersion).isEmpty)
    var absurdCount = packet
    absurdCount[2] = 0xFF
    #expect(NetFlowV5.parse(absurdCount).isEmpty)
}

@Test func collectorReceivesAndSummarises() async throws {
    let collector = FlowCollector()
    let port = UInt16.random(in: 40_000...60_000)
    try collector.start(port: port)
    defer { collector.stop() }

    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    for packet in [netflowPacket([([192, 168, 1, 20], [1, 1, 1, 1], 443, 6, 1_000), ([192, 168, 1, 20], [9, 9, 9, 9], 443, 6, 500)]),
                   [0xDE, 0xAD],                                                  // junk is ignored
                   netflowPacket([([192, 168, 1, 21], [1, 1, 1, 1], 53, 17, 100)])] {
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    for _ in 0..<50 where collector.snapshot().flows < 3 { try await Task.sleep(for: .milliseconds(20)) }

    let summary = collector.snapshot()
    #expect(summary.flows == 3 && summary.totalBytes == 1_600)
    #expect(summary.byProtocol == ["TCP": 1_500, "UDP": 100])
    #expect(summary.byDestinationPort[443] == 1_500 && summary.byDestination["1.1.1.1"] == 1_100)
    #expect(summary.bySource["192.168.1.20"] == 1_500)
    #expect(summary.exporters == ["127.0.0.1"])

    collector.stop()
    #expect(!collector.isRunning)
}

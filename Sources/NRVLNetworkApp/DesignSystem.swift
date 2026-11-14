import NRVLCore
import SwiftUI

extension Color {
    /// Matches the app icon's cyan.
    static let nrvlAccent = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// The single place that decides how provenance is labelled and coloured.
extension Confidence {
    var badge: Badge {
        switch self {
        case .confirmed: Badge(text: "Confirmed", color: .green)
        case .inferred: Badge(text: "Inferred", color: .orange)
        }
    }

    var explanation: String {
        switch self {
        case .confirmed: "Reported directly by the device, the network or an integration."
        case .inferred: "Deduced from indirect evidence; may be wrong."
        }
    }
}

extension Freshness {
    var badge: Badge {
        switch self {
        case .live: Badge(text: "Live", color: .nrvlAccent)
        case .historical: Badge(text: "Historical", color: .secondary)
        case .estimated: Badge(text: "Estimated", color: .yellow)
        }
    }

    var explanation: String {
        switch self {
        case .live: "Measured within the current refresh interval."
        case .historical: "Read from stored records."
        case .estimated: "Calculated from other measurements, not measured directly."
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// SF Symbol for a device type label from `DeviceClassifier`.
func deviceSymbol(_ kind: String?) -> String {
    guard let kind else { return "questionmark.square.dashed" }
    let table: [(String, String)] = [
        ("Router", "wifi.router"), ("laptop", "laptopcomputer"), ("Mac", "desktopcomputer"), ("Printer", "printer"),
        ("Scanner", "scanner"), ("TV", "tv"), ("Cast", "tv"), ("HomePod", "hifispeaker"), ("Speaker", "hifispeaker"),
        ("iPhone", "iphone"), ("iPad", "ipad"), ("HomeKit", "homekit"), ("Smart-home", "homekit"),
        ("AirPlay", "airplayvideo"), ("server", "externaldrive.connected.to.line.below"), ("Computer", "desktopcomputer"),
    ]
    return table.first { kind.contains($0.0) }?.1 ?? "network"
}

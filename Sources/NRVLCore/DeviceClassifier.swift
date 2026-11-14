import Foundation

public struct ConnectionEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// First time this device was ever recorded.
        case discovered
        case appeared
        /// Not seen for several consecutive scans.
        case disappeared
    }

    public var kind: Kind
    public var date: Date

    public init(kind: Kind, date: Date) {
        self.kind = kind
        self.date = date
    }
}

public struct DeviceClassification: Sendable, Hashable {
    public var kind: String
    /// Why the app believes this — shown next to the value.
    public var basis: String
    public var confidence: Confidence
}

public enum DeviceClassifier {
    /// Nil when there is no evidence. Never guesses from the manufacturer alone.
    public static func classify(_ device: Device, isGateway: Bool) -> DeviceClassification? {
        if device.isThisMac {
            return DeviceClassification(kind: "Mac", basis: "This computer", confidence: .confirmed)
        }
        if isGateway {
            return DeviceClassification(kind: "Router / Gateway", basis: "It is this Mac's default gateway", confidence: .confirmed)
        }
        if let model = device.model, let kind = models.first(where: { model.hasPrefix($0.prefix) })?.kind {
            return DeviceClassification(kind: kind, basis: "Reports model \(model) over Bonjour", confidence: .confirmed)
        }
        for (service, kind) in services where device.services.contains(service) {
            return DeviceClassification(kind: kind, basis: "Advertises \(service)", confidence: .inferred)
        }
        return nil
    }

    // Ordered: first match wins, so longer prefixes come before "Mac".
    private static let models: [(prefix: String, kind: String)] = [
        ("MacBook", "Mac laptop"), ("iMac", "Mac desktop"), ("Macmini", "Mac desktop"), ("MacPro", "Mac desktop"),
        ("MacStudio", "Mac desktop"), ("Mac", "Mac"), ("AppleTV", "Apple TV"), ("AudioAccessory", "HomePod"),
        ("iPhone", "iPhone"), ("iPad", "iPad"), ("AirPort", "AirPort base station"), ("TimeCapsule", "Time Capsule"),
    ]

    // Ordered from most to least specific.
    private static let services: [(String, String)] = [
        ("_ipp._tcp", "Printer"), ("_ipps._tcp", "Printer"), ("_printer._tcp", "Printer"), ("_pdl-datastream._tcp", "Printer"),
        ("_scanner._tcp", "Scanner"), ("_uscan._tcp", "Scanner"),
        ("_googlecast._tcp", "Google Cast device"),
        ("_sonos._tcp", "Speaker"), ("_spotify-connect._tcp", "Speaker"),
        ("_hap._tcp", "HomeKit accessory"), ("_matter._tcp", "Smart-home device"),
        ("_airplay._tcp", "AirPlay device"), ("_raop._tcp", "AirPlay device"),
        ("_smb._tcp", "Computer or file server"), ("_afpovertcp._tcp", "Computer or file server"), ("_nfs._tcp", "File server"),
        ("_ssh._tcp", "Computer"), ("_sftp-ssh._tcp", "Computer"), ("_rfb._tcp", "Computer"),
        ("_companion-link._tcp", "Apple device"),
    ]
}

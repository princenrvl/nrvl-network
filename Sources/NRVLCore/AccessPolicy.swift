import Foundation

/// A rule the user created saying when a device (or every device in a group) should be blocked.
public struct AccessPolicy: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        /// Blocked until the policy is removed.
        case block
        /// Blocked until `until`.
        case pause
        /// Blocked every listed weekday between `startMinute` and `endMinute` (minutes after midnight, local time).
        case schedule
    }

    public enum Target: Sendable, Equatable {
        case device(Device.ID)
        case group(String)
    }

    public var id: Int64
    public var kind: Kind
    public var target: Target
    public var until: Date?
    public var startMinute: Int?
    public var endMinute: Int?
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    public var createdAt: Date

    public init(id: Int64 = 0, kind: Kind, target: Target, until: Date? = nil, startMinute: Int? = nil, endMinute: Int? = nil,
                weekdays: Set<Int> = [], createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.target = target
        self.until = until
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.weekdays = weekdays
        self.createdAt = createdAt
    }

    public func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
        switch kind {
        case .block:
            return true
        case .pause:
            return until.map { $0 > date } ?? false
        case .schedule:
            guard let start = startMinute, let end = endMinute, start != end else { return false }
            let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
            guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return false }
            let now = hour * 60 + minute
            if start < end { return weekdays.contains(weekday) && (start..<end).contains(now) }
            // Overnight window, e.g. 22:00–06:00: the early-morning part belongs to the previous day's schedule.
            let yesterday = weekday == 1 ? 7 : weekday - 1
            return (weekdays.contains(weekday) && now >= start) || (weekdays.contains(yesterday) && now < end)
        }
    }

    /// Group policies never apply to devices the user marked as trusted (the allowlist).
    public func applies(to device: Device) -> Bool {
        switch target {
        case .device(let id): id == device.id
        case .group(let name): device.group == name && !device.isTrusted
        }
    }

    /// The first policy that wants this device blocked right now, if any.
    public static func blocking(_ device: Device, among policies: [AccessPolicy], at date: Date, calendar: Calendar = .current) -> AccessPolicy? {
        policies.first { $0.applies(to: device) && $0.isActive(at: date, calendar: calendar) }
    }
}

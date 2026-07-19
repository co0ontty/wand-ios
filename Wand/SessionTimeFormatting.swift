import Foundation

enum SessionTimeFormatting {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoFormatter = ISO8601DateFormatter()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return fractionalFormatter.date(from: value) ?? isoFormatter.date(from: value)
    }

    static func sortTimestamp(timestamp: String?, mtimeMs: Double?) -> Double {
        if let mtimeMs { return mtimeMs / 1000 }
        return date(from: timestamp)?.timeIntervalSince1970 ?? 0
    }

    static func relativeTime(for value: String?, relativeTo referenceDate: Date = Date()) -> String {
        guard let timestamp = date(from: value) else { return "" }
        return relativeFormatter.localizedString(for: timestamp, relativeTo: referenceDate)
    }

    static func duration(startedAt: String?, endedAt: String?, now: Date = Date()) -> String {
        guard let started = date(from: startedAt) else { return "" }
        let ended = date(from: endedAt) ?? now
        let seconds = max(0, Int(ended.timeIntervalSince(started)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }
}

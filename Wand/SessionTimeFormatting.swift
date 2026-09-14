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

    /// 聊天消息时间：当天只显示时分秒，跨天才带月/日。对齐 Android formatChatClock。
    static func chatClock(iso: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date = date(from: iso) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        let clock = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return "\(month)/\(day) \(clock)"
    }

    static func conversationTurnClock(_ turn: ConversationTurn, now: Date = Date()) -> String {
        chatClock(iso: turn.completedAt ?? turn.createdAt, now: now)
    }

    static func nowISO(_ date: Date = Date()) -> String {
        fractionalFormatter.string(from: date)
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

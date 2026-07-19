import Foundation
import UIKit
import UserNotifications

/// 会话本地通知。无需 APNs / 推送证书，适合自签安装；只要 App 进程仍有机会轮询，
/// 就能在回复完成或等待授权时发系统通知。App 被系统彻底挂起后无法继续获取新状态。
@MainActor
final class SessionNotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = SessionNotificationController()

    private enum SessionState: Equatable {
        case responding
        case permission
        case idle
        case ended
    }

    private let center = UNUserNotificationCenter.current()
    private var states: [String: SessionState] = [:]
    private var sentAt: [String: Date] = [:]
    private var hasBaseline = false

    private override init() {
        super.init()
    }

    func configure(requestPermission: Bool = true) {
        center.delegate = self
        if requestPermission, ServerStore.shared.notificationsEnabled {
            requestAuthorization()
        }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    func clearPending() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        center.setBadgeCount(0)
    }

    func sendTestNotification() {
        send(
            id: "wand.notification.test",
            title: "Wand 通知正常",
            body: "回复完成和等待授权时会在这里提醒你。",
            sessionId: nil,
            interruptionLevel: .active
        )
    }

    func sendWebNotification(title: String, body: String, tag: String) {
        guard ServerStore.shared.notificationsEnabled else { return }
        let sessionId = sessionId(from: tag)
        send(
            id: normalizedIdentifier(tag: tag, sessionId: sessionId),
            title: title.isEmpty ? "Wand" : title,
            body: body,
            sessionId: sessionId,
            interruptionLevel: tag.hasPrefix("permission:") ? .timeSensitive : .active
        )
    }

    /// 从全局会话快照识别状态跃迁。首次同步只建立基线，避免冷启动把旧状态全通知一遍。
    func reconcile(snapshots: [SessionSnapshot]) {
        let visible = snapshots.filter { !($0.archived ?? false) }
        let nextStates = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, state(for: $0)) })
        guard hasBaseline else {
            states = nextStates
            hasBaseline = true
            return
        }

        if ServerStore.shared.notificationsEnabled,
           UIApplication.shared.applicationState != .active {
            for snapshot in visible {
                let current = nextStates[snapshot.id] ?? .idle
                let previous = states[snapshot.id]
                if current == .permission, previous != .permission {
                    send(
                        id: "wand.permission.\(snapshot.id)",
                        title: "需要你的授权",
                        body: notificationBody(for: snapshot, fallback: "会话正在等待确认后继续"),
                        sessionId: snapshot.id,
                        interruptionLevel: .timeSensitive
                    )
                } else if previous == .responding, current == .idle {
                    send(
                        id: "wand.completed.\(snapshot.id)",
                        title: "回复已完成",
                        body: notificationBody(for: snapshot, fallback: "点击查看会话结果"),
                        sessionId: snapshot.id,
                        interruptionLevel: .active
                    )
                }
            }
        }
        states = nextStates
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.identifier == "wand.notification.test" ? [.banner, .sound] : []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let sessionId = response.notification.request.content.userInfo["sessionId"] as? String,
              !sessionId.isEmpty else { return }
        QuickActionCoordinator.shared.enqueue(.openSession(id: sessionId))
    }

    private func state(for snapshot: SessionSnapshot) -> SessionState {
        if snapshot.hasPendingPermission { return .permission }
        if snapshot.isResponding { return .responding }
        if snapshot.isEnded { return .ended }
        return .idle
    }

    private func notificationBody(for snapshot: SessionSnapshot, fallback: String) -> String {
        let detail = snapshot.currentTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, !detail.isEmpty, detail != snapshot.displayTitle {
            return "\(snapshot.displayTitle)\n\(detail)"
        }
        return snapshot.displayTitle == "会话" ? fallback : snapshot.displayTitle
    }

    private func send(
        id: String,
        title: String,
        body: String,
        sessionId: String?,
        interruptionLevel: UNNotificationInterruptionLevel
    ) {
        if let last = sentAt[id], Date().timeIntervalSince(last) < 10 { return }
        sentAt[id] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruptionLevel
        content.threadIdentifier = sessionId ?? "wand"
        if let sessionId {
            content.userInfo = ["sessionId": sessionId]
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func sessionId(from tag: String) -> String? {
        for prefix in ["permission:wand-perm-", "task-ended:wand-ended-", "wand-perm-", "wand-ended-"]
        where tag.hasPrefix(prefix) {
            return String(tag.dropFirst(prefix.count))
        }
        return nil
    }

    private func normalizedIdentifier(tag: String, sessionId: String?) -> String {
        guard let sessionId else { return tag.isEmpty ? UUID().uuidString : tag }
        if tag.contains("perm") { return "wand.permission.\(sessionId)" }
        if tag.contains("ended") { return "wand.completed.\(sessionId)" }
        return tag
    }
}

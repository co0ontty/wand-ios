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
    private var baselinedServerIDs: Set<String> = []

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
            serverID: nil,
            interruptionLevel: .active
        )
    }

    func sendWebNotification(
        title: String,
        body: String,
        tag: String,
        serverID: String? = nil
    ) {
        guard ServerStore.shared.notificationsEnabled else { return }
        let sessionId = sessionId(from: tag)
        let serverID = serverID ?? ServerStore.shared.activeServerID
        send(
            id: normalizedIdentifier(tag: tag, sessionId: sessionId, serverID: serverID),
            title: title.isEmpty ? "Wand" : title,
            body: body,
            sessionId: sessionId,
            serverID: serverID,
            interruptionLevel: tag.hasPrefix("permission:") ? .timeSensitive : .active
        )
    }

    /// 从全局会话快照识别状态跃迁。首次同步只建立基线，避免冷启动把旧状态全通知一遍。
    func reconcile(snapshots: [SessionSnapshot], serverID: String? = nil) {
        let serverID = serverID ?? ServerStore.shared.activeServerID ?? "legacy"
        let visible = snapshots.filter { !($0.archived ?? false) }
        let key: (String) -> String = { "\(serverID):\($0)" }
        let nextStates = Dictionary(uniqueKeysWithValues: visible.map { (key($0.id), state(for: $0)) })
        guard baselinedServerIDs.contains(serverID) else {
            states.merge(nextStates) { _, new in new }
            baselinedServerIDs.insert(serverID)
            return
        }

        if ServerStore.shared.notificationsEnabled,
           UIApplication.shared.applicationState != .active {
            for snapshot in visible {
                let scopedID = key(snapshot.id)
                let current = nextStates[scopedID] ?? .idle
                let previous = states[scopedID]
                if current == .permission, previous != .permission {
                    send(
                        id: "wand.permission.\(serverID).\(snapshot.id)",
                        title: "需要你的授权",
                        body: notificationBody(for: snapshot, fallback: "会话正在等待确认后继续"),
                        sessionId: snapshot.id,
                        serverID: serverID,
                        interruptionLevel: .timeSensitive
                    )
                } else if previous == .responding, current == .idle {
                    send(
                        id: "wand.completed.\(serverID).\(snapshot.id)",
                        title: "回复已完成",
                        body: notificationBody(for: snapshot, fallback: "点击查看会话结果"),
                        sessionId: snapshot.id,
                        serverID: serverID,
                        interruptionLevel: .active
                    )
                }
            }
        }
        states = states.filter { !$0.key.hasPrefix("\(serverID):") }
        states.merge(nextStates) { _, new in new }
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
        let serverID = response.notification.request.content.userInfo["serverId"] as? String
        QuickActionCoordinator.shared.enqueue(.openSession(id: sessionId, serverID: serverID))
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
        serverID: String?,
        interruptionLevel: UNNotificationInterruptionLevel
    ) {
        if let last = sentAt[id], Date().timeIntervalSince(last) < 10 { return }
        sentAt[id] = Date()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruptionLevel
        content.threadIdentifier = [serverID, sessionId].compactMap { $0 }.joined(separator: ":").nilIfEmpty ?? "wand"
        if let sessionId {
            var userInfo: [String: Any] = ["sessionId": sessionId]
            if let serverID { userInfo["serverId"] = serverID }
            content.userInfo = userInfo
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

    private func normalizedIdentifier(tag: String, sessionId: String?, serverID: String?) -> String {
        guard let sessionId else { return tag.isEmpty ? UUID().uuidString : tag }
        let scope = serverID.map { ".\($0)" } ?? ""
        if tag.contains("perm") { return "wand.permission\(scope).\(sessionId)" }
        if tag.contains("ended") { return "wand.completed\(scope).\(sessionId)" }
        return tag
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

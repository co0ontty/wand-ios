import Foundation
import UIKit
import UserNotifications

/// 统一通知权限与点击入口。服务器启用 APNs 后不再重复生成同类本地通知；
/// 旧服务器/无推送签名保留本地回退，该回退在 App 被挂起后无法获取新状态。
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
        Task { _ = await requestAuthorizationAndWait() }
    }

    func requestAuthorizationAndWait() async -> Bool {
        let granted: Bool = await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
        RemoteNotificationController.shared.refresh()
        return granted
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
           !RemoteNotificationController.shared.suppressesLocal(for: serverID),
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
                        interruptionLevel: .active
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
        let info = response.notification.request.content.userInfo
        if info["aps"] != nil {
            guard ServerStore.shared.notificationsEnabled,
                  let target = RemoteNotificationPolicy.target(info, knownServerIDs: Set(ServerStore.shared.profiles.map(\.id))) else { return }
            QuickActionCoordinator.shared.enqueue(.openSession(id: target.sessionID, serverID: target.serverID))
            return
        }
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

    /// 与服务器 APNs 正文同口径：先给具体任务名（会话标题），没有标题才用摘要，最后才用兜底文案。
    /// 正在执行的子任务名与标题不同时补一行；两者相同不重复，避免正文被重复文案挤满。
    private func notificationBody(for snapshot: SessionSnapshot, fallback: String) -> String {
        let name = [snapshot.title, snapshot.summary]
            .compactMap { $0?.singleLineNotificationText }
            .first { !$0.isEmpty }
        let detail = snapshot.currentTaskTitle?.singleLineNotificationText ?? ""
        var lines = name.map { [$0] } ?? []
        if !detail.isEmpty, detail != name { lines.append(detail) }
        return lines.isEmpty ? fallback : lines.joined(separator: "\n")
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    /// 通知正文只排单行：标题里的换行与连续空白压成空格，避免把正文挤断或撑成多行空白。
    var singleLineNotificationText: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

import Foundation

struct RemoteNotificationBinding: Codable, Equatable {
    let serverID: String
    let endpoint: URL
    let connectionIdentity: String
    /// Device-only revocation capability; never a Wand login credential.
    let secret: String
    var leaseUntil: Date
    var confirmed: Bool

    func suppressesLocal(serverID: String, identity: String, now: Date = Date()) -> Bool {
        self.serverID == serverID && connectionIdentity == identity && leaseUntil > now
    }
}

enum RemoteNotificationPolicy {
    static let subscriptionPath = "/api/push/apns/subscription"

    static func environment(_ value: String?) -> String? {
        switch value {
        case "development", "sandbox": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }

    static func registrationRejected(status: Int, code: String?) -> Bool {
        [400, 401, 403, 404, 405].contains(status) || (status == 503 && code == "apns_unavailable")
    }

    static func target(_ info: [AnyHashable: Any], knownServerIDs: Set<String>) -> (sessionID: String, serverID: String)? {
        guard let serverID = info["serverId"] as? String, knownServerIDs.contains(serverID),
              let sessionID = info["sessionId"] as? String, !sessionID.isEmpty, sessionID.utf8.count <= 256,
              !sessionID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let eventID = info["eventId"] as? String,
              eventID.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return (sessionID, serverID)
    }
}

#if canImport(UIKit)
import UIKit
import UserNotifications
import Combine
import Security

/// Revocation survives profile deletion without retaining the old app token. Device-only, non-syncing Keychain storage.
enum PushCapabilityVault {
    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Wand") + ".apns",
         kSecAttrAccount as String: account]
    }

    static func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65_536 else { throw CocoaError(.fileWriteUnknown) }
        let query = query(account: account)
        var changes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            changes.merge(query) { _, new in new }
            guard SecItemAdd(changes as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        } else if status != errSecSuccess { throw CocoaError(.fileWriteNoPermission) }
    }

    static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileReadUnknown)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One serialized revision loop owns registration and revocation. No background keep-alive or silent push is needed.
@MainActor
final class RemoteNotificationController: ObservableObject {
    static let shared = RemoteNotificationController()
    @Published private(set) var status = "正在检查远程通知…"
    private var configured = false
    private var observers = Set<AnyCancellable>()
    private var deviceToken: String?
    private var bindings: [RemoteNotificationBinding] = []
    private var vaultLoaded = false
    private var revision = 0
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 30
    private var retryNeeded = false

    private var environment: String? {
#if targetEnvironment(simulator)
        nil
#else
        RemoteNotificationPolicy.environment(Bundle.main.object(forInfoDictionaryKey: "WandAPNSEnvironment") as? String)
#endif
    }

    func configure() {
        guard !configured else { return }
        configured = true
        ServerStore.shared.$profileState.combineLatest(ServerStore.shared.$notificationsEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &observers)
        refresh()
    }

    func refresh() {
        guard configured else { return }
        retryTask?.cancel()
        retryTask = nil
        if !ServerStore.shared.notificationsEnabled || ServerStore.shared.activeProfile == nil {
            UIApplication.shared.unregisterForRemoteNotifications()
            deviceToken = nil
        }
        requestSync()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if ServerStore.shared.notificationsEnabled, ServerStore.shared.activeProfile != nil, environment != nil,
               [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
            requestSync()
        }
    }

    func registered(deviceToken: Data) {
        // APNs token is obtained afresh each launch, not cached in local storage.
        self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        requestSync()
    }

    func registrationFailed() {
        status = "设备推送注册暂不可用，将在回到前台后重试"
        // Existing bindings may still deliver; do not switch on duplicate local generation on an unknown failure.
        requestSync()
    }

    func suppressesLocal(for serverID: String) -> Bool {
        guard ServerStore.shared.notificationsEnabled,
              let profile = ServerStore.shared.activeProfile, profile.id == serverID else { return false }
        return bindings.contains { $0.suppressesLocal(serverID: serverID, identity: profile.connectionIdentity) }
    }

    private func requestSync() {
        revision &+= 1
        guard configured, syncTask == nil else { return }
        syncTask = Task {
            repeat {
                let captured = revision
                retryNeeded = false
                await synchronize(revision: captured)
                if captured == revision { break }
            } while !Task.isCancelled
            syncTask = nil
            if retryNeeded, UIApplication.shared.applicationState == .active {
                let delay = retryDelay
                retryDelay = min(retryDelay * 2, 300)
                retryTask = Task {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    requestSync()
                }
            }
        }
    }

    private func persist(_ next: [RemoteNotificationBinding]) throws {
        try PushCapabilityVault.save(next, account: "subscriptions.v1")
        bindings = next
    }

    private func synchronize(revision captured: Int) async {
        do {
            if !vaultLoaded {
                bindings = try PushCapabilityVault.load([RemoteNotificationBinding].self, account: "subscriptions.v1") ?? []
                guard bindings.count <= 32 else { throw CocoaError(.fileReadCorruptFile) }
                vaultLoaded = true
            }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard captured == revision else { return }
            let store = ServerStore.shared
            let allowed = store.notificationsEnabled && [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            let desired = allowed && environment != nil ? store.activeProfile : nil

            // Never re-login to a removed server. A capability can only revoke its own binding.
            for binding in bindings where desired?.connectionIdentity != binding.connectionIdentity {
                do {
                    let (_, response) = try await send(endpoint: binding.endpoint, method: "DELETE", bearer: binding.secret)
                    if response.statusCode == 204 {
                        try persist(bindings.filter { $0.secret != binding.secret })
                    } else { retryNeeded = true }
                } catch { retryNeeded = true }
                guard captured == revision else { return }
            }
            guard let profile = desired, let appToken = profile.token, !appToken.isEmpty else {
                status = !allowed ? "通知已关闭" : environment == nil ? "此安装包未启用 APNs，使用本地通知" : desired != nil ? "此连接缺少应用凭据，使用本地通知" : "连接服务器后启用远程通知"
                if retryNeeded { status += "；旧订阅撤销待联网完成" }
                return
            }
            guard let deviceToken, let environment else {
                status = "正在向 Apple 注册设备…"
                return
            }
            guard captured == revision else { return }
            var binding = bindings.first { $0.connectionIdentity == profile.connectionIdentity }
            if binding == nil {
                guard bindings.count < 32 else { status = "待撤销订阅过多，请联网后重试"; return }
                binding = RemoteNotificationBinding(serverID: profile.id, endpoint: profile.baseURL,
                    connectionIdentity: profile.connectionIdentity, secret: try PushCapabilityVault.secret(),
                    leaseUntil: .distantPast, confirmed: false)
            }
            var pending = binding!
            // Persist BEFORE sending. An unknown PUT response must still be revocable and must not cause local+APNs duplicates.
            pending.leaseUntil = Date().addingTimeInterval(14 * 86_400)
            try persist(bindings.filter { $0.secret != pending.secret } + [pending])
            let body: [String: Any] = ["secret": pending.secret, "deviceToken": deviceToken,
                "environment": environment, "serverId": profile.id]
            do {
                let (data, response) = try await send(endpoint: profile.baseURL, method: "PUT", bearer: appToken, body: body)
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if response.statusCode == 200, payload?["available"] as? Bool == true {
                    pending.confirmed = true
                    pending.leaseUntil = Date().addingTimeInterval(14 * 86_400)
                    retryDelay = 30
                } else if RemoteNotificationPolicy.registrationRejected(status: response.statusCode, code: payload?["code"] as? String) {
                    pending.confirmed = false
                    pending.leaseUntil = .distantPast
                } else { retryNeeded = true }
                try persist(bindings.filter { $0.secret != pending.secret } + [pending])
                guard captured == revision else { return } // next loop revokes a late accepted registration for the retired profile.
                status = pending.confirmed ? "APNs 远程通知已启用" : pending.leaseUntil > Date() ? "远程通知注册待确认，将自动重试" : "服务器推送未启用或环境不匹配，使用本地通知"
                if retryNeeded { status += "；部分订阅操作待联网完成" }
            } catch {
                retryNeeded = true
                if captured == revision { status = "远程通知注册待联网确认" }
            }
        } catch {
            status = "无法安全读取或保存设备推送凭据，请解锁后重试"
        }
    }

    private func send(endpoint: URL, method: String, bearer: String, body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        return try await PushSubscriptionTransport.send(endpoint: endpoint, path: RemoteNotificationPolicy.subscriptionPath, method: method, bearer: bearer, body: body)
    }
}

/// Same endpoint-bounded transport for ordinary notifications and ActivityKit; neither can re-login a retired profile.
@MainActor
enum PushSubscriptionTransport {
    static func send(endpoint: URL, path: String, method: String, bearer: String, body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = WandEndpoint.url(baseURL: endpoint, route: path) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        // Endpoint-bounded TLS/redirect handling, isolated from login cookies and retired profile sessions.
        let connection = SelfSignedSession.temporary(forEndpoint: endpoint)
        defer { connection.invalidate() }
        let (data, response) = try await connection.session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 4096 else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
#endif

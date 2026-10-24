import Foundation

struct LiveActivityPushBinding: Codable, Equatable {
    let activityID: String
    let serverID: String
    let endpoint: URL
    let connectionIdentity: String
    let secret: String
    var leaseUntil: Date
    var confirmed: Bool
}

enum LiveActivityPushPolicy {
    static let path = "/api/push/apns/live-activity"
    static func remainingLinger(since: Date?, now: Date, duration: TimeInterval) -> TimeInterval {
        guard let since else { return 0 } // Legacy finished entries have no trustworthy completion anchor.
        return min(duration, max(0, duration - now.timeIntervalSince(since)))
    }
    static func owns(activityServerID: String?, activityIdentity: String?, currentServerID: String?, origin: String, currentIdentity: String?, enabled: Bool) -> Bool {
        enabled && currentServerID != nil && activityServerID == currentServerID
            && activityIdentity != nil && activityIdentity == currentIdentity && origin == currentIdentity
    }
}

#if canImport(UIKit)
import UIKit
import ActivityKit
import Combine

/// Activity-specific token lifetime, separate from UNUserNotificationCenter authorization and ordinary device tokens.
@MainActor
final class LiveActivityPushController: ObservableObject {
    static let shared = LiveActivityPushController()
    @Published private(set) var status = "任务运行时创建灵动岛活动"
    static var supportsPush: Bool {
#if targetEnvironment(simulator)
        false
#else
        RemoteNotificationPolicy.environment(Bundle.main.object(forInfoDictionaryKey: "WandAPNSEnvironment") as? String) != nil
#endif
    }
    private final class Observation {
        let activity: Activity<SessionActivityAttributes>
        let origin: String
        var token: String?
        var tasks: [Task<Void, Never>] = []
        init(activity: Activity<SessionActivityAttributes>, origin: String) { self.activity = activity; self.origin = origin }
    }
    private var configured = false
    private var loaded = false
    private var bindings: [LiveActivityPushBinding] = []
    private var observations: [String: Observation] = [:]
    private var endingIDs = Set<String>()
    private var retiredIDs = Set<String>()
    private var observers = Set<AnyCancellable>()
    private var activityTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var revision = 0
    private var retryNeeded = false
    private var retryDelay: UInt64 = 30

    private var enabled: Bool {
        ServerStore.shared.liveActivityEnabled && ActivityAuthorizationInfo().areActivitiesEnabled && Self.supportsPush
    }
    func configure() {
        guard !configured else { return }
        configured = true
        ServerStore.shared.$profileState.combineLatest(ServerStore.shared.$liveActivityEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &observers)
        activityTask = Task { [weak self] in
            for await activity in Activity<SessionActivityAttributes>.activityUpdates {
                guard !Task.isCancelled else { return }
                self?.observe(activity)
            }
        }
        refresh()
    }
    private func load() throws {
        guard !loaded else { return }
        bindings = try PushCapabilityVault.load([LiveActivityPushBinding].self, account: "live-activities.v1") ?? []
        guard bindings.count <= 32 else { throw CocoaError(.fileReadCorruptFile) }
        loaded = true
    }
    private func persist(_ next: [LiveActivityPushBinding]) throws {
        try PushCapabilityVault.save(next, account: "live-activities.v1")
        bindings = next
    }
    func refresh() {
        guard configured else { return }
        retryTask?.cancel(); retryTask = nil
        do { try load() }
        catch { status = "解锁后才能读取灵动岛推送凭据"; return }
        pruneRetired()
        let profile = ServerStore.shared.activeProfile
        for (id, item) in observations where !LiveActivityPushPolicy.owns(
            activityServerID: item.activity.attributes.serverID, activityIdentity: item.activity.attributes.connectionIdentity, currentServerID: profile?.id,
            origin: item.origin, currentIdentity: profile?.connectionIdentity, enabled: enabled
        ) {
            retire(activityID: id)
            endLocally(item.activity)
        }
        if !ServerStore.shared.liveActivityEnabled || !ActivityAuthorizationInfo().areActivitiesEnabled {
            SessionLiveActivityController.shared.endAll()
        } else if enabled {
            for activity in Activity<SessionActivityAttributes>.activities { observe(activity) }
        }
        requestSync()
    }

    func observe(_ activity: Activity<SessionActivityAttributes>) {
        guard configured, enabled, !retiredIDs.contains(activity.id), activity.attributes.remoteUpdates == true,
              let profile = ServerStore.shared.activeProfile, activity.attributes.serverID == profile.id,
              activity.activityState == .active || activity.activityState == .stale else { return }
        do { try load() }
        catch { status = "无法安全读取灵动岛推送凭据"; return }
        if activity.attributes.connectionIdentity != profile.connectionIdentity {
            endLocally(activity)
            requestSync()
            return
        }
        if let old = bindings.first(where: { $0.activityID == activity.id }), old.connectionIdentity != profile.connectionIdentity {
            // A restored activity belongs to the old credential, not whichever server/credential is selected now.
            endLocally(activity)
            requestSync()
            return
        }
        let id = activity.id
        if let existing = observations[id] {
            if let token = activity.pushToken { existing.token = Self.hex(token) }
            return
        }
        let item = Observation(activity: activity, origin: profile.connectionIdentity)
        item.token = activity.pushToken.map(Self.hex)
        observations[id] = item
        item.tasks = [
            Task { [weak self] in
                for await token in activity.pushTokenUpdates {
                    guard !Task.isCancelled, let self, let current = self.observations[id] else { return }
                    current.token = Self.hex(token)
                    self.requestSync()
                }
            },
            Task { [weak self] in
                for await state in activity.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    if state == .ended || state == .dismissed {
                        self?.retire(activityID: id)
                        SessionLiveActivityController.shared.remoteActivityEnded(id: id)
                        return
                    }
                }
            }
        ]
        requestSync()
    }
    private func endLocally(_ activity: Activity<SessionActivityAttributes>) {
        guard endingIDs.insert(activity.id).inserted else { return }
        retire(activityID: activity.id)
        SessionLiveActivityController.shared.remoteActivityEnded(id: activity.id)
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            endingIDs.remove(activity.id)
        }
    }
    private static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }
    private func pruneRetired() {
        let activeIDs = Set(Activity<SessionActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }.map(\.id))
        retiredIDs.formIntersection(activeIDs)
    }
    func retire(activityID: String) {
        pruneRetired()
        retiredIDs.insert(activityID)
        if let item = observations.removeValue(forKey: activityID) { for task in item.tasks { task.cancel() } }
        requestSync()
    }
    func isRegistered(activityID: String) -> Bool {
        guard enabled, let profile = ServerStore.shared.activeProfile else { return false }
        return bindings.contains { $0.activityID == activityID && $0.connectionIdentity == profile.connectionIdentity && $0.confirmed && $0.leaseUntil > Date() }
    }
    private func eligible(_ item: Observation, profile: ServerProfile?) -> Bool {
        ServerStore.shared.activeProfile?.connectionIdentity == profile?.connectionIdentity
            && LiveActivityPushPolicy.owns(activityServerID: item.activity.attributes.serverID, activityIdentity: item.activity.attributes.connectionIdentity, currentServerID: profile?.id,
            origin: item.origin, currentIdentity: profile?.connectionIdentity, enabled: enabled)
            && (item.activity.activityState == .active || item.activity.activityState == .stale)
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
                let delay = retryDelay; retryDelay = min(300, retryDelay * 2)
                retryTask = Task {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    requestSync()
                }
            }
        }
    }
    private func synchronize(revision captured: Int) async {
        do {
            try load()
            let profile = ServerStore.shared.activeProfile
            for binding in bindings {
                let observation = observations[binding.activityID]
                let keep = observation.map { eligible($0, profile: profile) && binding.connectionIdentity == profile?.connectionIdentity } ?? false
                if keep { continue }
                do {
                    let (_, response) = try await PushSubscriptionTransport.send(endpoint: binding.endpoint, path: LiveActivityPushPolicy.path, method: "DELETE", bearer: binding.secret)
                    if response.statusCode == 204 { try persist(bindings.filter { $0.secret != binding.secret }) }
                    else { retryNeeded = true }
                } catch { retryNeeded = true }
                guard captured == revision else { return }
            }
            guard enabled, let profile, let appToken = profile.token, !appToken.isEmpty,
                  let environment = RemoteNotificationPolicy.environment(Bundle.main.object(forInfoDictionaryKey: "WandAPNSEnvironment") as? String) else {
                status = enabled ? "连接服务器后启用灵动岛远程更新" : Self.supportsPush ? "灵动岛已关闭或系统未允许" : "此安装包使用本地灵动岛"
                if retryNeeded { status += "；旧活动撤销待联网完成" }
                return
            }
            var confirmed = 0
            for item in Array(observations.values) where eligible(item, profile: profile) {
                guard captured == revision else { return }
                guard let token = item.token else { continue }
                let id = item.activity.id
                var binding = bindings.first { $0.activityID == id && $0.connectionIdentity == profile.connectionIdentity }
                if binding == nil {
                    guard bindings.count < 32 else { status = "待撤销灵动岛过多，请联网重试"; return }
                    binding = LiveActivityPushBinding(activityID: id, serverID: profile.id, endpoint: profile.baseURL,
                        connectionIdentity: profile.connectionIdentity, secret: try PushCapabilityVault.secret(),
                        leaseUntil: Date().addingTimeInterval(8 * 3600), confirmed: false)
                }
                var pending = binding!
                // A capability is durable before a potentially accepted PUT, so a late callback can always be revoked.
                try persist(bindings.filter { $0.secret != pending.secret } + [pending])
                do {
                    let body: [String: Any] = ["secret": pending.secret, "activityId": id, "activityToken": token,
                        "serverId": profile.id, "environment": environment]
                    let (data, response) = try await PushSubscriptionTransport.send(endpoint: profile.baseURL, path: LiveActivityPushPolicy.path, method: "PUT", bearer: appToken, body: body)
                    let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    if response.statusCode == 200, payload?["available"] as? Bool == true {
                        pending.confirmed = true; retryDelay = 30
                    } else if RemoteNotificationPolicy.registrationRejected(status: response.statusCode, code: payload?["code"] as? String) {
                        pending.confirmed = false
                    } else { retryNeeded = true }
                    try persist(bindings.filter { $0.secret != pending.secret } + [pending])
                    guard captured == revision else { return }
                    if pending.confirmed { confirmed += 1 }
                } catch { retryNeeded = true }
            }
            status = observations.isEmpty ? "任务运行时创建灵动岛，随后可在后台远程更新" : confirmed > 0 ? "灵动岛远程更新已注册" : "灵动岛远程注册待确认；保留本地更新"
            if retryNeeded { status += "；部分订阅操作待联网完成" }
        } catch { status = "无法安全保存灵动岛推送凭据，请解锁后重试" }
    }
}
#endif

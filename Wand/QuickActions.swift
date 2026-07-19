import SwiftUI
import UIKit

/// 长按 App 图标的快捷操作（Home Screen Quick Actions）。
/// 静态项在 Info.plist（新建会话 / 打开网页版）；动态项是最近会话
/// （SessionListView 刷新时通过 updateRecentSessionShortcuts 同步）。
/// 冷启动的 shortcutItem 在 AppDelegate.configurationForConnecting 捕获，
/// App 已在运行时走 SceneDelegate.performActionFor。
enum QuickAction: Equatable {
    case newSession
    case openWeb
    case openSession(id: String)
    case showSessions

    static let newSessionType = "com.wand.app.shortcut.new-session"
    static let openWebType = "com.wand.app.shortcut.open-web"
    static let openSessionType = "com.wand.app.shortcut.open-session"

    init?(shortcutItem: UIApplicationShortcutItem) {
        switch shortcutItem.type {
        case Self.newSessionType:
            self = .newSession
        case Self.openWebType:
            self = .openWeb
        case Self.openSessionType:
            guard let id = shortcutItem.userInfo?["sessionId"] as? String, !id.isEmpty else { return nil }
            self = .openSession(id: id)
        default:
            return nil
        }
    }
}

/// 待处理快捷操作的单例桥：UIKit 委托写入，SwiftUI 视图按归属消费。
/// 写入与消费都发生在主线程（UIKit 委托回调 / SwiftUI onReceive），
/// 刻意不标 @MainActor，避免 View 结构体 nonisolated 方法引用时的隔离摩擦。
final class QuickActionCoordinator: ObservableObject {
    static let shared = QuickActionCoordinator()

    /// 超过这个时长还没被消费的操作视为过期（例如未连接服务器时长按「新建会话」，
    /// 等用户几分钟后才连上就不要再突然弹窗了）。
    private static let maxPendingAge: TimeInterval = 60

    @Published private(set) var pending: QuickAction?
    private var pendingAt = Date.distantPast

    private init() {}

    @discardableResult
    func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(shortcutItem: shortcutItem) else { return false }
        pendingAt = Date()
        pending = action
        return true
    }

    func enqueue(_ action: QuickAction) {
        pendingAt = Date()
        pending = action
    }

    /// 消费匹配的待处理操作；过期或不匹配时返回 nil（不清除，留给真正的归属视图）。
    func consume(where matches: (QuickAction) -> Bool) -> QuickAction? {
        guard let action = pending,
              Date().timeIntervalSince(pendingAt) < Self.maxPendingAge,
              matches(action) else { return nil }
        pending = nil
        return action
    }

    /// 把最近会话同步成动态快捷项（系统把它们排在 Info.plist 静态项之后，最多共展示 4 个）。
    @MainActor
    static func updateRecentSessionShortcuts(_ sessions: [SessionSnapshot]) {
        let recent = sessions.filter { !($0.archived ?? false) }.prefix(2)
        UIApplication.shared.shortcutItems = recent.map { session in
            UIApplicationShortcutItem(
                type: QuickAction.openSessionType,
                localizedTitle: session.displayTitle,
                localizedSubtitle: "\(session.providerLabel) · \(session.isStructured ? "聊天" : "终端")",
                icon: UIApplicationShortcutIcon(systemImageName: "bubble.left.and.bubble.right"),
                userInfo: ["sessionId": session.id as NSString]
            )
        }
    }
}

/// SwiftUI 生命周期下接快捷操作需要自定义 scene delegate：
/// 冷启动（App 因快捷操作被拉起）时 shortcutItem 在 connection options 里。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let isLiveActivityMock: Bool
#if DEBUG
        isLiveActivityMock = ProcessInfo.processInfo.environment["WAND_MOCK_LIVE_ACTIVITY"] != nil
#else
        isLiveActivityMock = false
#endif
        SessionNotificationController.shared.configure(requestPermission: !isLiveActivityMock)
#if DEBUG
        guard !isLiveActivityMock else {
            return true
        }
#endif
        // 等应用完成启动后主动触发本地网络权限检查。未决定时系统会弹框；
        // 已允许或拒绝时不会重复打扰用户。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            LocalNetworkPermission.triggerPromptIfNeeded()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            QuickActionCoordinator.shared.handle(shortcutItem)
        }
        let config = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}

/// App 已在运行（前台/后台）时长按图标触发的路径。
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(QuickActionCoordinator.shared.handle(shortcutItem))
    }
}

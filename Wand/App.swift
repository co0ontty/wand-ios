import SwiftUI

/// iOS 版入口。对称 macOS 的 WandApp，但 iOS 没有菜单栏，所以"切换服务器"
/// 入口放在 ContentView 的悬浮按钮里（同样用 .wandRequestSwitchServer 通知驱动）。
@main
struct WandApp: App {
    /// 接长按图标快捷操作：AppDelegate 捕获冷启动 shortcutItem 并注入自定义 scene delegate。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ServerStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

extension Notification.Name {
    static let wandRequestSwitchServer = Notification.Name("WandRequestSwitchServer")
}

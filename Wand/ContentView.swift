import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ServerStore
    @State private var showSwitchSheet = false
    @ObservedObject private var quickActions = QuickActionCoordinator.shared

    var body: some View {
        ZStack {
            // 全屏背景，避免 ConnectView/加载中状态露出空白
            WandAmbientBackground()
            if let profile = store.activeProfile {
                // 原生客户端为主界面（会话列表 + 聊天 + 权限审批），
                // WebView 退居 NativeRootView 内的「网页版」兜底入口。
                NativeRootView(profile: profile)
                    .id(profile.connectionIdentity)
            } else {
                ConnectView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showSwitchSheet) {
            ConnectView(isPresentedAsSheet: true) { showSwitchSheet = false }
                .environmentObject(store)
                .wandPreferredAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: .wandRequestSwitchServer)) { _ in
            showSwitchSheet = true
        }
        .onReceive(quickActions.$pending) { action in
            guard let targetID = action?.targetServerID,
                  targetID != store.activeServerID else { return }
            if store.profile(id: targetID) != nil {
                store.activateProfile(id: targetID)
            } else {
                // 目标服务器已被移除：保留动作，先让用户重新添加或选择服务器。
                showSwitchSheet = true
            }
        }
    }
}

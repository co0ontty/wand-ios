import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: ServerStore
    @State private var showSwitchSheet = false

    var body: some View {
        ZStack {
            // 全屏背景，避免 ConnectView/加载中状态露出空白
            WandAmbientBackground()
            if let serverURL = store.serverURL {
                // 原生客户端为主界面（会话列表 + 聊天 + 权限审批），
                // WebView 退居 NativeRootView 内的「网页版」兜底入口。
                NativeRootView(serverURL: serverURL, token: store.token)
                    .id(serverURL.absoluteString)
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
    }
}

import SwiftUI

/// 原生设置页：服务器信息 / 功能开关 / 网页版入口 / 关于。
/// 服务端的完整设置（更新通道、Android 下载等）仍在网页版里，这里聚焦客户端本身。
struct SettingsView: View {
    let serverURL: URL
    let token: String?
    /// 请求打开网页版（由 NativeRootView 在 sheet 关闭后呈现 fullScreenCover）。
    let onOpenWeb: () -> Void

    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var serverVersion: String?
    @State private var confirmDisconnect = false

    private var api: WandAPI { WandAPI(baseURL: serverURL, token: token) }

    var body: some View {
        NavigationView {
            Form {
                serverSection
                featureSection
                moreSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.brand)
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            serverVersion = (try? await api.serverConfig())?.currentVersion
        }
        .confirmationDialog("断开后需要重新输入连接码才能连回来。", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    store.disconnect()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 区块

    private var serverSection: some View {
        Section("服务器") {
            infoRow("地址", serverURL.absoluteString, mono: true)
            infoRow("认证方式", (token?.isEmpty == false) ? "连接码" : "无密码")
            if let serverVersion {
                infoRow("服务端版本", "v\(serverVersion)", mono: true)
            }
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                }
            } label: {
                Label("切换服务器", systemImage: "server.rack")
                    .font(.system(size: 15))
            }
            Button(role: .destructive) {
                confirmDisconnect = true
            } label: {
                Label("断开连接", systemImage: "xmark.circle")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.danger)
            }
        }
    }

    private var featureSection: some View {
        Section {
            Toggle("灵动岛 / 实时活动", isOn: $store.liveActivityEnabled)
                .tint(Theme.brand)
        } header: {
            Text("功能")
        } footer: {
            Text("会话运行时在灵动岛与锁屏显示聚合长条：每个会话的缩略标题 + 状态（运行中 / 等待授权 / 已完成）。已退出或被杀的会话不展示。需要 iOS 16.1+；App 被系统挂起后状态会暂停更新。")
        }
    }

    private var moreSection: some View {
        Section {
            Button {
                dismiss()
                onOpenWeb()
            } label: {
                Label("打开网页版（完整设置）", systemImage: "safari")
                    .font(.system(size: 15))
            }
        } footer: {
            Text("更新通道、模型配置等服务端设置在网页版里调整。")
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            infoRow("App 版本", appVersion, mono: true)
            Link(destination: URL(string: "https://github.com/co0ontty/wand")!) {
                Label("GitHub 仓库", systemImage: "link")
                    .font(.system(size: 15))
            }
        }
    }

    // MARK: - 小组件

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "v\(short)"
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

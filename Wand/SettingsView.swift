import SwiftUI
import UIKit
import UserNotifications

/// 原生设置页：服务器信息 / 功能开关 / 网页版入口 / 关于。
/// 服务端的完整设置（更新通道、Android 下载等）仍在网页版里，这里聚焦客户端本身。
struct SettingsView: View {
    let serverURL: URL
    let token: String?
    /// 请求打开网页版（由 NativeRootView 在 sheet 关闭后呈现 fullScreenCover）。
    let onOpenWeb: () -> Void

    @EnvironmentObject private var store: ServerStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WandAppearanceMode.storageKey) private var appearanceModeRaw = WandAppearanceMode.system.rawValue

    @State private var serverVersion: String?
    @State private var confirmDisconnect = false
    @State private var notificationStatus = "读取中…"
    @State private var logShare: LogShareItem?
    @State private var logExportEmpty = false

    private var api: WandAPI { WandAPI(baseURL: serverURL, token: token) }

    var body: some View {
        NavigationStack {
            Form {
                settingsOverview
                appearanceSection
                featureSection
                serverSection
                diagnosticsSection
                clientUpdateSection
                moreSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(WandAmbientBackground())
            .navigationTitle("系统设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(Theme.brand)
        .wandPreferredAppearance()
        .task {
            serverVersion = (try? await api.serverConfig())?.currentVersion
            await refreshNotificationStatus()
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
        .sheet(item: $logShare) { item in
            ActivityView(activityItems: [item.url])
        }
        .alert("最近 5 分钟没有日志", isPresented: $logExportEmpty) {
            Button("好", role: .cancel) {}
        } message: {
            Text("打开会话、收发消息或复现问题后再导出，才能捕获到有用的上下文。")
        }
        .wandKeyboardShortcuts(settingsKeyboardShortcuts)
    }

    private var settingsKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "dismiss-settings",
                title: "完成",
                key: .escape,
                modifiers: []
            ) {
                dismiss()
            },
            WandKeyboardShortcutAction(
                id: "close-settings",
                title: "关闭设置",
                key: "w",
                modifiers: .command
            ) {
                dismiss()
            },
        ]
    }

    // MARK: - 区块

    /// Android 端同样先交代设备、连接和外观；这里保持 iOS Form 的原生信息密度。
    private var settingsOverview: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    WandBrandMark(size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("系统设置")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("连接、设备和工作流偏好都在这里调整。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Text(appVersion)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.surface.opacity(0.82)))
                }
                HStack(spacing: 7) {
                    settingsStatePill(
                        token?.isEmpty == false ? "已安全连接" : "已连接",
                        color: Theme.success
                    )
                    settingsStatePill("iOS 原生", color: Theme.brand)
                    settingsStatePill(currentAppearance.title, color: Theme.brandStrong)
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

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
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("主题", systemImage: currentAppearance.icon)
                        .font(.system(size: 15))
                    Spacer()
                    Text(currentAppearance.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Picker("主题", selection: $appearanceModeRaw) {
                    ForEach(WandAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 6)
        } header: {
            Text("外观")
        } footer: {
            Text("选择明亮、黑暗，或跟随 iOS 系统外观。")
        }
    }

    private var currentAppearance: WandAppearanceMode {
        WandAppearanceMode.resolved(from: appearanceModeRaw)
    }

    private var featureSection: some View {
        Section {
            Toggle("回复完成 / 等待授权通知", isOn: $store.notificationsEnabled)
                .tint(Theme.brand)
                .onChange(of: store.notificationsEnabled) { _, enabled in
                    if enabled {
                        SessionNotificationController.shared.requestAuthorization()
                    } else {
                        SessionNotificationController.shared.clearPending()
                    }
                    Task { await refreshNotificationStatus() }
                }
            Toggle("灵动岛与锁屏进度", isOn: $store.liveActivityEnabled)
                .tint(Theme.brand)
                .onChange(of: store.liveActivityEnabled) { _, enabled in
                    if !enabled { SessionPresenceController.shared.endAll() }
                }
            Button {
                openSystemSettings()
            } label: {
                HStack {
                    Label("系统通知权限", systemImage: "bell.badge")
                    Spacer()
                    Text(notificationStatus)
                        .foregroundStyle(notificationStatus == "已开启" ? .green : Theme.danger)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 14))
            Button {
                SessionNotificationController.shared.sendTestNotification()
            } label: {
                Label("发送测试通知", systemImage: "bell.and.waves.left.and.right")
            }
            .disabled(notificationStatus != "已开启")
        } header: {
            Text("通知")
        } footer: {
            Text("系统通知会在 App 位于后台时提醒回复完成或等待授权。若权限关闭，请到 iOS 设置 → Wand 开启。App 被系统彻底挂起后，通知会暂停更新。")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Button {
                exportLogs()
            } label: {
                Label("导出最近 5 分钟日志", systemImage: "square.and.arrow.up.on.square")
                    .font(.system(size: 15))
            }
        } header: {
            Text("诊断")
        } footer: {
            Text("会话打开后空白、连接异常等偶发问题时，复现后立即来这里导出日志（会话加载 / WebSocket / 网络请求等事件），发给开发者排查。日志只存在本机内存，不含密码。")
        }
    }

    /// iOS 不存在安全的应用内安装 API；把版本与正确的更新路径放在设置中，
    /// 但不伪造 Android 那种可下载 / 安装的流程。
    private var clientUpdateSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.success.opacity(0.13)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("通过签名工具更新")
                        .font(.system(size: 14, weight: .semibold))
                    Text("当前 \(appVersion)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        } header: {
            Text("应用与更新")
        } footer: {
            Text("iOS 自签名应用无法在 App 内下载安装更新。请使用安装 Wand 时的 SideStore、AltStore 或 Sideloadly 刷新签名并安装新版本。")
        }
    }

    /// 拼最近 5 分钟日志写临时文件并弹系统分享面板；窗口内没有日志时给出提示。
    private func exportLogs() {
        guard WandLog.shared.recentCount(within: 5) > 0 else {
            logExportEmpty = true
            return
        }
        guard let url = WandLog.shared.exportToFile(within: 5) else { return }
        logShare = LogShareItem(url: url)
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
        } header: {
            Text("服务端设置")
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
        guard let stamp = Bundle.main.object(forInfoDictionaryKey: "WandBuildStamp") as? String,
              !stamp.isEmpty else {
            return "v\(short)"
        }
        return "v\(short)+\(stamp)"
    }

    private func settingsStatePill(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 0.6))
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationStatus = "已开启"
        case .denied:
            notificationStatus = "已关闭"
        case .notDetermined:
            notificationStatus = "未请求"
        @unknown default:
            notificationStatus = "未知"
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent {
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        } label: {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

/// 包一层让 URL 可作为 `.sheet(item:)` 的标识。
struct LogShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// UIActivityViewController 的 SwiftUI 封装，用于系统分享面板（存文件 / AirDrop / 发送给开发者）。
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

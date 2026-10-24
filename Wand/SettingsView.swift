import SwiftUI
import UIKit
import UserNotifications

/// 与 Android 相同的设置目录；设备能力保留 iOS 原生实现。
enum MobileSettingsSection: String, CaseIterable, Identifiable {
    case server, appearance, traffic, notifications, updates, models, diagnostics, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .server: return "当前服务器"
        case .appearance: return "外观与反馈"
        case .traffic: return "流量与实时内容"
        case .notifications: return "通知与后台"
        case .updates: return "应用与更新"
        case .models: return "模型分组"
        case .diagnostics: return "诊断"
        case .about: return "关于 Wand"
        }
    }
    var symbol: String {
        switch self {
        case .server: return "server.rack"
        case .appearance: return "paintpalette"
        case .traffic: return "network"
        case .notifications: return "bell.badge"
        case .updates: return "arrow.triangle.2.circlepath"
        case .models: return "slider.horizontal.3"
        case .diagnostics: return "square.and.arrow.up"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    let serverURL: URL
    let token: String?

    @EnvironmentObject private var store: ServerStore
    @EnvironmentObject private var appUpdater: AppUpdateController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(WandAppearanceMode.storageKey) private var appearanceModeRaw = WandAppearanceMode.system.rawValue
    @AppStorage(WandFeedback.storageKey) private var hapticEnabled = true
    @AppStorage("wand.trafficTimelineMode") private var trafficTimelineMode = "wifi"

    @State private var serverVersion: String?
    @State private var confirmRemoveServer = false
    @State private var notificationStatus = "读取中…"
    @ObservedObject private var remoteNotifications = RemoteNotificationController.shared
    @ObservedObject private var liveActivityPush = LiveActivityPushController.shared
    @State private var logShare: LogShareItem?
    @State private var logExportEmpty = false
    @State private var showRenameServer = false
    @State private var serverNameDraft = ""
    private var iosUpdate: IosIpaUpdateInfo? { appUpdater.info }
    private var iosUpdateChecking: Bool { appUpdater.checking }
    private var iosUpdateError: String? { appUpdater.error }
    @State private var expandedSection: MobileSettingsSection?
    @State private var showWebSettings = false
    @State private var webSettingsSection: String? = nil
    @State private var showModelGroups = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    private var api: WandAPI { WandAPI(baseURL: serverURL, token: token) }

    var body: some View {
        NavigationStack {
            Form {
                settingsDirectory
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.brand)
        .wandPreferredAppearance()
        .task {
            serverVersion = (try? await api.serverConfig())?.currentVersion
            await refreshNotificationStatus()
            await appUpdater.check()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationStatus() }
        }
        .confirmationDialog("移除当前服务器？", isPresented: $confirmRemoveServer, titleVisibility: .visible) {
            Button("移除服务器", role: .destructive) {
                guard let id = store.activeServerID else { return }
                dismiss()
                store.removeProfile(id: id)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从这台设备移除该服务器及认证信息，重新连接需要连接码。服务端会话和文件保留。")
        }
        .sheet(isPresented: $showWebSettings) {
            SettingsWebView(api: api, section: webSettingsSection)
        }
        .sheet(isPresented: $showModelGroups) { ModelGroupsView(api: api) }
        .sheet(item: $logShare) { item in
            ActivityView(activityItems: [item.url])
        }
        .alert("最近 5 分钟没有日志", isPresented: $logExportEmpty) {
            Button("好", role: .cancel) {}
        } message: {
            Text("打开会话、收发消息或复现问题后再导出，才能捕获到有用的上下文。")
        }
        .alert("服务器名称", isPresented: $showRenameServer) {
            TextField("留空使用地址", text: $serverNameDraft)
            Button("保存") {
                if let id = store.activeServerID {
                    store.renameProfile(id: id, customName: serverNameDraft)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("名称只保存在这台设备上，不会修改服务器配置。")
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
                if showWebSettings { showWebSettings = false }
                else if expandedSection != nil { expandedSection = nil }
                else { dismiss() }
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

    private var settingsDirectory: some View {
        Group {
            Section {
                settingsChapter(.server, detail: store.activeProfile?.displayName ?? "当前服务器") {
                    serverSection
                }
            }
            Section("此设备") {
                settingsChapter(.appearance, detail: currentAppearance.title) { appearanceSection }
                settingsChapter(.traffic) { trafficSection }
                settingsChapter(.notifications) { featureSection }
                settingsChapter(.updates, detail: appVersion) { clientUpdateSection }
            }
            Section("服务配置") {
                Button { showModelGroups = true } label: {
                    Label(MobileSettingsSection.models.title, systemImage: MobileSettingsSection.models.symbol)
                        .frame(minHeight: WandLayout.controlTouch, alignment: .leading)
                }
                .accessibilityIdentifier("settings-models")
                Button { webSettingsSection = "connectors"; showWebSettings = true } label: {
                    Label("钉钉群聊接入", systemImage: "person.3")
                        .frame(minHeight: WandLayout.controlTouch, alignment: .leading)
                }
                .accessibilityIdentifier("settings-dingtalk")
                Button { webSettingsSection = nil; showWebSettings = true } label: {
                    Label("完整 Web 设置", systemImage: "globe")
                        .frame(minHeight: WandLayout.controlTouch, alignment: .leading)
                }
                .accessibilityIdentifier("settings-web")
            }
            Section("帮助与关于") {
                settingsChapter(.diagnostics) { diagnosticsSection }
                settingsChapter(.about) { aboutSection }
            }
        }
    }

    /// 目录与 Android 同序；短设置在触发点下方展开，避免又加一层页面或模态。
    private func settingsChapter<Content: View>(_ section: MobileSettingsSection, detail: String? = nil,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedSection == section },
            set: { open in
                withAnimation(reducedMotion ? nil : WandMotion.expansion) {
                    expandedSection = open ? section : nil
                }
            }
        )) {
            content()
        } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: WandLayout.fieldGap) {
                        Label(section.title, systemImage: section.symbol)
                        if let detail { Text(detail).font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        Label(section.title, systemImage: section.symbol)
                        if let detail {
                            Spacer(minLength: 8)
                            Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
                                .lineLimit(2).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .frame(minHeight: WandLayout.controlTouch, alignment: .leading)
        }
        .accessibilityIdentifier("settings-" + section.rawValue)
    }

    private var serverSection: some View {
        Group {
            if let profile = store.activeProfile {
                infoRow("名称", profile.displayName)
            }
            infoRow("地址", serverURL.absoluteString, mono: true)
            infoRow("认证方式", (token?.isEmpty == false) ? "连接码" : "无密码")
            infoRow("已保存", "\(store.profiles.count) 台")
            if let serverVersion {
                infoRow("服务端版本", "v\(serverVersion)", mono: true)
            }
            Button {
                serverNameDraft = store.activeProfile?.customName ?? ""
                showRenameServer = true
            } label: {
                Label("重命名当前服务器", systemImage: "pencil")
                    .font(.subheadline).frame(minHeight: WandLayout.controlTouch)
            }
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                }
            } label: {
                Label("管理服务器", systemImage: "server.rack")
                    .font(.wand(size: 15))
            }
            Button(role: .destructive) {
                confirmRemoveServer = true
            } label: {
                Label("移除当前服务器", systemImage: "trash")
                    .font(.wand(size: 15))
            }
        }
    }

    private var appearanceSection: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("主题", systemImage: currentAppearance.icon)
                        .font(.wand(size: 15))
                    Spacer()
                    Text(currentAppearance.title)
                        .font(.wand(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    appearancePicker.pickerStyle(.menu)
                } else {
                    appearancePicker.pickerStyle(.segmented).labelsHidden()
                }
            }
            .padding(.vertical, 6)
            Toggle("触感反馈", isOn: $hapticEnabled)
            Text("选择明亮、黑暗，或跟随 iOS 系统外观。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var trafficSection: some View {
        Group {
            Picker("实时工具时间线", selection: Binding(
                get: { activityTimelineDisplayOption(trafficTimelineMode) },
                set: { option in
                    trafficTimelineMode = activityTimelineMode(forOption: option, current: trafficTimelineMode)
                },
            )) {
                Text("仅 Wi-Fi").tag("wifi")
                Text("一直打开").tag("all")
                Text("一直折叠").tag("never")
            }
                .tint(Theme.brand)
            Text("选择工具时间线自动展开的网络范围，或一直折叠。历史详情始终可点击查看；在对话里手动收放不改变已选网络范围。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var appearancePicker: some View {
        Picker("主题", selection: $appearanceModeRaw) {
            ForEach(WandAppearanceMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
        }
    }

    private var currentAppearance: WandAppearanceMode {
        WandAppearanceMode.resolved(from: appearanceModeRaw)
    }

    private var featureSection: some View {
        Group {
            Toggle("回复完成 / 等待授权通知", isOn: $store.notificationsEnabled)
                .tint(Theme.brand)
                .onChange(of: store.notificationsEnabled) { _, enabled in
                    Task {
                        if enabled {
                            _ = await SessionNotificationController.shared
                                .requestAuthorizationAndWait()
                        } else {
                            SessionNotificationController.shared.clearPending()
                        }
                        await refreshNotificationStatus()
                    }
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
                        .foregroundStyle(notificationStatus == "已开启" ? Theme.success : Theme.danger)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .frame(minHeight: WandLayout.controlTouch)
            Button {
                SessionNotificationController.shared.sendTestNotification()
            } label: {
                Label("发送测试通知", systemImage: "bell.and.waves.left.and.right")
            }
            .disabled(notificationStatus != "已开启")
            Text(liveActivityPush.status)
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Text(remoteNotifications.status)
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Text("启用 APNs 后，App 被挂起仍可收到回复完成或等待授权提醒。服务器或安装包未启用推送时使用本地通知，挂起后暂停。灵动岛先在前台创建，已注册的活动可由服务器远程更新与结束。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var diagnosticsSection: some View {
        Group {
            Button {
                exportLogs()
            } label: {
                Label("导出最近 5 分钟日志", systemImage: "square.and.arrow.up.on.square")
                    .font(.wand(size: 15))
            }
            Text("复现问题后导出最近 5 分钟日志，通过系统分享或存储到文件。日志只存在本机内存，不含密码。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var clientUpdateSection: some View {
        Group {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.success.opacity(0.13)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(iosUpdateTitle)
                        .font(.wand(size: 14, weight: .semibold))
                    Text(iosUpdateSubtitle)
                        .font(.wand(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                if iosUpdateChecking {
                    ProgressView()
                }
            }
            .padding(.vertical, 4)
            if appUpdater.installURL != nil {
                Button { appUpdater.install() } label: {
                    ZStack {
                        Label("安装更新", systemImage: "arrow.down.app")
                            .opacity(appUpdater.opening ? 0 : 1)
                        if appUpdater.opening { ProgressView() }
                    }
                    .font(.wand(size: 15))
                    .frame(minHeight: 44)
                }
                .disabled(appUpdater.opening)
            }
            if appUpdater.handoffMessage != nil, appUpdater.installPageURL != nil {
                Button("打开安装页") { appUpdater.openInstallPage() }
                    .disabled(appUpdater.opening)
            }
            Button {
                Task { await checkIosUpdate() }
            } label: {
                Label("检查更新", systemImage: "arrow.clockwise")
                    .font(.wand(size: 15))
            }
            .disabled(iosUpdateChecking || appUpdater.opening)
            Text(iosUpdateFooter).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private var iosUpdateTitle: String {
        if iosUpdateChecking { return "正在检查更新" }
        if let latest = iosUpdate?.latestVersion, iosUpdate?.updateAvailable == true {
            return "发现新版本 v\(latest)"
        }
        if iosUpdateError != nil { return "检查更新失败" }
        if iosUpdate != nil { return "已是最新版本" }
        return "检查客户端更新"
    }

    private var iosUpdateSubtitle: String {
        if let error = iosUpdateError { return error }
        return appUpdater.handoffMessage ?? "当前 \(appVersion)"
    }

    private var iosUpdateFooter: String {
        if iosUpdate?.updateAvailable == true, iosUpdate?.otaReadyValue != true {
            return "已检测到新包，但还不能直接安装。请使用 HTTPS 连接，并由服务端提供已签名的安装包。"
        }
        return "连接成功、回到前台及前台使用期间会自动检查更新。发现可安装版本后，点“安装更新”会直接打开安装页，在页面确认即开始安装，无需连接电脑。"
    }

    private func checkIosUpdate() async {
        await appUpdater.check(manual: true)
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

    private var aboutSection: some View {
        Group {
            infoRow("App 版本", appVersion, mono: true)
            if let serverVersion { infoRow("服务端版本", "v\(serverVersion)", mono: true) }
            Link(destination: URL(string: "https://github.com/co0ontty/wand")!) {
                Label("GitHub 仓库", systemImage: "link")
                    .font(.wand(size: 15))
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
                .font(.wand(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
        } label: {
            Text(label)
                .font(.wand(size: 14))
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

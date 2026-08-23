import SwiftUI

/// 连接界面：输入服务器地址（host:port，自动判别 http/https）或 wand 设置页生成的"连接码"。
/// 解析与可达性探测统一收敛到 `WandAuth.resolve`，错误就地内联展示。
/// 对称 macOS 的 ConnectView，去掉了 macOS-only 的窗口尺寸约束，sheet 用 iOS 风格。
struct ConnectView: View {
    @EnvironmentObject var store: ServerStore

    var isPresentedAsSheet: Bool = false
    var onDismiss: (() -> Void)? = nil

    @State private var input: String = ""
    @State private var error: String? = nil
    @State private var isConnecting = false
    @State private var connectingProfileID: String?
    @State private var connectionGeneration = 0
    @State private var connectionAttempt: WandAuth.ConnectionAttempt?
    @State private var showScanner = false
    @State private var showLocalNetworkHint = false
    @State private var pendingRemoval: ServerProfile?
    @State private var confirmRemoveAll = false
    @FocusState private var inputFocused: Bool

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            WandAmbientBackground()

            VStack(spacing: 0) {
                if isPresentedAsSheet {
                    sheetHeader
                }
                ScrollView {
                    VStack {
                        Spacer(minLength: 24)
                        card
                            .frame(maxWidth: 440)
                            .padding(22)
                            .wandGlassCard(cornerRadius: 22)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 24)
                        Spacer(minLength: 24)
                    }
                    .frame(maxWidth: .infinity)
                }
                .interactiveKeyboardDismiss()
                .dismissKeyboardOnTap()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard store.profiles.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { inputFocused = true }
        }
        .onDisappear { invalidateConnectionAttempt() }
        .interactiveDismissDisabled(isPresentedAsSheet && isConnecting)
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in
                input = code
                error = nil
                connect()
            }
        }
        .confirmationDialog(
            "移除这台服务器？",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let profile = pendingRemoval {
                Button("移除 \(profile.displayName)", role: .destructive) {
                    store.removeProfile(id: profile.id)
                    pendingRemoval = nil
                }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("只会移除这台服务器保存的地址和认证信息，不会影响服务器上的会话。")
        }
        .confirmationDialog("移除所有已保存服务器？", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("全部移除", role: .destructive) {
                store.removeAllProfiles()
                onDismiss?()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有端点的本地认证信息都会被清除，此操作不会删除服务器数据。")
        }
        .wandKeyboardShortcuts(connectKeyboardShortcuts)
    }

    private var connectKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "connect",
                title: "连接",
                key: .return,
                modifiers: .command,
                isEnabled: !trimmedInput.isEmpty && !isConnecting
            ) {
                connect()
            },
            WandKeyboardShortcutAction(
                id: "scan-qr",
                title: "扫码连接",
                key: "q",
                modifiers: [.command, .shift],
                isEnabled: !isConnecting
            ) {
                inputFocused = false
                showScanner = true
            },
            WandKeyboardShortcutAction(
                id: "dismiss-connect",
                title: "取消",
                key: .escape,
                modifiers: [],
                isEnabled: inputFocused || isPresentedAsSheet
            ) {
                if inputFocused {
                    inputFocused = false
                } else {
                    cancelAndDismiss()
                }
            },
        ]
    }

    // MARK: - 区块

    private var sheetHeader: some View {
        HStack {
            Text("切换服务器")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
            Button("取消") { cancelAndDismiss() }
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .wandGlassSurface()
    }

    private var card: some View {
        VStack(spacing: 22) {
            VStack(spacing: 14) {
                WandBrandMark(size: 64)
                VStack(spacing: 6) {
                    Text("连接到 Wand")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    Text("粘贴设置页的连接码，或直接输入服务器地址")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }

            inputField

            if let error {
                errorBanner(error)
            }

            if showLocalNetworkHint {
                localNetworkHint
            }

            connectButton

            if !store.profiles.isEmpty {
                savedServersSection
            }

            footerHint
        }
    }

    private var inputField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("连接码 / 服务器地址")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textSecondary)
                TextField("例如 192.168.1.10:7777 或粘贴连接码", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .focused($inputFocused)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.go)
                    .onSubmit { connect() }
                    .disabled(isConnecting)
                if !input.isEmpty {
                    Button { input = ""; error = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .disabled(isConnecting)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .wandInputSurface(focused: inputFocused, invalid: error != nil, cornerRadius: 12)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(Theme.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.danger.opacity(0.1))
        )
    }

    private var localNetworkHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("请检查「本地网络」权限", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("Wand 需要本地网络权限才能连接局域网内的服务。请在系统设置中允许 Wand 访问本地网络，然后重试。")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开 Wand 设置") {
                LocalNetworkPermission.openSettings()
            }
            .font(.system(size: 13, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.brand.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.brand.opacity(0.35), lineWidth: 1)
        )
    }

    private var connectButton: some View {
        HStack(spacing: 10) {
            Button(action: connect) {
                HStack(spacing: 8) {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text(isConnecting ? "连接中…" : "连接")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(WandPrimaryButtonStyle())
            .disabled(isConnecting || trimmedInput.isEmpty)

            Button {
                inputFocused = false
                showScanner = true
            } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Theme.brand)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
            .disabled(isConnecting)
            .accessibilityLabel("扫码连接")
        }
    }

    private var savedServersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已保存的服务器")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("每台服务器的认证信息独立保存。")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            VStack(spacing: 6) {
                ForEach(store.profiles) { profile in
                    savedServerRow(profile)
                }
            }
            Button("移除所有服务器", role: .destructive) {
                confirmRemoveAll = true
            }
            .font(.system(size: 13, weight: .medium))
            .disabled(isConnecting)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func savedServerRow(_ profile: ServerProfile) -> some View {
        let active = profile.id == store.activeServerID
        let connecting = profile.id == connectingProfileID
        return HStack(spacing: 9) {
            Button {
                connect(to: profile)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13))
                        .foregroundColor(active ? Theme.brand : Theme.textSecondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(profile.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(active ? Theme.brand : Theme.textPrimary)
                                .lineLimit(1)
                            if active {
                                Text("当前")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Theme.brand)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.brand.opacity(0.12)))
                            }
                        }
                        HStack(spacing: 6) {
                            Text(safeDisplayURL(profile.baseURL))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(profile.hasToken ? "已认证" : "直接连接")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(profile.hasToken ? Theme.success : Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if connecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.brand)
                            .padding(8)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
            .accessibilityLabel(
                "连接服务器 \(profile.displayName)，\(profile.hasToken ? "已认证" : "直接连接")\(active ? "，当前服务器" : "")"
            )

            if !connecting {
                Button {
                    pendingRemoval = profile
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .padding(8)
                }
                .disabled(isConnecting)
                .accessibilityLabel("移除服务器 \(profile.displayName)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func safeDisplayURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? "无效服务器地址"
    }

    private var footerHint: some View {
        Text("在电脑端 Wand 的「设置 → 连接 App」里获取连接码")
            .font(.system(size: 12))
            .foregroundColor(Theme.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
    }

    // MARK: - 逻辑

    private func connect() {
        let raw = trimmedInput
        guard !raw.isEmpty, !isConnecting else { return }
        connectionAttempt?.cancel()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        isConnecting = true
        connectingProfileID = nil
        error = nil
        showLocalNetworkHint = false
        inputFocused = false

        connectionAttempt = WandAuth.resolve(rawInput: raw) { result in
            DispatchQueue.main.async {
                guard generation == connectionGeneration else { return }
                connectionAttempt = nil
                isConnecting = false
                switch result {
                case .success(let target):
                    store.connect(serverURL: target.url, token: target.token)
                    onDismiss?()
                case .failure(let err):
                    error = err.userMessage
                    if case .network = err {
                        let host = WandAuth.decodeConnectCode(raw)?.url.host
                            ?? WandAuth.candidateURLs(from: raw).first?.host
                        showLocalNetworkHint = LocalNetworkPermission.isLikelyLanHost(host)
                    }
                }
            }
        }
    }

    private func connect(to profile: ServerProfile) {
        guard !isConnecting else { return }
        connectionAttempt?.cancel()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        isConnecting = true
        connectingProfileID = profile.id
        error = nil
        showLocalNetworkHint = false
        let expectedConnectionIdentity = profile.connectionIdentity
        let targetEndpointSession = SelfSignedSession.forEndpoint(profile.baseURL)

        let finish: (Result<Void, WandAuth.Failure>) -> Void = { result in
            DispatchQueue.main.async {
                guard generation == connectionGeneration else { return }
                connectionAttempt = nil
                isConnecting = false
                connectingProfileID = nil
                switch result {
                case .success:
                    guard let current = store.profile(id: profile.id),
                          current.connectionIdentity == expectedConnectionIdentity,
                          store.activateProfile(id: profile.id) else {
                        error = "服务器信息已变化，请按最新列表重试。"
                        return
                    }
                    onDismiss?()
                case .failure(let failure):
                    error = failure.userMessage
                    if case .network = failure {
                        showLocalNetworkHint = LocalNetworkPermission.isLikelyLanHost(profile.baseURL.host)
                    }
                }
            }
        }

        if let token = profile.token, !token.isEmpty {
            connectionAttempt = WandAuth.authenticate(
                serverURL: profile.baseURL,
                appToken: token,
                targetEndpointSession: targetEndpointSession,
                completion: finish
            )
        } else {
            connectionAttempt = WandAuth.probeConnection(url: profile.baseURL) { reachable in
                finish(reachable ? .success(()) : .failure(.network(
                    "无法连接到已保存的服务器"
                )))
            }
        }
    }

    private func cancelAndDismiss() {
        invalidateConnectionAttempt()
        onDismiss?()
    }

    private func invalidateConnectionAttempt() {
        connectionGeneration &+= 1
        connectionAttempt?.cancel()
        connectionAttempt = nil
        isConnecting = false
        connectingProfileID = nil
    }
}

private extension View {
    /// 浏览进行中交互式收起键盘。
    func interactiveKeyboardDismiss() -> some View {
        self.scrollDismissesKeyboard(.interactively)
    }
}

import SwiftUI

func quickActionRequiresRootSessionRouting(
    _ action: QuickAction,
    rootIsSessions: Bool,
    hasPresentedSurface: Bool
) -> Bool {
    switch action {
    case .newSession, .openSession:
        return !rootIsSessions || hasPresentedSurface
    case .showSessions:
        return true
    }
}

func sessionListQuickActionsEnabled(
    rootIsSessions: Bool,
    hasPresentedSurface: Bool
) -> Bool {
    rootIsSessions && !hasPresentedSurface
}

/// Same four root modes as Android; preserve explicit old sessions/board preferences.
enum HomeListMode: String, Equatable {
    case im, contacts, sessions, board

    static let storageKey = "wand.homeListMode"

    var label: String {
        switch self { case .im: return "聊天"; case .contacts: return "通讯录"; case .sessions: return "工作区"; case .board: return "任务" }
    }

    var next: HomeListMode { self == .board ? .sessions : .board }

    static func fromStorage(_ value: String?) -> HomeListMode {
        HomeListMode(rawValue: value ?? "") ?? .im
    }
}

/// 原生客户端根视图：先用 appToken 登录，然后进入原生会话列表。
struct NativeRootView: View {
    let profile: ServerProfile
    @State private var endpointAPI: WandAPI
    @StateObject private var appUpdater: AppUpdateController

    @EnvironmentObject private var store: ServerStore
    @State private var phase: Phase = .authenticating
    @State private var showSettings = false
    @State private var showMissions = false
    @AppStorage(HomeListMode.storageKey) private var homeListModeRaw = HomeListMode.im.rawValue
    @State private var isSelectingHome = false
    @State private var serverUpdate: ServerUpdateInfo?
    @State private var dismissedUpdateVersion: String?
    @State private var updateBannerMessage: String?
    @State private var updateError: String?
    @State private var installingUpdate = false
    @State private var canManageSettings = false
    @State private var systemSocket: WandSocket?
    @State private var lifecycleGeneration = 0
    @State private var authenticationTask: Task<Void, Never>?
    @State private var authenticationAttempt: WandAuth.ConnectionAttempt?
    @State private var authenticationRetryTask: Task<Void, Never>?
    @State private var authenticationRetryAttempt = 0
    @State private var updateRefreshTask: Task<Void, Never>?
    @State private var updateInstallTask: Task<Void, Never>?
#if DEBUG
    @State private var didApplyDebugSettingsLaunch = false
#endif
    @ObservedObject private var quickActions = QuickActionCoordinator.shared
    /// 当前选中的会话身份 + 完整快照：由 SessionListView 写入，驱动 SplitView detail 栏
    /// / NavigationStack push。提升到根视图是因为 detail 内容由根容器直接承载，
    /// 不再走隐藏 NavigationLink（在 .columns 双栏下不可靠）。
    @State private var selectedSessionID: String?
    /// 「用户明确打开了这个会话」。只有带 intent 的那次打开才允许确认完成代次：
    /// 自动选中最近会话、后台刷新、重连、切任务都不算（对齐 Web completionViewIntent / macOS）。
    @State private var completionViewIntentSessionId: String?
    @State private var acknowledgedCompletionRevision: Int?
    @State private var selectedSnapshot: SessionSnapshot?
    /// iPhone push 动画期间的会话身份。列表只允许这一次打开落入状态机，避免双击/连点
    /// 把 navigationDestination(isPresented:) 推进半截时再次改写 selection。
    @State private var openingSessionID: String?
    @State private var selectedWorkspaceTask: WorkspaceTaskSelection?
    @State private var presentNewConversation = false
    @State private var newConversationSession: SessionSnapshot?
    @State private var pendingNewConversationCwd = ""
    @State private var pendingNewConversationWorkspaceID: String?
    @State private var pendingNewConversationTaskID: String?
    @State private var initialNewConversationEmployeeID: String?
    @StateObject private var workspaceStore: WorkspaceStore
    @StateObject private var contactsStore: ContactsStore
    @StateObject private var conversations: ConversationStore
    @State private var selectedConversationID: String?
    @State private var selectedContactEmployeeID: String?
    @State private var showingContacts = false
    @State private var selectedContactRunID: String?
    @State private var homeEmployees: [SiliconEmployee] = []
    @State private var homeTeams: [ContactTeam] = []
    @State private var homeContactsGeneration = 0
    @State private var homeModalVisible = false
    @State private var homeMutationBusy = false
    @State private var visibleCompletionSnapshot: SessionSnapshot?
    @State private var selectedTaskSessionId: String?
    @State private var selectedTaskShowsPicker = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    init(profile: ServerProfile) {
        self.profile = profile
        let endpointAPI = WandAPI(baseURL: profile.baseURL, token: profile.token)
        _endpointAPI = State(initialValue: endpointAPI)
        _appUpdater = StateObject(wrappedValue: AppUpdateController(
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            bundleID: Bundle.main.bundleIdentifier ?? "",
            fetch: { try await endpointAPI.iosIpaUpdate(currentVersion: $0) },
            report: { endpointAPI.reportClientFeedback(event: "update_failed", feature: "app_update", error: $0) }
        ))
        _contactsStore = StateObject(wrappedValue: ContactsStore(service: endpointAPI))
        _conversations = StateObject(wrappedValue: ConversationStore(api: endpointAPI))
        _workspaceStore = StateObject(wrappedValue: WorkspaceStore(
            api: endpointAPI,
            serverID: profile.id
        ))
    }

    private enum Phase: Equatable {
        case authenticating
        case ready
        case failed(String)
    }

    private var serverURL: URL { profile.baseURL }
    private var token: String? { profile.token }
    private var serverID: String { profile.id }

    private var api: WandAPI {
        endpointAPI
    }

    private var homeListMode: HomeListMode {
        HomeListMode.fromStorage(homeListModeRaw)
    }

    private var showingBoard: Bool { homeListMode == .board }

    var body: some View {
        AdaptiveNavigationContainer(
            selection: navigationSelection,
            parents: contactNavigationParents,
            sidebar: { sidebarContent },
            detail: { marker in contactDestination(marker) }
        )
        .safeAreaInset(edge: .top, spacing: 0) { AppUpdateBanner(updater: appUpdater) }
        .animation(WandMotion.disclosure, value: appUpdater.promptVersion)
        .fullScreenCover(isPresented: $showMissions) {
            MissionsView(
                api: api,
                linkedTaskId: selectedWorkspaceTask?.task.id,
                linkedTaskName: selectedWorkspaceTask?.task.name,
                linkedTaskCwd: workspaceStore.taskState.detail?.cwd ?? selectedWorkspaceTask?.workspace.cwd,
                onOpenSession: openSessionFromMissions
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(serverURL: serverURL, token: token)
                .environmentObject(store)
                .environmentObject(appUpdater)
        }
        .sheet(isPresented: $presentNewConversation, onDismiss: {
            if let snapshot = newConversationSession {
                newConversationSession = nil
                openCreatedConversation(snapshot)
            }
        }) {
            NewConversationView(
                api: api,
                serverID: profile.connectionIdentity,
                initialCwd: pendingNewConversationCwd,
                workspaceID: pendingNewConversationWorkspaceID,
                initialWorkspaceTaskID: pendingNewConversationTaskID,
                initialEmployeeID: initialNewConversationEmployeeID
            ) { snapshot in
                newConversationSession = snapshot
                presentNewConversation = false
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(get: { selectedContactEmployeeID != nil }, set: { if !$0 { selectedContactEmployeeID = nil } })) {
            if let employeeID = selectedContactEmployeeID {
                NavigationStack {
                    ScrollView {
                        EmployeeProfilePanel(id: employeeID, api: api, directory: contactsStore) { selectedContactEmployeeID = nil }
                            .padding(16)
                    }
                }.interactiveDismissDisabled(contactsStore.editorBusy || contactsStore.editorDirty)
            }
        }
        .onAppear { authenticate() }
        .onChange(of: scenePhase) { _, value in
            appUpdater.setActive(value == .active && phase == .ready)
        }
        .onChange(of: workspaceStore.taskGroups) { _, groups in
            syncSelectedWorkspaceTaskMetadata(groups)
        }
        .onDisappear { invalidateLifecycle() }
        // 登录完成前挂起会话快捷操作，ready 后再处理。
        .onChange(of: quickActions.pending) { _, _ in
            handleQuickAction()
        }
        .onChange(of: phase) { _, _ in
#if DEBUG
            handleDebugSettingsLaunch()
#endif
            handleQuickAction()
        }
        // NavigationStack 的系统返回手势只会把 selection 置空；同步释放详情快照，确保
        // 下次进入（包括同一会话）创建干净的 destination，而不是复用已 shutdown 的页面。
        .onChange(of: selectedSessionID) { _, sessionID in
            guard let sessionID else {
                selectedSnapshot = nil
                openingSessionID = nil
                if selectedWorkspaceTask == nil && selectedContactRunID == nil {
                    selectedTaskSessionId = nil
                    selectedTaskShowsPicker = false
                    clearCompletionIntent()
                }
                return
            }
            releaseSessionOpenGateAfterTransition(for: sessionID)
        }
        .task {
            workspaceStore.startTaskGroupsSync()
            if case .idle = workspaceStore.indexState {
                await workspaceStore.loadWorkspaceIndex()
            }
        }
        .onDisappear {
            workspaceStore.stopTaskGroupsSync()
        }
        .onChange(of: rootModalVisible) { _, visible in
            if !visible, let snapshot = visibleCompletionSnapshot { acknowledgeCompletionIfViewed(snapshot) }
        }
        .wandKeyboardShortcuts(rootKeyboardShortcuts)
    }

    private var navigationSelection: Binding<String?> {
        Binding(
            get: { selectedWorkspaceTask?.task.id ?? selectedSessionID ?? selectedConversationID.map { "wand:conversation:" + $0 } },
            set: { value in
                guard !homeMutationBusy else { return }
                if let value, value.hasPrefix("wand:conversation:") {
                    selectedConversationID = String(value.dropFirst("wand:conversation:".count))
                } else if value != nil { return }
                else if selectedSessionID == nil { selectedConversationID = nil; conversations.select(nil) }
                selectedWorkspaceTask = nil
                selectedSessionID = nil
                selectedSnapshot = nil
                openingSessionID = nil
                selectedTaskSessionId = nil
                selectedTaskShowsPicker = false
                clearCompletionIntent()
            }
        )
    }

    private var contactNavigationParents: Binding<[String]> {
        Binding(
            get: {
                (showingContacts ? ["wand:contacts"] : []) + (selectedContactRunID.map { ["wand:team-run:" + $0] } ?? [])
                    + (selectedSessionID != nil ? selectedConversationID.map { ["wand:conversation:" + $0] } ?? [] : [])
            },
            set: { markers in
                guard !contactsStore.busy, !homeMutationBusy else { return }
                showingContacts = markers.contains("wand:contacts")
                if let conversation = markers.first(where: { $0.hasPrefix("wand:conversation:") }) {
                    selectedConversationID = String(conversation.dropFirst("wand:conversation:".count))
                }
                let runID = markers.first(where: { $0.hasPrefix("wand:team-run:") })
                    .map { String($0.dropFirst("wand:team-run:".count)) }
                if selectedContactRunID != runID { clearCompletionIntent() }
                selectedContactRunID = runID
            }
        )
    }

    @ViewBuilder private func contactDestination(_ marker: String?) -> some View {
        if let marker, marker.hasPrefix("wand:conversation:") {
            ConversationDetailView(id: String(marker.dropFirst("wand:conversation:".count)), store: conversations,
                onOpenSession: openWorkspaceStandaloneSession, onOpenConversation: openConversation,
                onEmployee: { selectedContactEmployeeID = $0 })
                .id(marker)
        } else if marker == "wand:contacts" {
            ContactsView(api: api, store: contactsStore, onBack: {
                guard !contactsStore.busy else { return }
                showingContacts = false; selectedContactRunID = nil
            }, onOpenSession: { snapshot in
                selectedWorkspaceTask = nil; selectedContactRunID = nil
                openCompletionIntent(snapshot.id)
                selectedSessionID = snapshot.id; selectedSnapshot = snapshot
            }, onOpenRun: openTeamRun)
        } else if let marker, marker.hasPrefix("wand:team-run:") {
            ContactRunView(runId: String(marker.dropFirst("wand:team-run:".count)), api: api,
                onOpenSession: openSessionFromMissions, onCompletionVisible: { snapshot in
                    guard selectedContactRunID == String(marker.dropFirst("wand:team-run:".count)),
                          selectedSessionID == nil, selectedWorkspaceTask == nil else { return }
                    if completionViewIntentSessionId != snapshot.id { openCompletionIntent(snapshot.id) }
                    acknowledgeCompletionIfViewed(snapshot)
                })
                .id(marker)
        } else {
            // Each destination owns its chrome: chat uses floating controls, PTY/workspace use the system bar.
            detailContent
        }
    }

    private var rootKeyboardShortcuts: [WandKeyboardShortcutAction] {
        guard phase == .ready, !homeMutationBusy else { return [] }
        return [
            WandKeyboardShortcutAction(
                id: "new-task",
                title: "新建对话",
                key: "n",
                modifiers: .command
            ) {
                pendingNewConversationCwd = ""
                pendingNewConversationWorkspaceID = nil
                pendingNewConversationTaskID = nil
                initialNewConversationEmployeeID = nil
                presentNewConversation = true
            },
            WandKeyboardShortcutAction(
                id: "show-settings",
                title: "设置",
                key: ",",
                modifiers: .command,
                isEnabled: !showSettings
            ) {
                showSettings = true
            },
            WandKeyboardShortcutAction(
                id: "show-tasks",
                title: "显示任务列表",
                key: "1",
                modifiers: .command,
                isEnabled: selectedSessionID != nil || selectedWorkspaceTask != nil || showingBoard
            ) {
                showSettings = false
                showMissions = false
                setHomeListMode(.sessions)
                selectedWorkspaceTask = nil
                selectedSessionID = nil
                selectedSnapshot = nil
            },
            WandKeyboardShortcutAction(
                id: "show-missions",
                title: "显示并行任务",
                key: "2",
                modifiers: .command,
                isEnabled: !showMissions
            ) {
                showSettings = false
                showMissions = true
            },
            WandKeyboardShortcutAction(
                id: "show-task-board",
                title: "显示任务管理",
                key: "3",
                modifiers: .command,
                isEnabled: !showingBoard
            ) {
                showSettings = false
                showMissions = false
                setHomeListMode(.board)
            },
            WandKeyboardShortcutAction(
                id: "close-active-surface",
                title: "关闭当前页",
                key: "w",
                modifiers: .command,
                isEnabled: selectedSessionID != nil || selectedWorkspaceTask != nil || showSettings || showMissions
            ) {
                closeActiveSurfaceFromKeyboard()
            },
        ]
    }

    private func setHomeListMode(_ mode: HomeListMode) {
        guard !contactsStore.busy, !homeMutationBusy else { return }
        showingContacts = false; selectedContactRunID = nil
        selectedWorkspaceTask = nil; selectedSessionID = nil; selectedSnapshot = nil
        selectedConversationID = nil; conversations.select(nil)
        homeListModeRaw = mode.rawValue
        isSelectingHome = false
    }

    private func closeActiveSurfaceFromKeyboard() {
        guard !contactsStore.busy, !homeMutationBusy else { return }
        if showMissions {
            showMissions = false
        } else if showSettings {
            showSettings = false
        } else if selectedSessionID != nil {
            selectedSessionID = nil
            selectedSnapshot = nil
        } else if selectedWorkspaceTask != nil {
            selectedWorkspaceTask = nil
        } else if selectedContactRunID != nil {
            selectedContactRunID = nil
        } else if showingContacts {
            showingContacts = false
        }
    }

    /// 侧边栏：登录/失败/就绪三种阶段共用同一栏。ready 时承载会话列表及其 toolbar。
    @ViewBuilder private var sidebarContent: some View {
        ZStack {
            WandAmbientBackground()
            switch phase {
            case .authenticating:
                VStack(spacing: 16) {
                    WandBrandMark(size: 52)
                    ProgressView().tint(Theme.brand)
                    Text("正在登录…")
                        .font(.wand(size: 14))
                        .foregroundColor(Theme.textSecondary)
                    Button(action: switchServerBeforeAuthentication) {
                        Label("切换服务器", systemImage: "server.rack")
                    }
                    .buttonStyle(WandSecondaryButtonStyle())
                    .accessibilityIdentifier("login-switch-server")
                }
                .padding(24)
                .navigationTitle("Wand")
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "lock.slash")
                        .font(.system(size: 30))
                        .foregroundColor(Theme.danger)
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button { authenticate() } label: {
                        Text("重试").frame(maxWidth: .infinity)
                    }
                        .buttonStyle(WandPrimaryButtonStyle())
                    if LocalNetworkPermission.isLikelyLanHost(serverURL.host) {
                        Button {
                            LocalNetworkPermission.openSettings()
                        } label: {
                            Text("打开 Wand 设置").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(WandSecondaryButtonStyle())
                    }
                    Button(action: switchServerBeforeAuthentication) {
                        Text("切换服务器").frame(maxWidth: .infinity)
                    }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
                .frame(maxWidth: 420)
                .padding(24)
                .wandGlassCard(cornerRadius: 18)
                .padding(16)
                .navigationTitle("Wand")
            case .ready:
                VStack(spacing: 0) {
                    if shouldShowUpdateBanner {
                        updateBanner
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                    }
                    if homeListMode == .sessions || showingBoard {
                    HomeOverviewBar(
                        serverDisplayName: profile.displayName,
                        showNewTask: !showingBoard,
                        onNewTask: {
                            pendingNewConversationCwd = ""
                            pendingNewConversationWorkspaceID = nil
                            pendingNewConversationTaskID = nil
                            initialNewConversationEmployeeID = nil
                            presentNewConversation = true
                        },
                        onOpenSettings: { showSettings = true },
                        onSwitchServer: {
                            NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil)
                        }
                    )
                    .disabled(homeMutationBusy)
                    }
                    if homeListMode == .im {
                        ConversationListView(store: conversations, onSelect: openConversation,
                            onEmployee: { selectedContactEmployeeID = $0 }, onSettings: { showSettings = true },
                            onSwitchServer: { NotificationCenter.default.post(name: .wandRequestSwitchServer, object: nil) })
                            .transition(.opacity)
                    } else if homeListMode == .contacts {
                        ContactsView(api: api, store: contactsStore, onBack: { setHomeListMode(.im) },
                            onOpenSession: { snapshot in openWorkspaceStandaloneSession(snapshot.id) }, onOpenRun: openTeamRun,
                            onNewConversation: { employeeID in
                                pendingNewConversationCwd = ""
                                pendingNewConversationWorkspaceID = nil
                                pendingNewConversationTaskID = nil
                                initialNewConversationEmployeeID = employeeID
                                presentNewConversation = true
                            },
                            onOpenConversation: openConversation, onTeamConversation: openPresetConversation, embedded: true)
                            .transition(.opacity)
                    } else if showingBoard {
                        TaskBoardView(
                            api: api,
                            workspaceStore: workspaceStore,
                            creationServerID: profile.connectionIdentity,
                            onOpenSession: openSessionFromMissions,
                            onOpenBoundSession: openBoardBoundSession,
                            onOpenTeamRun: openTeamRun,
                            embedded: true
                        )
                    } else {
                        WorkspaceListView(
                            store: workspaceStore,
                            api: api,
                            creationServerID: profile.connectionIdentity,
                            serverDisplayName: profile.displayName,
                            selectedTaskId: selectedWorkspaceTask?.task.id,
                            selectedSessionId: selectedSessionID,
                            hidesHomeChrome: true,
                            isSelecting: $isSelectingHome,
                            onOpenTask: { workspace, task in
                                clearCompletionIntent()
                                selectedTaskSessionId = nil
                                selectedTaskShowsPicker = false
                                selectedSessionID = nil
                                selectedSnapshot = nil
                                openingSessionID = nil
                                selectedWorkspaceTask = WorkspaceTaskSelection(
                                    workspace: workspace,
                                    task: task
                                )
                            },
                            onTaskRenamed: { updated in
                                if var selection = selectedWorkspaceTask, selection.task.id == updated.id {
                                    selection = WorkspaceTaskSelection(workspace: selection.workspace, task: updated)
                                    selectedWorkspaceTask = selection
                                }
                            },
                            onTaskDeleted: { taskId in
                                if selectedWorkspaceTask?.task.id == taskId {
                                    selectedWorkspaceTask = nil
                                }
                            },
                            onTaskArchived: { taskId in
                                // 归档是软删除：侧栏入口消失，详情也跟着收起（对齐 web 的 closeWorkspace）。
                                if selectedWorkspaceTask?.task.id == taskId {
                                    selectedWorkspaceTask = nil
                                }
                            },
                            onOpenSession: { _, session in
                                if let chat = session.teamChat { openTeamRun(chat.runId) }
                                else { openWorkspaceStandaloneSession(session.id) }
                            },
                            onOpenTaskSession: { workspace, task, session in
                                if let chat = session.teamChat { openTeamRun(chat.runId); return }
                                selectedSessionID = nil
                                selectedSnapshot = nil
                                selectedTaskSessionId = session.id
                                selectedTaskShowsPicker = false
                                openCompletionIntent(session.id)
                                selectedWorkspaceTask = WorkspaceTaskSelection(
                                    workspace: workspace,
                                    task: task
                                )
                            },
                            onRequestNewSession: { workspace, task in
                                pendingNewConversationCwd = task.worktree?.path ?? workspace.cwd
                                pendingNewConversationWorkspaceID = workspace.id
                                pendingNewConversationTaskID = task.id
                                initialNewConversationEmployeeID = nil
                                presentNewConversation = true
                                clearCompletionIntent()
                                selectedSessionID = nil
                                selectedSnapshot = nil
                                selectedTaskSessionId = nil
                                selectedTaskShowsPicker = false
                                selectedWorkspaceTask = WorkspaceTaskSelection(
                                    workspace: workspace,
                                    task: task
                                )
                            },
                            onOpenParallel: { workspace, task in
                                selectedWorkspaceTask = WorkspaceTaskSelection(
                                    workspace: workspace,
                                    task: task
                                )
                                showMissions = true
                            },
                            onMergeAgentStarted: { _, started in
                                presentMergeAgentSession(started)
                            },
                            onWorkspaceDeleted: { workspaceId in
                                if selectedWorkspaceTask?.workspace.id == workspaceId {
                                    selectedWorkspaceTask = nil
                                }
                            },
                            employees: homeEmployees,
                            teams: homeTeams,
                            onOpenTeamRun: { runId in
                                openTeamRun(runId)
                            },
                            onModalVisibilityChanged: { homeModalVisible = $0 },
                            onMutationBusyChanged: { homeMutationBusy = $0 }
                        )
                    }
                }
                .animation(reducedMotion ? nil : WandMotion.stateSwap, value: homeListMode)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer(minLength: 8)
                        HomeMenuPill(mode: homeListMode, onMode: setHomeListMode) {
                            guard !contactsStore.busy, !homeMutationBusy else { return }
                            selectedWorkspaceTask = nil; selectedSessionID = nil; selectedSnapshot = nil
                            selectedContactRunID = nil; setHomeListMode(.contacts)
                        }
                        .disabled(homeMutationBusy)
                        Spacer(minLength: 8)
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    /// 详情：任务工作窗口优先；未分组会话 / 合并 Agent 仍可直接打开。
    @ViewBuilder private var detailContent: some View {
        if let selection = selectedWorkspaceTask {
            WorkspaceTaskView(
                workspace: selection.workspace,
                task: selection.task,
                api: api,
                store: workspaceStore,
                initialSessionId: selectedTaskSessionId,
                initialShowPicker: selectedTaskShowsPicker,
                onExplicitOpen: openCompletionIntent,
                onCompletionVisible: acknowledgeCompletionIfViewed,
                onOpenTeamRun: openTeamRun,
                onPickerRequestConsumed: { selectedTaskShowsPicker = false },
                onOpenParallel: { showMissions = true },
                onOpenTaskBoard: { selectedWorkspaceTask = nil; setHomeListMode(.board) },
                onOpenChat: { selectedWorkspaceTask = nil; setHomeListMode(.im) },
                onSessionPresentationChanged: { id in
                    guard selectedWorkspaceTask?.task.id == selection.task.id else { return }
                    selectedTaskSessionId = id
                }
            )
            .id(selection.task.id)
        } else if let session = selectedSnapshot {
            SessionDestinationView(session: session, api: api, onCompletionVisible: acknowledgeCompletionIfViewed,
                sharedChatStore: selectedConversationID != nil ? conversations.executionStore(session.id) : nil)
                .id(session.id)
        } else if selectedSessionID != nil {
            ProgressView().tint(Theme.brand)
        } else {
            emptyDetailPlaceholder
        }
    }

    private var emptyDetailPlaceholder: some View {
        VStack(spacing: 12) {
            WandBrandMark(size: 48)
            Text("选择一个任务")
                .font(.wand(size: 14))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WandAmbientBackground() }
    }

    private var shouldShowUpdateBanner: Bool {
        guard let info = serverUpdate else { return false }
        return dismissedUpdateVersion != info.normalizedLatest
    }

    private var updateBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: installingUpdate ? "arrow.triangle.2.circlepath" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.brand)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(installingUpdate ? "正在更新服务端" : "服务端有新版本")
                        .font(.wand(size: 14, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(updateError ?? updateBannerMessage ?? (canManageSettings ? "点击下方按钮一键更新" : "请到网页版或本机终端更新服务端"))
                        .font(.wand(size: 12))
                        .foregroundColor(updateError == nil ? Theme.textSecondary : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    if let latest = serverUpdate?.normalizedLatest {
                        dismissedUpdateVersion = latest
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .disabled(installingUpdate)
            }
            if let info = serverUpdate {
                HStack(spacing: 10) {
                    versionPill(info.displayCurrent, filled: false)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    versionPill(info.displayLatest, filled: true)
                    Spacer(minLength: 0)
                    if canManageSettings {
                    Button {
                        installUpdate()
                    } label: {
                        HStack(spacing: 6) {
                            if installingUpdate {
                                ProgressView()
                                    .controlSize(.mini)
                                    .tint(.white)
                            }
                            Text(installingUpdate ? "更新中" : "立即更新")
                        }
                        .font(.wand(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(installingUpdate ? Theme.brand.opacity(0.65) : Theme.brand)
                        )
                    }
                    .disabled(installingUpdate)
                    }
                }
            }
        }
        .padding(12)
        .wandGlassCard(cornerRadius: 14)
    }

    private func versionPill(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.wand(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(filled ? Theme.brand : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(filled ? Theme.brand.opacity(0.12) : Theme.border.opacity(0.45))
            )
            .overlay(
                Capsule()
                    .stroke(filled ? Theme.brand.opacity(0.55) : Color.clear, lineWidth: 1)
            )
    }

    private func handleQuickAction() {
        guard phase == .ready,
              let pending = quickActions.pending,
              pending.belongs(to: serverID) else { return }
        let hasPresentedSurface = showSettings || showMissions

        switch pending {
        case .showSessions:
            guard quickActions.consume(where: { $0 == pending }) != nil else { return }
            showTaskRoot()
        case .newSession:
            guard quickActions.consume(where: { $0 == pending }) != nil else { return }
            showTaskRoot()
            presentNewConversation = true
        case .openSession(let id, _):
            guard quickActionRequiresRootSessionRouting(
                pending,
                rootIsSessions: false,
                hasPresentedSurface: hasPresentedSurface
            ) || !hasPresentedSurface,
            quickActions.consume(where: { $0 == pending }) != nil else { return }
            showSettings = false
            showMissions = false
            openSessionFromMissions(id)
        }
    }

    private func showTaskRoot() {
        showSettings = false
        showMissions = false
        setHomeListMode(.sessions)
        selectedWorkspaceTask = nil
        selectedSessionID = nil
        selectedSnapshot = nil
        openingSessionID = nil
    }

    /// SwiftUI 没有为 navigationDestination(isPresented:) 提供转场完成回调。用一个短暂、
    /// 可验证的输入锁覆盖 iPhone 默认 push 动画窗口；若期间返回或换会话，identity 检查会
    /// 让旧任务自然失效。这样既拦住重复打开，也不会把 iPad 双栏永久锁死。
    private func releaseSessionOpenGateAfterTransition(for sessionID: String) {
        guard openingSessionID == sessionID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard selectedSessionID == sessionID,
                  openingSessionID == sessionID else { return }
            openingSessionID = nil
        }
    }

    /// 看板/侧栏拿到新分组时，把详情的导航元数据对齐：另一端改名、归档、移动会话都不会
    /// 经过本机的 mutation 回调，只有这里能补上（对齐 Android 的 syncTaskMembership）。
    private func syncSelectedWorkspaceTaskMetadata(_ groups: [TaskDirectoryGroup]) {
        guard let selection = selectedWorkspaceTask else { return }
        for group in groups {
            guard let summary = group.tasks.first(where: { $0.id == selection.task.id }) else { continue }
            let workspace = workspaceForTaskSummary(summary, group: group, workspaces: workspaceStore.workspaces)
            let next = WorkspaceTaskSelection(
                workspace: workspace,
                task: summary.asTask()
            )
            if next != selection { selectedWorkspaceTask = next }
            return
        }
    }

    private func openSessionFromMissions(_ sessionID: String) {
        selectedWorkspaceTask = nil
        showMissions = false
        openingSessionID = sessionID
        openCompletionIntent(sessionID)
        selectedSessionID = sessionID
        selectedSnapshot = nil
        Task {
            do {
                let snapshot = try await api.getSession(id: sessionID)
                guard selectedSessionID == sessionID else { return }
                selectedSnapshot = snapshot
                SessionPresenceController.shared.sync(snapshot: snapshot, serverID: serverID)
            } catch {
                guard selectedSessionID == sessionID else { return }
                selectedSessionID = nil
                selectedSnapshot = nil
                openingSessionID = nil
            }
        }
    }

    /// 打开项目直属会话：留在项目分区，替换任务详情为会话详情。
    /// 看板里的会话若已归属任务，连着任务上下文打开；归属任务以最新分组为准，
    /// 因为会话可能在另一端刚被移动过（与 Android 的 openSession 一致）。
    private func openBoardBoundSession(_ sessionId: String, workspaceTaskId: String) {
        Task {
            await workspaceStore.loadTaskGroups(force: true)
            for group in workspaceStore.taskGroups {
                guard let summary = group.tasks.first(where: { $0.id == workspaceTaskId }) else { continue }
                let workspace = workspaceForTaskSummary(
                    summary,
                    group: group,
                    workspaces: workspaceStore.workspaces
                )
                selectedSessionID = nil
                selectedSnapshot = nil
                openingSessionID = nil
                selectedWorkspaceTask = WorkspaceTaskSelection(
                    workspace: workspace,
                    task: summary.asTask()
                )
                selectedTaskSessionId = sessionId
                selectedTaskShowsPicker = false
                openCompletionIntent(sessionId)
                return
            }
            openWorkspaceStandaloneSession(sessionId)
        }
    }

    private func openCompletionIntent(_ sessionID: String) {
        completionViewIntentSessionId = sessionID
        acknowledgedCompletionRevision = nil
        visibleCompletionSnapshot = nil
    }

    private func openTeamRun(_ runId: String) {
        clearCompletionIntent()
        selectedWorkspaceTask = nil; selectedSessionID = nil; selectedSnapshot = nil
        selectedTaskSessionId = nil; selectedTaskShowsPicker = false
        showingContacts = false; selectedConversationID = nil; selectedContactRunID = runId
        Task {
            guard let detail = try? await api.contactRun(runId), selectedContactRunID == runId else { return }
            if let conversationID = detail.run.conversationId, !conversationID.isEmpty { openConversation(conversationID) }
        }
    }

    private func clearCompletionIntent() {
        completionViewIntentSessionId = nil
        acknowledgedCompletionRevision = nil
        visibleCompletionSnapshot = nil
    }

    /// 只在「明确打开 + 这一代结果真的在屏幕上 + 没有弹层」时确认完成代次。
    /// 同一代次只发一次；失败保留未读提示，下一次明确打开还能重试。
    private func acknowledgeCompletionIfViewed(_ session: SessionSnapshot) {
        visibleCompletionSnapshot = session
        let isJustCompleted = SessionCompletion.isJustCompleted(
            completion: session.completionRevision,
            viewed: session.viewedCompletionRevision,
            status: session.status,
            archived: session.archived,
            ptyBusy: session.ptyBusy,
            inFlight: session.structuredState?.inFlight,
            permissionBlocked: session.permissionBlocked,
            pendingEscalation: session.pendingEscalation != nil,
            providerCliExitCode: session.providerCliExitCode
        )
        guard SessionCompletion.shouldAcknowledge(
            isJustCompleted: isJustCompleted,
            explicitOpen: completionViewIntentSessionId == session.id,
            isSelected: scenePhase == .active && (
                selectedSessionID == session.id ||
                (selectedWorkspaceTask != nil && workspaceStore.visibleSessionID == session.id) ||
                (selectedContactRunID != nil && selectedSessionID == nil && selectedWorkspaceTask == nil)),
            // 本页挂的模态层（设置 / 任务 / 通讯录…）都算挡住结果；
            // 子页自己 sheet 的判断交给各自的 onChange 条件。
            modalVisible: rootModalVisible
        ) else { return }
        let revision = session.completionRevision ?? 0
        guard revision > 0, acknowledgedCompletionRevision != revision else { return }
        acknowledgedCompletionRevision = revision
        Task {
            do {
                try await workspaceStore.markSessionCompletionViewed(
                    sessionId: session.id,
                    completionRevision: revision
                )
            } catch {
                // 保留未读提示，让下一次明确打开重试。
                guard completionViewIntentSessionId == session.id,
                      acknowledgedCompletionRevision == revision else { return }
                acknowledgedCompletionRevision = nil
            }
        }
    }

    private var rootModalVisible: Bool {
        showSettings || showMissions || presentNewConversation || homeModalVisible || selectedContactEmployeeID != nil
    }

    private func openCreatedConversation(_ snapshot: SessionSnapshot) {
        pendingNewConversationCwd = ""
        pendingNewConversationWorkspaceID = nil
        pendingNewConversationTaskID = nil
        selectedWorkspaceTask = nil
        selectedConversationID = nil
        selectedContactRunID = nil
        selectedSessionID = snapshot.id
        selectedSnapshot = snapshot
        openingSessionID = nil
        openCompletionIntent(snapshot.id)
        SessionPresenceController.shared.sync(snapshot: snapshot, serverID: serverID)
        Task { await workspaceStore.loadWorkspaceIndex() }
    }

    private func openConversation(_ id: String) {
        selectedWorkspaceTask = nil; selectedSessionID = nil; selectedSnapshot = nil
        selectedContactRunID = nil; showingContacts = false
        selectedConversationID = id; homeListModeRaw = HomeListMode.im.rawValue
        conversations.select(id); clearCompletionIntent()
    }

    private func openPresetConversation(_ templateID: String) {
        setHomeListMode(.im)
        conversations.creatingPresetID = templateID
    }

    private func openWorkspaceStandaloneSession(_ sessionID: String) {
        guard openingSessionID != sessionID, selectedSessionID != sessionID else { return }
        selectedWorkspaceTask = nil
        openingSessionID = sessionID
        openCompletionIntent(sessionID)
        selectedSessionID = sessionID
        selectedSnapshot = nil
        Task {
            do {
                let snapshot = try await api.getSession(id: sessionID)
                guard selectedSessionID == sessionID else { return }
                selectedSnapshot = snapshot
                openingSessionID = nil
                SessionPresenceController.shared.sync(snapshot: snapshot, serverID: serverID)
            } catch {
                guard selectedSessionID == sessionID else { return }
                selectedSessionID = nil
                selectedSnapshot = nil
                openingSessionID = nil
            }
        }
    }

    /// Worktree 合并 Agent 启动完成：快照已就绪，直接在项目分区展示该托管会话。
    private func presentMergeAgentSession(_ snapshot: SessionSnapshot) {
        selectedWorkspaceTask = nil
        openingSessionID = nil
        selectedSessionID = snapshot.id
        selectedSnapshot = snapshot
        SessionPresenceController.shared.sync(snapshot: snapshot, serverID: serverID)
    }

#if DEBUG
    private func handleDebugSettingsLaunch() {
        guard !didApplyDebugSettingsLaunch,
              phase == .ready else { return }
        let environment = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--wand-open-settings")
            || environment["WAND_DEBUG_OPEN_SETTINGS"] == "1"
            || environment["WAND_DEBUG_OPEN_CONTACTS"] == "1"
            || environment["WAND_DEBUG_OPEN_TEAM_RUN"] != nil else { return }
        didApplyDebugSettingsLaunch = true
        if let runId = environment["WAND_DEBUG_OPEN_TEAM_RUN"], !runId.isEmpty {
            showingContacts = true; selectedContactRunID = runId
        } else if environment["WAND_DEBUG_OPEN_CONTACTS"] == "1" {
            showingContacts = true
        } else { showSettings = true }
    }
#endif

    private func switchServerBeforeAuthentication() {
        // 先使旧回调/重试失效，再退回现有连接页；保留所有已保存服务器及凭据。
        invalidateLifecycle()
        workspaceStore.stopTaskGroupsSync()
        store.disconnect()
    }

    private func authenticate() {
        invalidateLifecycle()
        let generation = lifecycleGeneration
        authenticationRetryAttempt = 0
        phase = .authenticating
        startAuthenticationAttempt(generation: generation)
    }

    private func startAuthenticationAttempt(generation: Int) {
        guard isCurrentLifecycle(generation) else { return }
        let endpointAPI = api
        guard let token, !token.isEmpty else {
            // 裸地址连接（无 token）：直接试列表，401 时引导重新连接。
            authenticationTask = Task { @MainActor in
                do {
                    _ = try await endpointAPI.listSessions()
                    guard !Task.isCancelled, isCurrentLifecycle(generation) else { return }
                    finishAuthentication(generation: generation)
                } catch {
                    guard !Task.isCancelled, isCurrentLifecycle(generation) else { return }
                    authenticationTask = nil
                    if let apiError = error as? WandAPI.APIError,
                       shouldRetryAuthentication(apiError) {
                        scheduleAuthenticationRetry(generation: generation)
                    } else {
                        phase = .failed("无法访问服务器：\(error.localizedDescription)\n如果服务器设有密码，请用「连接码」重新连接。")
                    }
                }
            }
            return
        }

        let endpointURL = serverURL
        authenticationAttempt = WandAuth.authenticate(
            serverURL: endpointURL,
            appToken: token,
            targetEndpointSession: endpointAPI.endpointSession
        ) { result in
            DispatchQueue.main.async {
                guard isCurrentLifecycle(generation) else { return }
                authenticationAttempt = nil
                switch result {
                case .success:
                    finishAuthentication(generation: generation)
                case .failure(let error):
                    if shouldRetryAuthentication(error) {
                        scheduleAuthenticationRetry(generation: generation)
                    } else {
                        phase = .failed(error.userMessage)
                    }
                }
            }
        }
    }

    private func shouldRetryAuthentication(_ error: WandAuth.Failure) -> Bool {
        switch error {
        case .network, .rateLimited:
            return true
        case .server(let status):
            return status >= 500
        case .invalidURL, .unauthorized, .noCookie:
            return false
        }
    }

    private func shouldRetryAuthentication(_ error: WandAPI.APIError) -> Bool {
        switch error {
        case .network:
            return true
        case .server(let status, _):
            return status == 429 || status >= 500
        case .invalidURL, .unauthorized:
            return false
        }
    }

    private func scheduleAuthenticationRetry(generation: Int) {
        guard authenticationRetryAttempt < 8 else {
            phase = .failed("服务器暂时不可用，请稍后重试")
            return
        }
        let delays: [UInt64] = [500, 1_000, 2_000, 4_000, 8_000, 15_000]
        let delay = delays[min(authenticationRetryAttempt, delays.count - 1)]
        authenticationRetryAttempt += 1
        phase = .authenticating
        authenticationRetryTask?.cancel()
        authenticationRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            guard !Task.isCancelled, isCurrentLifecycle(generation) else { return }
            authenticationRetryTask = nil
            startAuthenticationAttempt(generation: generation)
        }
    }

    private func finishAuthentication(generation: Int) {
        guard isCurrentLifecycle(generation) else { return }
        authenticationTask = nil
        authenticationRetryTask?.cancel()
        authenticationRetryTask = nil
        authenticationRetryAttempt = 0
        phase = .ready
        appUpdater.setActive(scenePhase == .active)
        conversations.start()
        startSystemSocket(generation: generation)
        refreshServerUpdateInfo(generation: generation)
        refreshHomeContacts()
    }

    private func refreshHomeContacts() {
        homeContactsGeneration &+= 1
        let generation = homeContactsGeneration
        let lifecycle = lifecycleGeneration
        let endpointAPI = api
        Task {
            async let employees = try? endpointAPI.listContactEmployees()
            async let teams = try? endpointAPI.listContactTeams()
            let values = await (employees, teams)
            guard generation == homeContactsGeneration, isCurrentLifecycle(lifecycle), !Task.isCancelled else { return }
            if let employees = values.0 { homeEmployees = employees }
            if let teams = values.1 { homeTeams = teams }
        }
    }

    private func refreshServerUpdateInfo(generation: Int) {
        updateRefreshTask?.cancel()
        let endpointAPI = api
        updateRefreshTask = Task { @MainActor in
            let config = try? await endpointAPI.serverConfig()
            guard !Task.isCancelled,
                  isCurrentLifecycle(generation),
                  let config,
                  config.updateAvailable == true,
                  let latest = config.latestVersion,
                  !latest.isEmpty else { return }
            canManageSettings = config.canManageSettings == true
            serverUpdate = ServerUpdateInfo(
                current: config.currentVersion ?? "?",
                latest: latest,
                channel: config.updateChannel
            )
            if isCurrentLifecycle(generation) { updateRefreshTask = nil }
        }
    }

    private func startSystemSocket(generation: Int) {
        guard isCurrentLifecycle(generation), systemSocket == nil else { return }
        let socket = WandSocket(baseURL: serverURL)
        socket.onEvent = { [weak socket] incoming in
            guard let socket,
                  self.systemSocket === socket,
                  self.isCurrentLifecycle(generation) else { return }
            guard incoming.type == "notification", let data = incoming.data else { return }
            self.handleSystemNotification(data)
        }
        systemSocket = socket
        socket.connect()
    }

    private func handleSystemNotification(_ data: WsData) {
        switch data.kind {
        case "silicon-employee-definition", "ai-team-definition":
            contactsStore.refreshIfVisible()
            refreshHomeContacts()
        case "update":
            guard let current = data.current, let latest = data.latest else { return }
            serverUpdate = ServerUpdateInfo(current: current, latest: latest, channel: nil)
            updateBannerMessage = "点击下方按钮一键更新"
            updateError = nil
        case "auto-update-start":
            installingUpdate = true
            if let current = data.current, let latest = data.latest {
                serverUpdate = ServerUpdateInfo(current: current, latest: latest, channel: nil)
            }
            updateBannerMessage = "服务端正在下载并安装新版"
            updateError = nil
        case "auto-update-restart", "restart":
            installingUpdate = false
            updateBannerMessage = "更新完成，服务端正在重启"
            updateError = nil
        case "auto-update-failed":
            installingUpdate = false
            updateError = data.error ?? "更新失败，请到网页版设置中查看详情"
        default:
            break
        }
    }

    private func installUpdate() {
        guard !installingUpdate else { return }
        let generation = lifecycleGeneration
        guard isCurrentLifecycle(generation) else { return }
        let endpointAPI = api
        updateInstallTask?.cancel()
        installingUpdate = true
        updateError = nil
        updateBannerMessage = "服务端正在下载并安装新版"
        updateInstallTask = Task { @MainActor in
            do {
                try await endpointAPI.installServerUpdate()
                guard !Task.isCancelled, isCurrentLifecycle(generation) else { return }
                updateBannerMessage = "更新命令已发送，服务端即将重启"
            } catch {
                guard !Task.isCancelled, isCurrentLifecycle(generation) else { return }
                updateError = error.localizedDescription
            }
            guard isCurrentLifecycle(generation) else { return }
            installingUpdate = false
            updateInstallTask = nil
        }
    }

    private func isCurrentLifecycle(_ generation: Int) -> Bool {
        lifecycleGeneration == generation
            && store.activeServerID == serverID
            && store.activeProfile?.connectionIdentity == profile.connectionIdentity
    }

    private func invalidateLifecycle() {
        appUpdater.setActive(false)
        lifecycleGeneration &+= 1
        authenticationTask?.cancel()
        authenticationTask = nil
        authenticationAttempt?.cancel()
        authenticationAttempt = nil
        authenticationRetryTask?.cancel()
        authenticationRetryTask = nil
        authenticationRetryAttempt = 0
        updateRefreshTask?.cancel()
        updateRefreshTask = nil
        updateInstallTask?.cancel()
        updateInstallTask = nil
        installingUpdate = false
        systemSocket?.close()
        systemSocket = nil
        conversations.shutdown()
    }
}

/// 对齐 Android HomeOverviewCard：服务器名 + 会话/任务模式芯片 + 新建 + 溢出菜单。
private struct HomeOverviewBar: View {
    let serverDisplayName: String
    let showNewTask: Bool
    let onNewTask: () -> Void
    let onOpenSettings: () -> Void
    let onSwitchServer: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSwitchServer) {
                HStack(spacing: 8) {
                    WandBrandMark(size: 26)
                    Text(serverDisplayName.isEmpty ? "当前服务器" : serverDisplayName)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(WandQuietButtonStyle()).accessibilityLabel("切换服务器")
            Spacer(minLength: 8)
            if showNewTask {
                Button(action: onNewTask) {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }.buttonStyle(WandQuietButtonStyle()).accessibilityLabel("新建终端或任务")
            }
            Menu {
                Button("设置", systemImage: "gearshape", action: onOpenSettings)
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("更多选项")
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

/// iPhone、窄分屏保持单栏返回栈；iPad 横屏和足够大的自由窗口使用系统双栏导航。
/// 只依据当前可用尺寸，旋转和 Stage Manager 改窗后会自动重新选择布局。
///
/// 宽屏用 NavigationSplitView(selection:)：selection 绑定驱动 detail 栏，选中即显示，
/// 这是双栏下可靠的程序化跳转方式（旧实现用 .columns + 隐藏 NavigationLink 在 iPad 上失效）。
/// 窄屏用 NavigationStack + navigationDestination(isPresented:)：点行 push 详情页。
private struct AdaptiveNavigationContainer<Sidebar: View, Detail: View>: View {
    @Binding var selection: String?
    @Binding var parents: [String]
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let detail: (String?) -> Detail
    @State private var containerSize = CGSize.zero
    @State private var navigationPath: [String] = []

    var body: some View {
        Group {
            if usesWideListDetail(width: containerSize.width, height: containerSize.height) {
                wideLayout
            } else {
                narrowLayout
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            guard abs(newSize.width - containerSize.width) > 0.5
                    || abs(newSize.height - containerSize.height) > 0.5 else { return }
            containerSize = newSize
        }
    }

    private var wideLayout: some View {
        NavigationSplitView {
            sidebar()
        } detail: {
            NavigationStack { detail(selection ?? parents.last) }
                .id(selection ?? parents.last)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var narrowLayout: some View {
        NavigationStack(path: $navigationPath) {
            sidebar()
                .navigationDestination(for: String.self) { marker in
                    detail(marker)
                }
        }
        .onChange(of: selection) { _, newValue in
            // 用 NavigationPath 驱动 push，而不是 isPresented。后者在 List 内部
            // 连续点击/切换任务时可能只更新布尔值，不会重新创建 destination。
            let target = contactNavigationPath(parents: parents, selection: newValue)
            if navigationPath != target {
                navigationPath = target
            }
        }
        .onChange(of: parents) { _, next in
            let target = contactNavigationPath(parents: next, selection: selection)
            if navigationPath != target { navigationPath = target }
        }
        .onChange(of: navigationPath) { _, newPath in
            let retained = parents.filter { newPath.contains($0) }
            let current = newPath.last == retained.last ? nil : newPath.last
            if parents != retained { parents = retained }
            if selection != current { selection = current }
            let accepted = contactNavigationPath(parents: parents, selection: selection)
            if accepted != newPath { navigationPath = accepted }
        }
        .onAppear {
            navigationPath = contactNavigationPath(parents: parents, selection: selection)
        }
    }
}

func usesWideListDetail(width: CGFloat, height: CGFloat) -> Bool {
    width >= 640 && height >= 480
}

import Foundation

enum HomeFoldMode: String, CaseIterable, Identifiable {
    case expand, collapse, running
    var id: String { rawValue }
    var title: String {
        switch self { case .expand: return "展开"; case .collapse: return "收起"; case .running: return "在跑" }
    }
}

enum HomeSessionPulse: Equatable { case running, needsYou, quiet }

/// Execution facts, never inferred from a task's business column or process liveness.
enum HomeExecutionState: String, CaseIterable {
    case running, queued, needsYou, failed, completed, idle, archived
    var label: String {
        switch self {
        case .running: return "运行中"
        case .queued: return "排队中"
        case .needsYou: return "待处理"
        case .failed: return "失败"
        case .completed: return "已完成"
        case .idle: return "未运行"
        case .archived: return "已归档"
        }
    }
    var symbol: String {
        switch self {
        case .running: return "play.fill"
        case .queued: return "clock"
        case .needsYou: return "hand.raised.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .idle: return "pause.circle"
        case .archived: return "archivebox"
        }
    }
}

struct HomeSessionCounts: Equatable {
    var running = 0
    var needsYou = 0
}

struct HomeRecentConversation: Identifiable {
    let group: TaskDirectoryGroup
    let task: WorkspaceTaskSummary?
    let session: WorkspaceSessionSummary
    var id: String { session.id }
}

enum HomeGroupKind: Equatable { case employee, team, pty, blankTerminal, cli }

struct HomeRecentGroup: Identifiable {
    let id: String
    let kind: HomeGroupKind
    let title: String
    let avatar: String?
    let conversations: [HomeRecentConversation]
    /// 员工分组键之外的稳定身份。头像种子必须用这个值，不能用 `employee:<id>` 等展示键。
    let employeeId: String?
    let employeeSystemKey: String?
}

enum HomePresentation {
    static func workspaceLabel(_ group: TaskDirectoryGroup) -> String? {
        guard !group.isGlobal else { return nil }
        let name = group.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = name.isEmpty ? group.workspaceCwd.trimmingCharacters(in: .whitespacesAndNewlines) : name
        return value.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
    }

    static func executionState(_ task: WandBoardTask) -> HomeExecutionState {
        let sessions = task.sessions.filter { $0.archived != true }
        if sessions.contains(where: { $0.permissionBlocked == true || ["waiting-input", "waiting_input"].contains($0.status) }) { return .needsYou }
        if sessions.contains(where: { $0.status == "failed" }) { return .failed }
        if task.executionStatus == "running" || sessions.contains(where: {
            $0.executionStatus == "running" || $0.inFlight == true ||
                ($0.isStructured && $0.inFlight == nil && ["running", "thinking"].contains($0.status))
        }) { return .running }
        if task.hasQueuedExecution || sessions.contains(where: { $0.executionStatus == "queued" || $0.status == "queued" }) { return .queued }
        return task.status == "archived" ? .archived : task.status == "done" ? .completed : .idle
    }

    static func executionState(_ session: WorkspaceSessionSummary) -> HomeExecutionState {
        if session.archived == true { return .archived }
        if session.activityStatus == "failed" { return .failed }
        if pulse(session) == .needsYou { return .needsYou }
        if session.activityStatus == "queued" { return .queued }
        if pulse(session) == .running { return .running }
        return session.isJustCompleted ? .completed : .idle
    }

    static func executionState(_ task: WorkspaceTaskSummary) -> HomeExecutionState {
        let states = task.sessions.filter { $0.archived != true }.map(executionState)
        if states.contains(.needsYou) { return .needsYou }
        if states.contains(.failed) { return .failed }
        if task.executionStatus == "running" || states.contains(.running) { return .running }
        if task.hasQueuedExecution || states.contains(.queued) { return .queued }
        return task.status == "done" ? .completed : .idle
    }
    static func sessionSummary(_ sessions: [WorkspaceSessionSummary], total: Int? = nil) -> String {
        var seen = Set<String>()
        let unique = sessions.filter { seen.insert($0.id).inserted }
        var parts = ["\(total ?? unique.count) 个会话"]
        let running = unique.filter { pulse($0) == .running }.count
        let needsYou = unique.filter { pulse($0) == .needsYou }.count
        if running > 0 { parts.append("\(running) 在跑") }
        if needsYou > 0 { parts.append("\(needsYou) 等你") }
        return parts.joined(separator: " · ")
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "queued": return "排队中"
        case "running", "thinking": return "在跑"
        case "permission", "permission-blocked", "waiting-input": return "等你"
        case "reconnecting": return "重连中"
        case "failed": return "失败"
        case "stopped": return "已停止"
        case "exited": return "已结束"
        default: return "空闲"
        }
    }
    static func pulse(_ session: WorkspaceSessionSummary) -> HomeSessionPulse {
        guard session.archived != true else { return .quiet }
        switch session.activityStatus.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "queued", "running", "thinking", "reconnecting": return .running
        case "permission", "permission-blocked", "waiting-input", "failed": return .needsYou
        default: return .quiet
        }
    }

    static func isActive(_ session: WorkspaceSessionSummary) -> Bool {
        session.archived != true && (pulse(session) != .quiet || session.isJustCompleted)
    }

    static func counts(_ groups: [TaskDirectoryGroup]) -> HomeSessionCounts {
        var result = HomeSessionCounts()
        for item in conversations(groups) {
            switch pulse(item.session) {
            case .running: result.running += 1
            case .needsYou: result.needsYou += 1
            case .quiet: break
            }
        }
        return result
    }

    static func conversations(_ groups: [TaskDirectoryGroup]) -> [HomeRecentConversation] {
        var seen = Set<String>()
        return groups.flatMap { group in
            group.tasks.flatMap { task in
                task.sessions.map { HomeRecentConversation(group: group, task: task, session: $0) }
            } + group.standaloneSessions.map { HomeRecentConversation(group: group, task: nil, session: $0) }
        }.filter { $0.session.archived != true && seen.insert($0.id).inserted }
            .sorted {
                let a = $0.session.startedAt ?? "", b = $1.session.startedAt ?? ""
                return a == b ? $0.id < $1.id : a > b
            }
    }

    static func identity(_ session: WorkspaceSessionSummary) -> (String, HomeGroupKind) {
        if let employee = nonblank(session.employeeId) { return ("employee:" + employee, .employee) }
        if let chat = session.teamChat { return ("team:" + (nonblank(chat.teamId) ?? chat.runId), .team) }
        if let step = session.teamStep { return ("team-run:" + step.runId, .team) }
        if session.sessionKind == "pty" {
            return nonblank(session.provider).map { $0 != "shell" } == true ? ("pty", .pty) : ("blank-terminal", .blankTerminal)
        }
        return ("cli:" + (session.provider ?? ""), .cli)
    }

    static func recentGroups(
        _ groups: [TaskDirectoryGroup], employees: [SiliconEmployee], teams: [ContactTeam], limit: Int = 8
    ) -> [HomeRecentGroup] {
        let ordered = conversations(groups)
        let terminals = ordered.filter { [.pty, .blankTerminal].contains(identity($0.session).1) }
        let others = ordered.filter { ![.pty, .blankTerminal].contains(identity($0.session).1) }
        let source = Array(others.prefix(max(0, limit))) + terminals
        var keys: [String] = [], buckets: [String: [HomeRecentConversation]] = [:]
        for item in source {
            let key = identity(item.session).0
            if buckets[key] == nil { keys.append(key) }
            buckets[key, default: []].append(item)
        }
        var result = keys.compactMap { key -> HomeRecentGroup? in
            guard let items = buckets[key], let head = items.first?.session else { return nil }
            let kind = identity(head).1
            let person = employees.first { $0.id == head.employeeId }
            let team = teams.first { $0.id == head.teamChat?.teamId }
            let title: String
            switch kind {
            case .employee: title = nonblank(person?.name) ?? nonblank(head.employeeName) ?? "员工"
            case .team:
                title = nonblank(team?.name) ?? items.compactMap { nonblank($0.session.teamChat?.teamName) ?? nonblank($0.session.teamStep?.teamName) }.first ?? "AI 团队"
            case .pty: title = "PTY 终端"
            case .blankTerminal: title = "空白终端"
            case .cli: title = head.providerLabel
            }
            return HomeRecentGroup(id: key, kind: kind, title: title,
                avatar: person.map { $0.avatar } ?? head.employeeAvatar,
                conversations: items,
                employeeId: kind == .employee ? head.employeeId : nil,
                employeeSystemKey: kind == .employee ? person?.systemKey : nil)
        }
        result = result.filter { ![.pty, .blankTerminal].contains($0.kind) }
            + result.filter { $0.kind == .pty } + result.filter { $0.kind == .blankTerminal }
        if !result.contains(where: { $0.kind == .blankTerminal }) {
            result.append(HomeRecentGroup(
                id: "blank-terminal", kind: .blankTerminal, title: "空白终端", avatar: nil,
                conversations: [], employeeId: nil, employeeSystemKey: nil
            ))
        }
        return result
    }

    /// Android 最近对话卡的局部展开规则：区级「收起/在跑」只改变默认视图，
    /// 点击某一组时临时切到「展开」，不写回区级设置。
    static func recentGroupFold(_ sectionFold: HomeFoldMode, temporarilyExpanded: Bool) -> HomeFoldMode {
        temporarilyExpanded ? .expand : sectionFold
    }

    /// 身份头不随会话数量与筛选变化；单会话员工也保留一级标题。
    static func recentGroupShowsHeader(
        _ group: HomeRecentGroup,
        sectionFold: HomeFoldMode,
        visibleConversationCount: Int
    ) -> Bool {
        !group.conversations.isEmpty || [.pty, .blankTerminal].contains(group.kind)
    }

    static func recentGroupExpandsContent(_ fold: HomeFoldMode, visibleConversationCount: Int) -> Bool {
        fold != .collapse && visibleConversationCount > 0
    }

    static func sessions(_ sessions: [WorkspaceSessionSummary], fold: HomeFoldMode, attentionOnly: Bool = false) -> [WorkspaceSessionSummary] {
        if attentionOnly { return sessions.filter { pulse($0) == .needsYou } }
        return fold == .running ? sessions.filter(isActive) : sessions
    }

    static func visibleGroups(_ groups: [TaskDirectoryGroup], query: String, attentionOnly: Bool, employees: [SiliconEmployee] = []) -> [TaskDirectoryGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.compactMap { group in
            let directoryMatches = matches(query, [group.workspaceName, group.workspaceCwd])
            let tasks = group.tasks.compactMap { task -> WorkspaceTaskSummary? in
                let wholeTask = directoryMatches || matches(query, [group.workspaceName, group.workspaceCwd, task.name, task.cwd])
                let kept = task.sessions.filter {
                    (!attentionOnly || pulse($0) == .needsYou) && (wholeTask || matches(query, sessionFields($0, employees: employees) + [group.workspaceName, group.workspaceCwd, task.name, task.cwd]))
                }
                guard !kept.isEmpty || (!attentionOnly && wholeTask) else { return nil }
                return replacing(task, sessions: kept)
            }
            let loose = group.standaloneSessions.filter {
                (!attentionOnly || pulse($0) == .needsYou) && (directoryMatches || matches(query, sessionFields($0, employees: employees) + [group.workspaceName, group.workspaceCwd]))
            }
            guard !tasks.isEmpty || !loose.isEmpty || (!attentionOnly && directoryMatches) else { return nil }
            return group.replacing(tasks: tasks, standaloneSessions: loose)
        }
    }

    static func matches(_ query: String, _ fields: [String?]) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = fields.compactMap { $0 }.joined(separator: " ")
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            text.localizedCaseInsensitiveContains(String($0))
        }
    }

    static func sessionFields(_ session: WorkspaceSessionSummary, employees: [SiliconEmployee] = []) -> [String?] {
        [session.title, session.cwd, session.providerLabel, session.employeeName,
         employees.first { $0.id == session.employeeId }?.name, session.teamChat?.teamName,
         session.teamStep?.title, session.teamStep?.memberName, session.teamStep?.teamName]
    }

    static func replacing(_ task: WorkspaceTaskSummary, sessions: [WorkspaceSessionSummary]) -> WorkspaceTaskSummary {
        WorkspaceTaskSummary(id: task.id, workspaceId: task.workspaceId, name: task.name, worktree: task.worktree,
            layout: task.layout, status: task.status, createdAt: task.createdAt, lastOpenedAt: task.lastOpenedAt,
            cwd: task.cwd, isolated: task.isolated, worktreeError: task.worktreeError, sessions: sessions,
            totalSessions: task.totalSessions, executionStatus: task.executionStatus, queuedExecutionCount: task.queuedExecutionCount)
    }

    private static func nonblank(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
    }
}

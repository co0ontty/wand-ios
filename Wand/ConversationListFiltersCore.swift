import Foundation

/// Business stages come only from wand_tasks, never workspace_tasks.status or runner state.
enum ConversationTaskStage: String, CaseIterable {
    case all, backlog, todo, doing, review, ready, archived, none, unknown
    static var options: [Self] { allCases.filter { $0 != .unknown } }
    static func businessStatus(_ value: String?) -> Self {
        if value == "done" { return .review }
        guard let value, let stage = Self(rawValue: value), ![.all, .none, .unknown].contains(stage) else { return .unknown }
        return stage
    }
    static func resolve(boardStatus: String?, hasTaskContainer: Bool, workspaceTaskId: String?) -> Self {
        if hasTaskContainer { return businessStatus(boardStatus) }
        return workspaceTaskId == nil ? .none : .unknown
    }
    var title: String {
        switch self {
        case .all: return "全部状态"
        case .backlog: return "待立项"
        case .todo: return "等待认领"
        case .doing: return "执行中"
        case .review: return "待验收"
        case .ready: return "待归档"
        case .archived: return "已归档"
        case .none: return "未关联任务"
        case .unknown: return "任务状态未知"
        }
    }
}

enum ConversationWorkspaceFilter: Hashable {
    case all, unassigned, workspace(String), unknown
    static func resolve(id: String?, synthetic: Bool = false, global: Bool = false) -> Self {
        if synthetic || global || id == "wand-global" { return .unassigned }
        guard let id, !id.isEmpty else { return .unknown }
        return .workspace(id)
    }
}

/// `.current` is the baseline projection: archived sessions stay out of the list until the
/// user explicitly picks another scope, and only then count as an active filter.
enum ConversationArchiveScope: String, CaseIterable {
    case current, all, archived
    var title: String {
        switch self { case .current: return "未归档"; case .all: return "全部含已归档"; case .archived: return "已归档" }
    }
}

enum ConversationRuntime: String, CaseIterable {
    case confirmation, running, queued, idle, finished, failed
    static var options: [Self] { [.confirmation, .running, .queued, .idle, .finished, .failed] }
    var title: String {
        switch self {
        case .confirmation: return "需要我确认"
        case .running: return "运行中"
        case .queued: return "排队中"
        case .idle: return "空闲"
        case .finished: return "已结束"
        case .failed: return "运行失败"
        }
    }
    var symbol: String {
        switch self {
        case .confirmation: return "exclamationmark.bubble"
        case .running: return "waveform.path.ecg"
        case .queued: return "clock"
        case .idle: return "circle"
        case .finished: return "stop.circle"
        case .failed: return "xmark.circle"
        }
    }
}

struct ConversationFilterFacts: Equatable {
    let stage: ConversationTaskStage
    let workspace: ConversationWorkspaceFilter
    let archived: Bool
    let active: Bool
    let searchText: String
    var runtime: ConversationRuntime? = .idle
    /// Server employee ID; "none" is the explicit unassigned value.
    var employee = "none"
}

struct ConversationListFilters: Equatable {
    var runtimes: Set<ConversationRuntime> = []
    var workspaces: Set<ConversationWorkspaceFilter> = []
    var employees: Set<String> = []
    var stage: ConversationTaskStage = .all
    var workspace: ConversationWorkspaceFilter = .all
    var archive: ConversationArchiveScope = .current
    var activeOnly = false
    var count: Int { (runtimes.isEmpty ? 0 : 1) + (workspaces.isEmpty ? 0 : 1) + (employees.isEmpty ? 0 : 1) + (stage == .all ? 0 : 1) + (workspace == .all ? 0 : 1) + (archive == .current ? 0 : 1) + (activeOnly ? 1 : 0) }
    var isDefault: Bool { count == 0 }

    /// All predicates run against one association; never combine different siblings' matches.
    func matches(_ facts: ConversationFilterFacts, query: String = "") -> Bool {
        (runtimes.isEmpty || (facts.runtime.map(runtimes.contains) ?? false))
            && (workspaces.isEmpty || workspaces.contains(facts.workspace))
            && (employees.isEmpty || employees.contains(facts.employee))
            && (stage == .all || stage == facts.stage)
            && (workspace == .all || workspace == facts.workspace)
            && (archive == .all || facts.archived == (archive == .archived))
            && (!activeOnly || facts.active)
            && query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { facts.searchText.localizedCaseInsensitiveContains(String($0)) }
    }
}

struct ConversationWorkspaceOption: Identifiable {
    let id: String
    let title: String
}

struct ConversationEmployeeOption: Identifiable {
    let id: String
    let title: String
}

enum ConversationFilterDimension {
    case runtime, workspace, employee
    var title: String {
        switch self { case .runtime: return "运行状态"; case .workspace: return "工作区"; case .employee: return "员工" }
    }
    var symbol: String {
        switch self { case .runtime: return "waveform.path.ecg"; case .workspace: return "folder"; case .employee: return "person" }
    }
    var identifier: String {
        switch self { case .runtime: return "conversation-runtime-expand"; case .workspace: return "conversation-workspace-expand"; case .employee: return "conversation-employee-expand" }
    }
}

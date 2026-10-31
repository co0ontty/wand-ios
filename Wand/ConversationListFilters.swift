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

enum ConversationArchiveScope: String, CaseIterable {
    case current, all, archived
    var title: String {
        switch self { case .current: return "未归档会话"; case .all: return "全部会话"; case .archived: return "已归档会话" }
    }
}

struct ConversationFilterFacts: Equatable {
    let stage: ConversationTaskStage
    let workspace: ConversationWorkspaceFilter
    let archived: Bool
    let active: Bool
    let searchText: String
}

struct ConversationListFilters: Equatable {
    var stage: ConversationTaskStage = .all
    var workspace: ConversationWorkspaceFilter = .all
    var archive: ConversationArchiveScope = .all
    var activeOnly = false
    var count: Int { (stage == .all ? 0 : 1) + (workspace == .all ? 0 : 1) + (archive == .all ? 0 : 1) + (activeOnly ? 1 : 0) }
    var isDefault: Bool { count == 0 }

    /// All predicates run against one association; never combine different siblings' matches.
    func matches(_ facts: ConversationFilterFacts, query: String = "") -> Bool {
        (stage == .all || stage == facts.stage)
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

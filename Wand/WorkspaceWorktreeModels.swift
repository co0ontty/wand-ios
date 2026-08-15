import Foundation

/// `GET /api/workspaces/:id/worktrees` 的任务 worktree 审查项。
struct WorkspaceWorktreeReview: Codable, Equatable, Identifiable {
    let taskId: String
    let taskName: String
    let taskStatus: String
    let branch: String
    let path: String
    let baseRef: String?
    let state: String
    let actionable: Bool
    let reason: String?
    let aheadCount: Int
    let hasUncommittedChanges: Bool
    let hasConflicts: Bool
    let commits: [WorkspaceWorktreeCommit]

    var id: String { taskId }

    /// 与 web 端 STATE_META 一致的状态文案。
    var stateLabel: String {
        switch state {
        case "ready": return "待合并"
        case "dirty": return "有未提交改动"
        case "conflict": return "可能冲突"
        case "empty": return "已同步"
        default: return "不可用"
        }
    }

    /// 与 web 端 workspaceWorktreeSummary 一致：任务名 · 最新 commit 主题。
    var summary: String {
        let commit = commits.first?.subject.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !commit.isEmpty && commit != name {
            return "\(name) · \(commit)"
        }
        return !name.isEmpty ? name : (!commit.isEmpty ? commit : branch)
    }

    /// 详情行：N commits · 工作区有改动 · 需处理冲突；无内容时退化为 reason。
    var details: String {
        var parts: [String] = []
        if aheadCount > 0 { parts.append("\(aheadCount) commits") }
        if hasUncommittedChanges { parts.append("工作区有改动") }
        if hasConflicts { parts.append("需处理冲突") }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        if let reason, !reason.isEmpty { return reason }
        return "没有新的待合并改动"
    }
}

struct WorkspaceWorktreeCommit: Codable, Equatable {
    let hash: String
    let shortHash: String?
    let subject: String
}

struct WorkspaceWorktreeOverview: Codable, Equatable {
    let workspaceId: String
    let repoRoot: String
    let targetBranch: String
    let worktrees: [WorkspaceWorktreeReview]

    var actionableWorktrees: [WorkspaceWorktreeReview] {
        worktrees.filter(\.actionable)
    }
}

enum WorkspaceWorktreeMergeError: LocalizedError, Equatable {
    case missingTargetBranch
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .missingTargetBranch: return "无法识别项目默认分支。"
        case .emptySelection: return "请至少选择一个有待合并改动的 Worktree。"
        }
    }
}

/// 与 web 端 buildWorkspaceMergeAgentPrompt 一致：Agent 只拿服务端审查结果里的
/// 规范路径与 ref，绝不信任界面上的自由文本。
func buildWorkspaceMergeAgentPrompt(
    workspace: Workspace,
    overview: WorkspaceWorktreeOverview,
    selectedTaskIds: Set<String>
) throws -> String {
    let selected = overview.worktrees.filter { selectedTaskIds.contains($0.taskId) && $0.actionable }
    guard !overview.targetBranch.isEmpty else { throw WorkspaceWorktreeMergeError.missingTargetBranch }
    guard !selected.isEmpty else { throw WorkspaceWorktreeMergeError.emptySelection }

    let manifest = selected.enumerated().map { index, worktree in
        WorkspaceMergeManifestEntry(
            order: index + 1,
            task: worktree.taskName,
            branch: worktree.branch,
            worktreePath: worktree.path,
            baseRef: worktree.baseRef,
            uncommittedChanges: worktree.hasUncommittedChanges,
            potentialConflict: worktree.hasConflicts,
            commitsAhead: worktree.aheadCount,
            commitSubjects: worktree.commits.map(\.subject).filter { !$0.isEmpty }
        )
    }
    let manifestJSON = WorkspaceMergeManifestEntry.prettyEncode(manifest)

    return [
        "你是 Wand 为项目「\(workspace.name)」启动的 Worktree 合并 Agent。",
        "项目主工作区：\(overview.repoRoot.isEmpty ? workspace.cwd : overview.repoRoot)",
        "唯一目标分支：\(overview.targetBranch)",
        "",
        "请按清单顺序审查并合并所选 Worktree：",
        manifestJSON,
        "",
        "执行要求：",
        "1. 先读取项目内适用的 AGENTS.md/agent.md 与仓库约定，再检查主工作区和每个 Worktree 的真实 Git 状态。",
        "2. 对有未提交改动的 Worktree，先理解改动、完成必要验证，并创建清晰的提交；不得丢弃或覆盖现有用户改动。",
        "3. 只把清单中的分支合并到 \(overview.targetBranch)，按清单顺序逐个处理；不要改为其他目标分支。",
        "4. 遇到冲突时理解双方意图后解决并验证；若无法安全判断，停止在可恢复状态并清楚报告，不要强行覆盖。",
        "5. 合并完成后运行与改动相称的测试。不要 push，也不要删除 Worktree、任务分支或 Wand 的项目任务记录。",
        "6. 最后汇报每个 Worktree 的提交/合并结果、测试结果，以及任何仍需人工处理的问题。",
    ].joined(separator: "\n")
}

/// 合并清单条目；字段声明顺序即 JSON 输出顺序，与 web 端 manifest 保持一致。
struct WorkspaceMergeManifestEntry: Codable, Equatable {
    let order: Int
    let task: String
    let branch: String
    let worktreePath: String
    let baseRef: String?
    let uncommittedChanges: Bool
    let potentialConflict: Bool
    let commitsAhead: Int
    let commitSubjects: [String]

    static func prettyEncode(_ entries: [WorkspaceMergeManifestEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

/// `POST /api/workspaces/:id/tasks` 的响应：任务实体 + 运行目录信息，无 layout/sessions。
struct WorkspaceTaskCreation: Codable, Equatable {
    let id: String
    let workspaceId: String
    let name: String
    let worktree: WorkspaceTaskWorktree?
    let status: String
    let cwd: String
    let isolated: Bool?
    let worktreeError: String?

    var isIsolated: Bool { isolated ?? (worktree != nil) }
}

/// `GET /api/workspaces/:id` 的响应：项目实体 + 计数 + 直属会话。
struct WorkspaceDetail: Codable, Equatable {
    let id: String
    let name: String
    let cwd: String
    let defaultProvider: WandProvider?
    let layout: LayoutNode?
    let createdAt: String
    let lastOpenedAt: String?
    let worktreeCount: Int?
    let sessionCount: Int?
    let sessions: [WorkspaceSessionSummary]

    /// 未绑定任务的直属会话（与 web 端 standaloneWorkspaceSessions 一致：倒序展示）。
    var standaloneSessions: [WorkspaceSessionSummary] {
        sessions.filter { $0.workspaceTaskId == nil }.reversed()
    }
}

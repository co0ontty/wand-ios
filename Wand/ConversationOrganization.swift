import SwiftUI

// MARK: - Conversation organization protocol

enum ConversationOrganizationMode: String, CaseIterable, Identifiable {
    case auto
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "默认范围"
        case .all: return "所有工作会话"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "保护人工命名任务中的会话"
        case .all: return "包含人工任务中的会话"
        }
    }
}

/// 目录菜单的范围投影。全局目录仍然是 workspace 范围，不能退化成 target.kind=all。
enum ConversationOrganizationTarget: Equatable {
    case workspace(id: String)
    case directory(cwd: String)

    var body: [String: Any] {
        switch self {
        case .workspace(let id): return ["kind": "workspace", "workspaceId": id]
        case .directory(let cwd): return ["kind": "directory", "cwd": cwd]
        }
    }
}

extension TaskDirectoryGroup {
    var conversationOrganizationTarget: ConversationOrganizationTarget? {
        if isSynthetic {
            let cwd = normalizeWorkspaceDirectory(workspaceCwd)
            return cwd.isEmpty ? nil : .directory(cwd: cwd)
        }
        // Includes the global group: the server resolves its exact workspace membership.
        guard !workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .workspace(id: workspaceId)
    }
}

struct ConversationOrganizationPreview: Codable, Equatable {
    let token: String
    let sessionCount: Int
    let manualSessionCount: Int
    let skippedSessionCount: Int
    let existingTaskCount: Int
    let contentCharacters: Int
    let estimatedModelRequests: Int
    let unchanged: Bool
    let activeJobId: String?
}

struct ConversationOrganizationCreatedTask: Codable, Equatable {
    let taskId: String
    let cardId: String
    let title: String
    let sessionCount: Int
}

struct ConversationOrganizationReusedTask: Codable, Equatable {
    let taskId: String
    let title: String
    let sessionCount: Int
}

struct ConversationOrganizationUpdatedTask: Codable, Equatable {
    let taskId: String
    let previousTitle: String
    let title: String
}

struct ConversationOrganizationMovedSession: Codable, Equatable {
    let sessionId: String
    let taskId: String
    let taskName: String
}

struct ConversationOrganizationUnassignedSession: Codable, Equatable {
    let sessionId: String
    let reason: String
}

struct ConversationOrganizationRefusal: Codable, Equatable {
    let id: String
    let kind: String
    let reason: String
}

struct ConversationOrganizationResult: Codable, Equatable {
    let ok: Bool
    let foundSessions: Int
    let eligibleSessions: Int
    let skippedManualSessions: Int
    let skippedSessions: Int
    let analyzedSessions: Int
    let createdTasks: [ConversationOrganizationCreatedTask]
    let reusedTasks: [ConversationOrganizationReusedTask]
    let updatedTasks: [ConversationOrganizationUpdatedTask]
    let movedSessions: [ConversationOrganizationMovedSession]
    let unassignedSessions: [ConversationOrganizationUnassignedSession]
    let refused: [ConversationOrganizationRefusal]
    let unchanged: Bool?
    let cancelled: Bool?
    let error: String?
}

struct ConversationOrganizationJob: Codable, Equatable, Identifiable {
    let id: String
    let status: String
    let stage: String
    let processedSessions: Int
    let totalSessions: Int
    let modelRequests: Int
    let result: ConversationOrganizationResult
    let logSessionId: String?
    let error: String?

    var isRunning: Bool { status == "running" }
    var isFailure: Bool { status == "failed" || status == "interrupted" }
}

private struct ConversationOrganizationPreviewEnvelope: Decodable {
    let kind: String
    let preview: ConversationOrganizationPreview
}

private struct ConversationOrganizationJobEnvelope: Decodable {
    let job: ConversationOrganizationJob
}

protocol ConversationOrganizationAPI {
    func prepareConversationOrganization(target: ConversationOrganizationTarget, mode: ConversationOrganizationMode) async throws -> ConversationOrganizationPreview
    func startConversationOrganization(token: String, force: Bool) async throws -> ConversationOrganizationJob
    func conversationOrganizationJobByToken(_ token: String) async throws -> ConversationOrganizationJob
    func conversationOrganizationJob(id: String) async throws -> ConversationOrganizationJob
    func cancelConversationOrganization(id: String) async throws -> ConversationOrganizationJob
}

extension WandAPI: ConversationOrganizationAPI {
    func prepareConversationOrganization(
        target: ConversationOrganizationTarget,
        mode: ConversationOrganizationMode
    ) async throws -> ConversationOrganizationPreview {
        let response = try await request(
            ConversationOrganizationPreviewEnvelope.self,
            method: "POST",
            path: "/api/sessions/auto-organize",
            body: ["action": "preview", "target": target.body, "mode": mode.rawValue],
            timeout: 90
        )
        return response.preview
    }

    func startConversationOrganization(token: String, force: Bool) async throws -> ConversationOrganizationJob {
        do {
            let response = try await request(
                ConversationOrganizationJobEnvelope.self,
                method: "POST",
                path: "/api/sessions/auto-organize",
                body: ["action": "start", "token": token, "force": force],
                timeout: 30
            )
            return response.job
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Start acceptance is intentionally unknown on transport/parse failure. Read the
            // original token once; never create another preview or model request automatically.
            do {
                return try await conversationOrganizationJobByToken(token)
            } catch {
                throw error
            }
        }
    }

    func conversationOrganizationJobByToken(_ token: String) async throws -> ConversationOrganizationJob {
        let encoded = percentEncodePathComponent(token)
        let response = try await request(
            ConversationOrganizationJobEnvelope.self,
            method: "GET",
            path: "/api/sessions/auto-organize/by-token/\(encoded)"
        )
        return response.job
    }

    func conversationOrganizationJob(id: String) async throws -> ConversationOrganizationJob {
        let encoded = percentEncodePathComponent(id)
        let response = try await request(
            ConversationOrganizationJobEnvelope.self,
            method: "GET",
            path: "/api/sessions/auto-organize/\(encoded)"
        )
        return response.job
    }

    func cancelConversationOrganization(id: String) async throws -> ConversationOrganizationJob {
        let encoded = percentEncodePathComponent(id)
        let response = try await request(
            ConversationOrganizationJobEnvelope.self,
            method: "POST",
            path: "/api/sessions/auto-organize/\(encoded)/cancel"
        )
        return response.job
    }
}

@MainActor
final class ConversationOrganizationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case prepared
        case running
        case done
        case error
    }

    let api: any ConversationOrganizationAPI
    let target: ConversationOrganizationTarget
    let onFinished: (() async -> Void)?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: ConversationOrganizationMode = .auto
    @Published private(set) var preview: ConversationOrganizationPreview?
    @Published private(set) var job: ConversationOrganizationJob?
    @Published private(set) var feedback = ""
    @Published private(set) var errorMessage: String?
    private var pollTask: Task<Void, Never>?
    private var revision = 0
    private var submittedToken: String?
    private var cancelling = false
    var needsRecheck: Bool { submittedToken != nil || job != nil }
    var canAdjustScope: Bool { phase == .prepared || phase == .done || (phase == .error && job != nil && job?.isRunning != true) }

    init(api: any ConversationOrganizationAPI, target: ConversationOrganizationTarget, onFinished: (() async -> Void)? = nil) {
        self.api = api
        self.target = target
        self.onFinished = onFinished
    }

    deinit { pollTask?.cancel() }

    func setMode(_ next: ConversationOrganizationMode) {
        guard !needsRecheck, phase == .idle || phase == .error else { return }
        mode = next
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        revision &+= 1
        if phase == .loading || phase == .running {
            phase = .error
            feedback = "查询已暂停；后台已接受的归组不会停止。"
        }
    }

    func previewScope() {
        guard !needsRecheck, phase == .idle || phase == .error else { return }
        stopPolling()
        revision &+= 1
        let current = revision
        phase = .loading
        preview = nil
        job = nil
        errorMessage = nil
        feedback = "正在读取当前目录的会话正文并估算处理量…"
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await api.prepareConversationOrganization(target: target, mode: mode)
                guard !Task.isCancelled, current == revision else { return }
                if let activeJobID = next.activeJobId {
                    let active = try await api.conversationOrganizationJob(id: activeJobID)
                    guard !Task.isCancelled, current == revision else { return }
                    preview = next
                    await watch(active, revision: current)
                } else if next.sessionCount == 0 {
                    preview = next
                    feedback = "没有符合范围且有正文的工作会话；跳过 \(next.manualSessionCount) 个人工任务会话、\(next.skippedSessionCount) 个归档或无正文等会话。可调整范围，不会调用模型。"
                    phase = .done
                } else {
                    preview = next
                    feedback = previewDescription(next)
                    phase = .prepared
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, current == revision else { return }
                errorMessage = error.localizedDescription
                feedback = "无法预览会话自动分组。"
                phase = .error
            }
        }
    }

    func confirm() {
        guard phase == .prepared, let preview else { return }
        stopPolling()
        revision &+= 1
        let current = revision
        phase = .loading
        errorMessage = nil
        feedback = "正在提交后台归组…"
        submittedToken = preview.token
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let accepted = try await api.startConversationOrganization(token: preview.token, force: preview.unchanged)
                guard !Task.isCancelled, current == revision else { return }
                job = accepted
                self.preview = nil
                await watch(accepted, revision: current)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, current == revision else { return }
                errorMessage = error.localizedDescription
                feedback = "后台归组回执未确认；可重新查询原作业，不会自动重发。"
                phase = .error
            }
        }
    }

    func reset() {
        guard phase != .loading, job?.isRunning != true, !(submittedToken != nil && job == nil) else { return }
        stopPolling()
        submittedToken = nil
        preview = nil
        job = nil
        feedback = ""
        errorMessage = nil
        phase = .idle
    }

    func recheck() {
        guard needsRecheck, phase == .error || phase == .done else { return }
        let originalJob = job
        let token = submittedToken
        stopPolling()
        revision &+= 1
        let current = revision
        phase = .loading
        errorMessage = nil
        feedback = "正在查询原作业…"
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let next: ConversationOrganizationJob
                if let originalJob {
                    next = try await api.conversationOrganizationJob(id: originalJob.id)
                } else if let token {
                    next = try await api.conversationOrganizationJobByToken(token)
                } else { return }
                guard !Task.isCancelled, current == revision else { return }
                await watch(next, revision: current)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, current == revision else { return }
                errorMessage = error.localizedDescription
                phase = .error
            }
        }
    }

    func cancel() {
        guard let job, job.isRunning, !cancelling else { return }
        cancelling = true
        Task { [weak self] in
            guard let self else { return }
            defer { cancelling = false }
            do {
                let next = try await api.cancelConversationOrganization(id: job.id)
                guard self.job?.id == next.id else { return }
                self.job = next
                self.feedback = "已请求取消后续归组；已完成部分会保留。"
            } catch {
                guard self.job?.id == job.id else { return }
                feedback = "取消回执未确认，仍可查询原作业；不会自动重发。"
            }
        }
    }

    private func watch(_ initial: ConversationOrganizationJob, revision expected: Int) async {
        job = initial
        phase = initial.isRunning ? .running : (initial.isFailure ? .error : .done)
        feedback = initial.isRunning ? initial.stage : resultDescription(initial)
        var current = initial
        var polls = 0
        while current.isRunning && polls < 900 {
            polls += 1
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled, expected == revision else { return }
                current = try await api.conversationOrganizationJob(id: current.id)
                guard !Task.isCancelled, expected == revision else { return }
                job = current
                feedback = current.isRunning ? current.stage : resultDescription(current)
            } catch is CancellationError {
                return
            } catch {
                guard expected == revision else { return }
                errorMessage = error.localizedDescription
                phase = .error
                return
            }
        }
        guard !Task.isCancelled, expected == revision else { return }
        if current.isRunning {
            feedback = "归组仍在后台运行；查询已暂停，可继续查询原作业。"
            phase = .error
            return
        }
        job = current
        phase = current.isFailure ? .error : .done
        feedback = resultDescription(current)
        await onFinished?()
    }

    private func previewDescription(_ preview: ConversationOrganizationPreview) -> String {
        "将整理 \(preview.sessionCount) 个工作会话，正文 \(preview.contentCharacters) 字符，预计 \(preview.estimatedModelRequests) 个系统模型请求；跳过 \(preview.manualSessionCount) 个人工任务会话，另排除 \(preview.skippedSessionCount) 个归档/私聊/系统记录或无正文会话。使用初二当前配置，失败可能按已配候选降级并产生费用；确认后创建或复用任务、移动会话，不执行会话中的工作。"
    }

    private func resultDescription(_ job: ConversationOrganizationJob) -> String {
        let result = job.result
        let summary = "新建 \(result.createdTasks.count) 个任务、复用 \(result.reusedTasks.count) 个任务，归入 \(result.movedSessions.count) 个会话；未分组 \(result.unassignedSessions.count) 个、拒绝 \(result.refused.count) 项。"
        if let error = job.error ?? result.error, !error.isEmpty { return "归组未完成：\(error)；\(summary)" }
        if job.isFailure { return "归组未完成；\(summary)" }
        if job.status == "cancelled" || result.cancelled == true { return "已取消后续归组，已完成部分已保留；\(summary)" }
        if result.eligibleSessions == 0 { return "没有符合范围且有正文的工作会话。" }
        if result.movedSessions.isEmpty { return "本次未移动会话；\(summary)" }
        return "归组完成：\(summary)"
    }
}

struct ConversationOrganizationPanel: View {
    let group: TaskDirectoryGroup
    let onClose: () -> Void
    @ObservedObject var controller: ConversationOrganizationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(Theme.brand)
                Text("根据会话内容自动分组")
                    .font(.wand(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Button("收起", action: onClose)
                    .font(.wand(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            Text(group.workspaceCwd.isEmpty ? group.workspaceName : group.workspaceCwd)
                .font(.wand(size: 11))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)

            HStack(spacing: 8) {
                organizationButton
                if controller.job?.isRunning == true {
                    Button("取消后续") { controller.cancel() }
                        .buttonStyle(WandSecondaryButtonStyle())
                } else if controller.canAdjustScope {
                    Button("调整范围") { controller.reset() }
                        .buttonStyle(WandSecondaryButtonStyle())
                }
            }
            if !controller.needsRecheck && (controller.phase == .idle || controller.phase == .error) {
                Picker("范围", selection: Binding(
                    get: { controller.mode },
                    set: { controller.setMode($0) }
                )) {
                    ForEach(ConversationOrganizationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(controller.mode.detail)
                    .font(.wand(size: 11))
                    .foregroundColor(Theme.textSecondary)
            }

            if let preview = controller.preview, controller.phase == .prepared {
                previewMetrics(preview)
            }
            if let job = controller.job, controller.phase == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(job.processedSessions)/\(job.totalSessions) 个会话 · \(job.modelRequests) 个模型请求")
                        .font(.wand(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            if !controller.feedback.isEmpty {
                Text(controller.errorMessage.map { "\(controller.feedback) \($0)" } ?? controller.feedback)
                    .font(.wand(size: 12))
                    .foregroundColor(controller.phase == .error ? Theme.danger : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(reduceMotion ? nil : WandMotion.stateSwap, value: controller.phase)
        .onDisappear { controller.stopPolling() }
    }

    private var organizationButton: some View {
        let title: String
        let action: () -> Void
        switch controller.phase {
        case .idle, .error:
            title = controller.needsRecheck ? "查询原作业" : (controller.phase == .error ? "重新预览" : "读取范围")
            action = controller.needsRecheck ? controller.recheck : controller.previewScope
        case .loading:
            title = "处理中…"
            action = {}
        case .prepared:
            title = controller.preview?.unchanged == true ? "确认重新分析" : "确认并开始"
            action = controller.confirm
        case .running:
            title = "后台归组中…"
            action = {}
        case .done:
            title = controller.job == nil ? "没有可整理会话" : "已完成 · 查看结果"
            action = controller.recheck
        }
        return Button(action: action) {
            Text(title)
                .contentTransition(.opacity)
                .frame(width: 156, height: 20)
        }
            .buttonStyle(WandPrimaryButtonStyle())
            .frame(width: 180, height: 40)
            .disabled(controller.phase == .loading || controller.phase == .running || (controller.phase == .done && controller.job == nil))
            .accessibilityLabel(title)
    }

    private func previewMetrics(_ preview: ConversationOrganizationPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("会话 \(preview.sessionCount) 个 · 正文 \(preview.contentCharacters) 字符 · 预计模型请求 \(preview.estimatedModelRequests) 个")
            Text("已有任务候选 \(preview.existingTaskCount) 个 · 跳过人工任务会话 \(preview.manualSessionCount) 个")
        }
        .font(.wand(size: 12))
        .foregroundColor(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

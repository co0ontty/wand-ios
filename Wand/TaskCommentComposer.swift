import SwiftUI

@MainActor
private enum TaskCommentDraftCache {
    struct Draft { var body = ""; var employeeId = ""; var source: String? = nil; var revision = UUID() }
    static var drafts: [String: Draft] = [:]
}

/// A chosen mention is the only dispatch authority. Typed @ text never selects an employee by itself.
struct TaskCommentComposer: View {
    let api: WandAPI
    let taskId: String
    let employees: [(id: String, name: String)]
    @Binding var sourceCommentId: String?
    let onSaved: () async -> Void
    @State private var bodyText = ""
    @State private var employeeId = ""
    @State private var caret = 0
    @State private var mentionDismissed = ""
    @State private var seenSource: String? = nil
    @State private var ready = false
    @State private var revision = UUID()
    @State private var busy = false
    @State private var active = true
    @State private var message = ""
    @State private var outcome = "idle"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    private var phase: String { busy ? "sending" : outcome }
    private var boundName: String { employees.first { $0.id == employeeId }?.name ?? "" }
    private var dispatching: Bool { TaskCommentMention.holds(bodyText, name: boundName) }
    private var mention: TaskCommentMention.Query? { TaskCommentMention.query(in: bodyText, caret: caret) }
    private var mentionKey: String { mention.map { "\($0.start):\($0.text)" } ?? "" }
    private var mentionMatches: [(id: String, name: String)] {
        guard let mention, mentionDismissed != mentionKey else { return [] }
        return employees.filter { mention.text.isEmpty || $0.name.localizedStandardContains(mention.text) }
    }
    private func label(_ state: String) -> String {
        switch state {
        case "sending": return "正在提交…"
        case "saved": return "评论已保存"
        case "failed": return "提交失败"
        case "unknown": return "送达待核对"
        default: return dispatching ? "评论并派发" : "发表评论"
        }
    }

    private func changed() {
        revision = UUID()
        outcome = "idle"; message = ""
        TaskCommentDraftCache.drafts[taskId] = .init(body: bodyText, employeeId: employeeId, source: sourceCommentId, revision: revision)
    }

    private func replaceBody(_ value: String, from previous: String) {
        bodyText = value
        caret = TaskCommentMention.caretOffset(from: previous, to: value)
        if !boundName.isEmpty && !TaskCommentMention.holds(value, name: boundName) { employeeId = "" }
        changed()
    }

    private func choose(_ employee: (id: String, name: String)) {
        let next = TaskCommentMention.insert(body: bodyText, caret: caret, name: employee.name)
        bodyText = next.body
        caret = next.caret
        employeeId = employee.id
        mentionDismissed = ""
        changed()
        focused = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sourceCommentId {
                HStack {
                    Text("回复评论 " + String(sourceCommentId.prefix(8))).font(.caption)
                    Button("取消回复") { self.sourceCommentId = nil }
                }
            }
            if !mentionMatches.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(mentionMatches, id: \.id) { employee in
                            Button("@\(employee.name)") { choose(employee) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("提及员工")
            } else if mention != nil && mentionDismissed != mentionKey {
                Text("没有匹配的员工").font(.caption).foregroundStyle(.secondary).accessibilityLabel("提及员工")
            }
            TextField("写评论。输入 @ 选择员工，选中后才会派发", text: Binding(get: { bodyText }, set: { replaceBody($0, from: bodyText) }), axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("task-comment-input")
            HStack(alignment: .top) {
                Button { submit() } label: {
                    ZStack {
                        ForEach(["idle", "sending", "saved", "failed", "unknown"], id: \.self) { state in
                            Text(label(state)).opacity(phase == state ? 1 : 0).accessibilityHidden(phase != state)
                        }
                    }.frame(width: 128, height: 32)
                    .animation(reduceMotion ? nil : WandMotion.stateSwap, value: phase)
                }
                    .accessibilityLabel(label(phase))
                    .disabled(busy || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(message.isEmpty ? (dispatching ? "将派发给 @\(boundName)。只派发这一次选中的人。" : "正文里没有选中的 @员工时，不会启动执行。") : message)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            let draft = TaskCommentDraftCache.drafts[taskId] ?? .init()
            active = true
            bodyText = draft.body; employeeId = draft.employeeId; caret = draft.body.count; revision = draft.revision
            if sourceCommentId == nil { sourceCommentId = draft.source }
            seenSource = sourceCommentId
            ready = true
        }
        .onDisappear { active = false }
        .onChange(of: sourceCommentId) { source in
            if ready, source != seenSource, source != nil {
                let gap = bodyText.isEmpty || bodyText.last?.isWhitespace == true ? "" : " "
                bodyText += gap + "@"
                caret = bodyText.count
                mentionDismissed = ""
            }
            seenSource = source
            changed(); focused = true
        }
    }

    private func submit() {
        guard !busy else { return }
        let taskId = taskId, text = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let employee = TaskCommentMention.holds(text, name: boundName) ? employeeId : ""
        let source = sourceCommentId, version = revision
        guard !text.isEmpty else { return }
        busy = true; mentionDismissed = mentionKey; message = ""
        let identity = TaskCommentRequestIdentity(taskId: taskId, body: text, employeeId: employee, sourceCommentId: source)
        Task {
            do {
                let comment = try await api.postBoardTaskComment(id: taskId, requestId: identity.requestId, body: text,
                    employeeId: employee.isEmpty ? nil : employee, sourceCommentId: source)
                identity.settle(comment)
                let rejected = comment.dispatch?.state == "failed"
                if active && revision == version && !rejected {
                    bodyText = ""; employeeId = ""; caret = 0; sourceCommentId = nil; changed()
                } else if !rejected && TaskCommentDraftCache.drafts[taskId]?.revision == version {
                    TaskCommentDraftCache.drafts[taskId] = .init()
                }
                guard active else { return }
                outcome = comment.dispatch?.deliveryUncertain == true ? "unknown" : rejected ? "failed" : "saved"
                message = comment.dispatch?.deliveryUncertain == true ? "评论已保存；请求身份已保留，同一评论不会重新派发。" : rejected ? comment.dispatch?.error ?? "执行明确未接受，原指令已保留。" : "评论已保存"
                await onSaved()
            } catch {
                guard active else { return }
                if let apiError = error as? WandAPI.APIError, case .server(let status, _) = apiError,
                   (400..<500).contains(status), status != 408, status != 409 { outcome = "failed" }
                else { outcome = "unknown" }
                message = error.localizedDescription + "；请刷新核对，同一评论重试复用请求标识。"
            }
            busy = false
        }
    }
}

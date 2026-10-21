import SwiftUI
import UIKit

@MainActor
private enum TaskCommentDraftCache {
    struct Draft { var body = ""; var employeeId = ""; var source: String? = nil; var revision = UUID() }
    static var drafts: [String: Draft] = [:]
}

/// A chosen mention is the only dispatch authority. Typed @ text never selects an employee by itself.
/// `#TASK-133` references are resolved by the server: the client only offers the current task's direct children.
struct TaskCommentComposer: View {
    let api: WandAPI
    let taskId: String
    let employees: [(id: String, name: String)]
    /// 当前任务的直接子任务：可被 `#` 引用。
    var referenceTasks: [TaskReferenceTarget] = []
    @Binding var sourceCommentId: String?
    /// 本次回复是否要派发员工：回复并派发时在评论框里预填 `@`。
    @Binding var replyDispatches: Bool
    var onRevealSubmit: () -> Void = {}
    let onSaved: () async -> Void

    static func submitAnchor(taskId: String) -> String { "task-comment-submit-\(taskId)" }
    @State private var bodyText = ""
    @State private var employeeId = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var composing = false
    @State private var editorHeight: CGFloat = 96
    @State private var mentionDismissed = ""
    @State private var referenceDismissed = ""
    @State private var referenceIndex = 0
    @State private var seenSource: String? = nil
    @State private var ready = false
    @State private var revision = UUID()
    @State private var busy = false
    @State private var active = true
    @State private var message = ""
    @State private var outcome = "idle"
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var focused = false
    private var phase: String { busy ? "sending" : outcome }
    private var boundName: String { employees.first { $0.id == employeeId }?.name ?? "" }
    private var dispatching: Bool { TaskCommentMention.holds(bodyText, name: boundName) }
    private var caret: Int {
        guard let range = Range(selection, in: bodyText) else { return bodyText.count }
        return TaskCommentMention.caretOffset(in: bodyText, at: range.upperBound) ?? bodyText.count
    }
    private var validation: String? {
        if composing { return "请先完成输入法组字，再提交评论。" }
        if mention != nil { return "请先从 @ 候选列表选择员工，或删除未完成的提及。" }
        return TaskCommentMention.validationMessage(bodyText, name: dispatching ? boundName : "")
    }
    private var mention: TaskCommentMention.Query? { TaskCommentMention.query(in: bodyText, caret: caret) }
    private var mentionKey: String { mention.map { "\($0.start):\($0.text)" } ?? "" }
    private var mentionMatches: [(id: String, name: String)] {
        guard !composing, let mention, mentionDismissed != mentionKey else { return [] }
        return employees.filter { mention.text.isEmpty || $0.name.localizedStandardContains(mention.text) }
    }
    /// 光标处的 `#` 引用 token；与 Web 共享同一套规则（见 `TaskCommentReference`）。
    private var reference: TaskCommentReference.Query? { TaskCommentReference.query(in: bodyText, caret: caret) }
    private var referenceKey: String { reference.map { "\($0.start):\($0.query)" } ?? "" }
    private var referenceMatches: [TaskReferenceTarget] {
        guard !composing, let reference, referenceDismissed != referenceKey else { return [] }
        let query = reference.query
        return referenceTasks.filter { target in
            guard !query.isEmpty else { return true }
            return target.identifier.localizedCaseInsensitiveContains(query)
                || target.title.localizedStandardContains(query)
        }
    }
    /// 正文里已经写下的引用编号（用于提示，不代替服务端校验）。
    private var referencedIdentifiers: [String] { TaskCommentReference.parseIdentifiers(bodyText) }
    private var unknownReferencedIdentifiers: [String] {
        TaskCommentReference.unknownIdentifiers(bodyText, children: referenceTasks)
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

    private func replaceBody(_ value: String) {
        bodyText = value
        if !boundName.isEmpty && !TaskCommentMention.holds(value, name: boundName) { employeeId = "" }
        changed()
    }

    private func choose(_ employee: (id: String, name: String)) {
        guard mention != nil else { return }
        let next = TaskCommentMention.insert(body: bodyText, caret: caret, name: employee.name, replacingName: boundName)
        bodyText = next.body
        moveCaret(to: next.caret)
        employeeId = employee.id
        mentionDismissed = ""
        changed()
        focused = true
    }

    private func moveCaret(to offset: Int) {
        let caret = min(max(offset, 0), bodyText.count)
        let index = bodyText.index(bodyText.startIndex, offsetBy: caret)
        selection = NSRange(location: index.utf16Offset(in: bodyText), length: 0)
    }

    /// 插入一条引用：正文里写成 `#TASK-133`（后面已经紧跟空白时不再多补一个空格），编号本身不再额外编码。
    private func choose(reference target: TaskReferenceTarget) {
        let next = TaskCommentReference.insert(body: bodyText, caret: caret, identifier: target.identifier)
        bodyText = next.body
        moveCaret(to: next.caret)
        referenceDismissed = ""
        changed()
        focused = true
    }

    private func moveReferenceSelection(_ delta: Int) -> KeyPress.Result {
        guard !referenceMatches.isEmpty else { return .ignored }
        let count = referenceMatches.count
        referenceIndex = (referenceIndex + delta + count) % count
        announceSelectedReference()
        return .handled
    }

    private func commitReferenceSelection() -> KeyPress.Result {
        guard !referenceMatches.isEmpty, referenceIndex < referenceMatches.count else { return .ignored }
        choose(reference: referenceMatches[referenceIndex])
        return .handled
    }

    private func dismissReferencePicker() -> KeyPress.Result {
        guard reference != nil else { return .ignored }
        referenceDismissed = referenceKey
        return .handled
    }

    /// 键盘移动时把当前高亮项念给读屏用户。
    private func announceSelectedReference() {
        guard referenceIndex < referenceMatches.count else { return }
        let target = referenceMatches[referenceIndex]
        UIAccessibility.post(notification: .announcement, argument: referenceAccessibilityLabel(target))
    }

    private func referenceAccessibilityLabel(_ target: TaskReferenceTarget) -> String {
        let status = target.status.isEmpty ? "" : "，\(target.status)"
        return "\(target.identifier)，\(target.title)\(status)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            replyBanner
            mentionPicker
            referencePicker
            composerInput
            referenceWarning
            submitRow
        }
        .onChange(of: focused) { _, editing in
            if editing { onRevealSubmit() }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _ in
            // Mention/reference results and multiline input can grow after focus.
            if focused {
                Task { @MainActor in
                    // Let the Form commit the new row metrics before resolving its anchor.
                    await Task.yield()
                    if focused { onRevealSubmit() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            // Scroll only after the system has resized the Form, not on a guessed delay.
            if focused { onRevealSubmit() }
        }
        .onAppear {
            let draft = TaskCommentDraftCache.drafts[taskId] ?? .init()
            active = true
            bodyText = draft.body; employeeId = draft.employeeId; revision = draft.revision
            moveCaret(to: draft.body.count)
            if sourceCommentId == nil { sourceCommentId = draft.source }
            seenSource = sourceCommentId
            ready = true
        }
        .onDisappear { active = false }
        .onChange(of: referenceKey) { _, _ in referenceIndex = 0 }
        .onChange(of: sourceCommentId) { source in
            if ready, source != seenSource, source != nil {
                let gap = bodyText.isEmpty || bodyText.last?.isWhitespace == true ? "" : " "
                // 只有「回复并派发」才预填 `@`；普通回复不预填，避免误触员工。
                if replyDispatches {
                    bodyText += gap + "@"
                    moveCaret(to: bodyText.count)
                    mentionDismissed = ""
                }
            }
            seenSource = source
            changed(); focused = true
        }
    }

    /// 输入框下方的说明：派发对象、引用目标，以及「没选 @员工 时只是普通评论」。
    private var composerHint: String {
        var parts: [String] = []
        if !bodyText.isEmpty, let validation { parts.append(validation) }
        if dispatching {
            parts.append("将派发给 @\(boundName)。只派发这一次选中的人。")
        } else {
            parts.append("正文里没有选中的 @员工时，不会启动执行。")
        }
        if !referencedIdentifiers.isEmpty {
            parts.append("本轮引用 " + referencedIdentifiers.map { "#\($0)" }.joined(separator: "、") + "。")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - 子视图

    @ViewBuilder
    private var replyBanner: some View {
        if let sourceCommentId {
            HStack {
                Text("回复评论 " + String(sourceCommentId.prefix(8))).font(.caption)
                Button("取消回复") { self.sourceCommentId = nil; self.replyDispatches = false }
            }
        }
    }

    @ViewBuilder
    private var mentionPicker: some View {
        if !mentionMatches.isEmpty {
            TaskCommentMentionPicker(employees: mentionMatches,
                                     selectedEmployeeId: dispatching ? employeeId : "",
                                     onChoose: choose)
        } else if mention != nil && mentionDismissed != mentionKey {
            Text("没有匹配的员工").font(.caption).foregroundStyle(.secondary).accessibilityLabel("提及员工")
        }
    }

    @ViewBuilder
    private var referencePicker: some View {
        if !referenceMatches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("引用任务").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("↑↓ 切换 · Enter 插入").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(referenceMatches.enumerated()), id: \.element.id) { index, target in
                            referenceOption(target, index: index)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("引用任务")
        } else if reference != nil && referenceDismissed != referenceKey {
            Text("没有匹配的可引用任务").font(.caption).foregroundStyle(.secondary).accessibilityLabel("引用任务")
        }
    }

    private func referenceOption(_ target: TaskReferenceTarget, index: Int) -> some View {
        Button {
            referenceIndex = index
            choose(reference: target)
        } label: {
            HStack(spacing: 6) {
                Text("#\(target.identifier)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.brandText)
                Text(target.title)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !target.status.isEmpty {
                    Text(target.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(referenceIndex == index ? Theme.brandSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(referenceAccessibilityLabel(target))
        .accessibilityHint("插入引用")
        .accessibilityAddTraits(referenceIndex == index ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private var composerInput: some View {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let minimum = lineHeight * (typeSize.isAccessibilitySize ? 1 : 3) + 8
        let maximum = lineHeight * (typeSize.isAccessibilitySize ? 2 : 8) + 8
        return IMEAwareComposerTextView(
            text: Binding(get: { bodyText }, set: { replaceBody($0) }),
            placeholder: "写评论。输入 @ 选择员工，输入 # 引用子任务", isFocused: focused,
            disableAutocorrect: true, maximumHeight: maximum, submitOnReturn: false,
            selection: $selection, accessibilityIdentifier: "task-comment-input", accessibilityLabel: "评论或本轮指令",
            onHardwareKey: { key in
                switch key {
                case .keyboardUpArrow: return moveReferenceSelection(-1) == .handled
                case .keyboardDownArrow: return moveReferenceSelection(1) == .handled
                case .keyboardReturnOrEnter: return commitReferenceSelection() == .handled
                case .keyboardEscape: return dismissReferencePicker() == .handled
                default: return false
                }
            },
            onFocusChange: { focused = $0 }, onCompositionChange: { composing = $0 },
            onSubmit: {}, onHeightChange: { editorHeight = $0 }
        )
        .frame(height: min(maximum, max(minimum, editorHeight)))
        .padding(.horizontal, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var referenceWarning: some View {
        if !unknownReferencedIdentifiers.isEmpty {
            Text("引用 \(unknownReferencedIdentifiers.joined(separator: "、")) 不在当前任务的子任务里，提交后会被服务端拒绝。")
                .font(.caption).foregroundStyle(Theme.warning)
        }
    }

    private var submitRow: some View {
        TaskCommentSubmitRow(phase: phase, labels: ["idle", "sending", "saved", "failed", "unknown"].map { ($0, label($0)) },
                             hint: message.isEmpty ? composerHint : message,
                             disabled: busy || validation != nil,
                             onSubmit: submit)
    }

    private func submit() {
        guard !busy else { return }
        let taskId = taskId
        let name = dispatching ? boundName : ""
        // Recheck in the real send path, before creating an identity or starting a request.
        if let error = validation {
            message = error; outcome = "failed"
            return
        }
        let text = TaskCommentMention.submissionBody(bodyText, name: name)
        let employee = name.isEmpty ? "" : employeeId
        let source = sourceCommentId, version = revision
        busy = true; mentionDismissed = mentionKey; referenceDismissed = referenceKey; message = ""
        let identity = TaskCommentRequestIdentity(taskId: taskId, body: text, employeeId: employee, sourceCommentId: source)
        Task {
            do {
                let comment = try await api.postBoardTaskComment(id: taskId, requestId: identity.requestId, body: text,
                    employeeId: employee.isEmpty ? nil : employee, sourceCommentId: source)
                identity.settle(comment)
                let rejected = comment.dispatch?.state == "failed"
                if active && revision == version && !rejected {
                    bodyText = ""; employeeId = ""; moveCaret(to: 0); sourceCommentId = nil; changed()
                } else if !rejected && TaskCommentDraftCache.drafts[taskId]?.revision == version {
                    TaskCommentDraftCache.drafts[taskId] = .init()
                }
                guard active else { return }
                outcome = comment.dispatch?.deliveryUncertain == true ? "unknown" : rejected ? "failed" : "saved"
                message = comment.dispatch?.deliveryUncertain == true ? "评论已保存；请求身份已保留，同一评论不会重新派发。" : rejected ? comment.dispatch?.error ?? "执行明确未接受，原指令已保留。" : "评论已保存"
                await onSaved()
            } catch {
                guard active else { return }
                if let apiError = error as? WandAPI.APIError, case .server(let status, let serverMessage) = apiError,
                   (400..<500).contains(status), status != 408, status != 409 {
                    // 明确的校验拒绝（例如引用了不属于当前任务的编号）：原样告诉用户，保留草稿。
                    outcome = "failed"
                    message = serverMessage
                }
                else {
                    outcome = "unknown"
                    message = error.localizedDescription + "；请刷新核对，同一评论重试复用请求标识。"
                }
            }
            busy = false
        }
    }
}

/// Native candidates are independently accessible even when embedded in a Form row.
struct TaskCommentMentionPicker: View {
    let employees: [(id: String, name: String)]
    let selectedEmployeeId: String
    let onChoose: ((id: String, name: String)) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(employees, id: \.id) { employee in
                    Button { onChoose(employee) } label: {
                        Text("@\(employee.name)")
                            .frame(maxWidth: .infinity, minHeight: WandLayout.controlTouch, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("@\(employee.name)")
                    .accessibilityHint("插入提及并选择此员工为本轮派发对象")
                    .accessibilityIdentifier("task-comment-mention-\(employee.id)")
                    .accessibilityAddTraits(selectedEmployeeId == employee.id ? .isSelected : [])
                }
            }
        }
        .frame(maxHeight: 180)
        // Keep the native scroll container transparent to AX traversal. Giving the
        // container its own label hides the independently actionable candidates.
        .accessibilityIdentifier("task-comment-mentions")
    }
}

/// Native layout keeps the same button through every receipt state. At accessibility
/// sizes the hint gets its own line instead of compressing either piece of content.
struct TaskCommentSubmitRow: View {
    let phase: String
    let labels: [(String, String)]
    let hint: String
    let disabled: Bool
    let onSubmit: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: WandLayout.fieldGap))
            : AnyLayout(HStackLayout(alignment: .top, spacing: WandLayout.fieldGap))
        layout {
            Button(action: onSubmit) {
                ZStack {
                    ForEach(labels, id: \.0) { item in
                        Text(item.1)
                            .opacity(phase == item.0 ? 1 : 0)
                            .accessibilityHidden(phase != item.0)
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
                .frame(minWidth: 128, minHeight: WandLayout.controlTouch)
                .animation(reduceMotion ? nil : WandMotion.stateSwap, value: phase)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(labels.first { $0.0 == phase }?.1 ?? "")
            .accessibilityIdentifier("task-comment-submit")
            .disabled(disabled)
            Text(hint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("task-comment-hint")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

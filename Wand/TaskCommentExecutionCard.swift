import SwiftUI
import UIKit

/// 评论正文渲染：`#TASK-133` 显示成引用 token（等宽字体、主题色），点一下跳到该子任务。
/// 切词规则与服务端 `src/task-comment-references.ts` 共享同一套（见 `TaskCommentReference`）。
struct TaskCommentBodyView: UIViewRepresentable {
    let body: String
    var onOpenReference: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOpenReference: onOpenReference) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        view.linkTextAttributes = [.foregroundColor: UIColor(Theme.brandText), .underlineStyle: 0]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 先把正文放进去，测高时才有真实内容。
        view.attributedText = TaskCommentBodyFormatter.attributed(body)
        view.accessibilityLabel = body
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onOpenReference = onOpenReference
        let attributed = TaskCommentBodyFormatter.attributed(body)
        if !uiView.attributedText.isEqual(to: attributed) { uiView.attributedText = attributed }
        uiView.accessibilityLabel = body
    }

    static func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onOpenReference: (String) -> Void
        init(onOpenReference: @escaping (String) -> Void) { self.onOpenReference = onOpenReference }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            guard URL.scheme == TaskCommentBodyFormatter.referenceScheme,
                  let identifier = URL.pathComponents.last, !identifier.isEmpty else { return true }
            onOpenReference(identifier)
            return false
        }
    }
}

/// 正文切段与引用 token 样式。
enum TaskCommentBodyFormatter {
    static let referenceScheme = "wand-task-reference"

    static func attributed(_ body: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        for segment in TaskCommentReference.segments(body) {
            if let identifier = segment.identifier {
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .medium),
                    .foregroundColor: UIColor(Theme.brandText),
                    .backgroundColor: UIColor(Theme.brandSoft)
                ]
                if let url = URL(string: "\(referenceScheme)://task/\(identifier)") { attributes[.link] = url }
                result.append(NSAttributedString(string: segment.text, attributes: attributes))
            } else {
                result.append(NSAttributedString(string: segment.text, attributes: [
                    .font: baseFont,
                    .foregroundColor: UIColor(Theme.textPrimary)
                ]))
            }
        }
        return result
    }
}

/// 员工执行卡片：卡片头（头像 / 名字 / 状态 / 动作数 / 送达 / 耗时），
/// 卡片体（`任务` 标签行 + `回复` 标签行），展开后是动作明细。
struct TaskCommentExecutionCard: View {
    let api: WandAPI
    let taskId: String
    let comment: WandTaskComment
    let employee: SiliconEmployee?
    let onOpenSession: (String) -> Void
    /// 本轮引用到的子任务编号（`TASK-133`），展示用编号；空数组时不显示引用行。
    var referencedIdentifiers: [String] = []
    /// 点引用芯片时跳到那个子任务。
    var onOpenReferencedTask: ((String) -> Void)? = nil

    @State private var execution: TaskCommentExecution?
    @State private var loading = false
    @State private var loadFailed = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dispatch: WandTaskCommentDispatch? { comment.dispatch }

    /// 状态变化时重新读一次本轮结果（执行中 → 结束）。
    private var loadKey: String {
        "\(comment.id)|\(dispatch?.state ?? "")|\(dispatch?.status ?? "")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            bodyRows
            referenceRow
            if expanded { detail }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .task(id: loadKey) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ContactAvatar(id: dispatch?.employeeId ?? "", avatar: employee?.avatar ?? "",
                          systemKey: employee?.systemKey, provider: employee?.agents.first?.provider, size: 22)
            Text(dispatch?.employeeName ?? "员工")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            statusPill
            Spacer(minLength: 4)
            if let count = execution?.actionCount, count > 0 {
                Button {
                    withAnimation(reduceMotion ? nil : WandMotion.expansion) { expanded.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Text("\(count) 个动作")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.brandText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(count) 个动作，展开动作明细")
            }
            deliveryMarker
            if let seconds = execution?.elapsedSeconds {
                Text(taskCommentElapsedLabel(seconds: seconds))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusPill: some View {
        let label = dispatch?.label ?? TaskCommentStatusLabels.unknown
        // 颜色按状态键判定，不从展示文案反推：文案表换词不会让状态色跟着漂。
        let key = dispatch?.statusKey ?? ""
        let done = key == "done" || key == "idle"
        let running = key == "running" || key == "blocked" || key == "pending" || key == "queued"
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background((done ? Theme.successSoft : running ? Theme.warning.opacity(0.14) : Theme.surfaceSoft), in: Capsule())
            .foregroundStyle(done ? Theme.success : running ? Theme.warning : Theme.textSecondary)
    }

    private var deliveryMarker: some View {
        let label = dispatch?.deliveryLabel ?? "送达未知"
        let uncertain = label == "送达未知"
        return HStack(spacing: 3) {
            Image(systemName: uncertain ? "questionmark.circle" : "paperplane")
                .font(.system(size: 10))
            Text(label).font(.caption2)
        }
        .foregroundStyle(uncertain ? Theme.textSecondary : Theme.textSecondary)
        .accessibilityLabel("送达状态：\(label)")
    }

    private var bodyRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledRow(title: "任务", tint: Theme.textSecondary) {
                Text(comment.dispatchInstruction)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            labeledRow(title: "回复", tint: Theme.success) {
                replyContent
            }
        }
    }

    @ViewBuilder
    private var replyContent: some View {
        if let execution, execution.available {
            if execution.replyText.isEmpty {
                Text("本轮没有可读回复。")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(execution.replyText)
                    .font(.callout)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取本轮结果…").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        } else if loadFailed {
            VStack(alignment: .leading, spacing: 4) {
                Text("本轮结果暂时读不到。").font(.caption).foregroundStyle(Theme.textSecondary)
                Button("重试读取本轮结果") { Task { await load(force: true) } }
                    .font(.caption).foregroundStyle(Theme.brandText)
            }
        } else if execution?.isRunning == true {
            Text("执行中，本轮结果还没有冻结。").font(.caption).foregroundStyle(Theme.textSecondary)
        } else {
            Button("查看本轮结果") { Task { await load(force: true) } }
                .font(.caption).foregroundStyle(Theme.brandText)
        }
    }

    /// 引用目标行：`目标` + 每个引用目标的编号芯片（`#TASK-133`），点一下跳到那个子任务。
    ///
    /// 与 Web 的 `TaskExecutionReferences` 同一语义：芯片上写的是编号（用户写进正文的句柄），
    /// 不是内部任务 ID；没有引用时不占位。
    @ViewBuilder
    private var referenceRow: some View {
        if !referencedIdentifiers.isEmpty {
            HStack(alignment: .center, spacing: 6) {
                Text("目标")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                ForEach(referencedIdentifiers, id: \.self) { identifier in
                    Button {
                        onOpenReferencedTask?(identifier)
                    } label: {
                        Text("#\(identifier)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.brandText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开任务 \(identifier)")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func labeledRow<Content: View>(title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(tint)
            content()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let execution, execution.available {
            VStack(alignment: .leading, spacing: 6) {
                Text("动作明细 · \(execution.actionCount) 个动作 / \(execution.thinkingCount) 段思考 / \(execution.replyCount) 段回复")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if execution.tools.isEmpty {
                    Text("本轮没有工具调用。").font(.caption).foregroundStyle(Theme.textMuted)
                } else {
                    ForEach(execution.tools) { tool in
                        HStack(spacing: 6) {
                            Image(systemName: "hammer")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.brandText)
                            Text(tool.name).font(.caption).foregroundStyle(Theme.textPrimary)
                            Text("\(tool.count) 次").font(.caption2).foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                metaRow(label: "执行状态", value: execution.outcome.isEmpty ? "—" : execution.outcome)
                metaRow(label: "送达", value: dispatch?.deliveryLabel ?? "送达未知")
                metaRow(label: "本轮结果", value: execution.available ? "可读取" : "不可读取")
                if let sessionId = dispatch?.sessionId, !sessionId.isEmpty {
                    HStack {
                        Text("会话").font(.caption2).foregroundStyle(Theme.textSecondary)
                        Text(String(sessionId.prefix(8))).font(.caption2.monospaced()).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                        Button("查看本次执行") { onOpenSession(sessionId) }
                            .font(.caption2).foregroundStyle(Theme.brandText)
                    }
                }
            }
            .padding(8)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Text("动作明细暂时读不到。").font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
            Text(value).font(.caption2).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private func load(force: Bool = false) async {
        guard let dispatch else { return }
        // 已经读到可用结果就不再重复拉；状态变化后（执行中 → 结束）才重读。
        guard force || execution?.available != true else { return }
        guard !loading else { return }
        // 执行还在跑时结果没有冻结，等状态变化后由 task(id:) 再读一次。
        if dispatch.status == "running" || dispatch.state == "pending" { return }
        guard dispatch.sessionId != nil else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await api.boardTaskCommentResult(taskId: taskId, commentId: comment.id)
            execution = taskCommentExecution(from: result)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}

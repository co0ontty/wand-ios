import SwiftUI

private struct ChatViewportHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var chatViewportHeight: CGFloat {
        get { self[ChatViewportHeightKey.self] }
        set { self[ChatViewportHeightKey.self] = newValue }
    }
}
func activityPanelHeight(viewportHeight: CGFloat) -> CGFloat {
    viewportHeight > 0 ? min(activityWindowHeight, max(120, viewportHeight / 3)) : activityWindowHeight
}
func activityShouldAutoExpand(newest: Bool, running: Bool, timelineEnabled: Bool) -> Bool {
    newest && running && timelineEnabled
}

private struct ActivityTimelineRow {
    let position: Int
    let item: DisplayItem
    let occurredAt: String?
    let key: String
}

private func activityOccurredAt(_ item: DisplayItem) -> String? {
    switch item {
    case .tool(_, _, _, let input, _, _): return input["__wandToolActivity"]?.objectValue?["occurredAt"]?.stringValue
    case .plain(.thinking(_, _, let occurredAt, _)): return occurredAt
    default: return nil
    }
}

private func activityTimelineRows(_ items: [DisplayItem], running: Bool) -> [ActivityTimelineRow] {
    var seen = Set<String>()
    let rows = items.enumerated().compactMap { index, item -> ActivityTimelineRow? in
        switch item {
        case .tool(let id, _, _, _, _, _):
            if !id.isEmpty && !seen.insert(id).inserted { return nil }
        case .plain(.thinking(let text, _, _, _)):
            if !keepThinkingRound(text: text, position: index, lastPosition: items.count - 1, running: running) { return nil }
        default: return nil
        }
        let key = displayItemIdentity(item) + (displayItemIdentity(item) == "thinking" ? ":\(index)" : "")
        return ActivityTimelineRow(position: index, item: item, occurredAt: activityOccurredAt(item), key: key)
    }
    return activityTimelineOrder(rows.map(\.occurredAt)).map { rows[$0] }
}

struct ActivityFoldCard: View {
    let group: ActivityGroup
    var baseURL: URL? = nil
    var isLastTurn = false
    var isResponding = false
    var timelinePolicyOverride: Bool? = nil
    var askSelections: [String: AskUserSelectionState] = [:]
    var onAskToggle: (String, Int, Int, Bool) -> Void = { _, _, _, _ in }
    var onAskSubmit: (String, String) -> Void = { _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatViewportHeight) private var viewportHeight
    @ObservedObject private var network = WandNetworkState.shared
    @AppStorage("wand.trafficTimelineMode") private var trafficMode = "wifi"
    @State private var expanded = false
    @State private var userToggled = false
    @State private var pinned = true
    @State private var inspecting = Set<String>()
    private var running: Bool { group.newest && isLastTurn && isResponding }
    private var rows: [ActivityTimelineRow] { activityTimelineRows(group.items, running: running) }
    private var autoExpanded: Bool { activityShouldAutoExpand(newest: group.newest, running: running, timelineEnabled: automaticTimeline) }
    private var liveToolID: String? {
        guard running else { return nil }
        return rows.reversed().compactMap { row -> String? in
            guard case .tool(let id, let name, _, let input, _, let result) = row.item,
                  ToolCallPresentation(name: name, input: input, result: result, sessionRunning: true).state == .running else { return nil }
            return id
        }.first
    }
    private var revision: String {
        rows.map { row in
            switch row.item {
            case .tool(_, _, _, _, _, let result): return row.key + ":" + (result?.text ?? "") + ":\(result?.isError == true)"
            case .plain(.thinking(let text, _, _, let lastAt)): return row.key + ":" + text + ":" + (lastAt ?? "")
            default: return row.key
            }
        }.joined(separator: "\u{0}")
    }
    private var automaticTimeline: Bool { timelinePolicyOverride ?? (trafficMode == "all" || network.wifi) }
    private var summary: String {
        var categories: [String: Set<String>] = [:]
        var seen = Set<String>(), thinking = 0
        for (index, item) in group.items.enumerated() {
            switch item {
            case .tool(let id, let name, _, let input, _, _):
                guard id.isEmpty || seen.insert(id).inserted else { continue }
                let kind = toolActivityKind(name: name, input: input)
                let file = input["__wandToolActivity"]?.objectValue?["fileKey"]?.stringValue
                    ?? input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? id
                categories[kind, default: []].insert(["read_file", "edit_file"].contains(kind) ? file : id.isEmpty ? "row-\(index)" : id)
            case .plain(.thinking(let text, _, _, _)):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { thinking += 1 }
            default: break
            }
        }
        var parts: [String] = []
        if let edits = categories["edit_file"], !edits.isEmpty { parts.append("修改 \(edits.count) 个文件") }
        if let reads = categories["read_file"], !reads.isEmpty { parts.append("查看 \(reads.count) 个文件") }
        if let commands = categories["run_command"], !commands.isEmpty { parts.append("运行 \(commands.count) 条命令") }
        if let other = categories["other"], !other.isEmpty { parts.append("其他 \(other.count) 次调用") }
        if thinking > 0 { parts.append("思考 \(thinking) 次") }
        if running { parts.append(rows.last.map { if case .plain(.thinking) = $0.item { return "思考中" }; return "运行中" } ?? "思考中") }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                userToggled = true
                withAnimation(activityWindowAnimation(reduceMotion)) { expanded.toggle() }
                if expanded { pinned = running }
            } label: {
                HStack(spacing: 8) {
                    if let time = rows.last?.occurredAt {
                        Text(SessionTimeFormatting.chatClock(iso: time)).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                    }
                    ZStack {
                        ProgressView().controlSize(.mini).tint(Theme.brand).opacity(running && !reduceMotion ? 1 : 0)
                        Circle().fill(running ? Theme.brand : Theme.success).frame(width: 6, height: 6).opacity(running && !reduceMotion ? 0 : 1)
                    }.frame(width: 12, height: 12)
                    Text(summary).font(.caption).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.caption).rotationEffect(.degrees(expanded ? 180 : 0))
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起工具时间线" : "展开工具时间线")
                .accessibilityValue(summary)
            if expanded && !rows.isEmpty { timeline }
        }
        .animation(activityWindowAnimation(reduceMotion), value: expanded)
        .onAppear { if !userToggled { expanded = autoExpanded } }
        .onChange(of: autoExpanded) { _, next in
            if !userToggled { withAnimation(activityWindowAnimation(reduceMotion)) { expanded = next } }
        }
    }
    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.key) { row in
                        ActivityTimelineEntry(row: row, thinkingOrdinal: rows.filter { item in
                            item.position <= row.position && { if case .plain(.thinking) = item.item { return true }; return false }()
                        }.count, thinkingTotal: rows.filter { if case .plain(.thinking) = $0.item { return true }; return false }.count,
                            active: running && (row.key == rows.last?.key || { if case .tool(let id, _, _, _, _, _) = row.item { return id == liveToolID }; return false }()),
                            baseURL: baseURL, onInspection: { open in if open { inspecting.insert(row.key) } else { inspecting.remove(row.key) } })
                    }
                    Color.clear.frame(height: 1).id("activity-tail")
                }
            }
            .frame(height: min(activityPanelHeight(viewportHeight: viewportHeight), max(120, CGFloat(rows.count) * 60)))
            .onScrollPhaseChange { _, phase in if phase == .interacting { pinned = false } }
            .onScrollGeometryChange(for: Bool.self) { $0.contentSize.height - ($0.contentOffset.y + $0.containerSize.height) < activityTailPin } action: { _, tail in pinned = tail }
            .onAppear { if pinned { proxy.scrollTo("activity-tail", anchor: .bottom) } }
            .onChange(of: revision) { _, _ in if pinned && inspecting.isEmpty { proxy.scrollTo("activity-tail", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                if !pinned { Button { pinned = true; proxy.scrollTo("activity-tail", anchor: .bottom) } label: { Image(systemName: "arrow.down").frame(width: 44, height: 44).background(Theme.surface, in: Circle()) }.accessibilityLabel("回到最新调用") }
            }
        }
    }
}

private struct ActivityTimelineEntry: View {
    let row: ActivityTimelineRow
    let thinkingOrdinal: Int
    let thinkingTotal: Int
    let active: Bool
    let baseURL: URL?
    let onInspection: (Bool) -> Void
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    private var thinking: String? { if case .plain(.thinking(let text, _, _, _)) = row.item { return text }; return nil }
    private var label: String {
        if thinking != nil { return "第 \(thinkingOrdinal)/\(thinkingTotal) 轮思考" }
        if case .tool(_, let name, _, let input, _, _) = row.item {
            return input["__wandToolActivity"]?.objectValue?["label"]?.stringValue ?? activityToolLabel(name: name, input: input)
        }
        return "工具调用"
    }
    private var preview: String {
        if let thinking { return thinking.isEmpty ? "思考内容尚未到达。" : thinking }
        if case .tool(_, _, let description, let input, _, let result) = row.item { return result?.text.isEmpty == false ? result!.text : activityToolSummary(description: description, input: input) }
        return ""
    }
    private var state: ToolCallState {
        if case .tool(_, let name, _, let input, _, let result) = row.item {
            return ToolCallPresentation(name: name, input: input, result: result, sessionRunning: active).state
        }
        return active ? .running : .completed
    }
    private var statusColor: Color {
        switch state {
        case .running: return Theme.brand
        case .failed: return Theme.danger
        case .completed: return Theme.success
        case .unreturned: return Theme.textMuted
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduced ? nil : WandMotion.stateSwap) { expanded.toggle() }
                onInspection(expanded)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(SessionTimeFormatting.chatClock(iso: row.occurredAt)).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary).frame(width: 64, alignment: .leading)
                    Circle().fill(statusColor).frame(width: 6, height: 6).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(String(preview.prefix(400))).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(thinking != nil ? 1 : 2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down").font(.caption).rotationEffect(.degrees(expanded ? 180 : 0))
                }.frame(minHeight: thinking != nil ? 44 : 78, alignment: .topLeading).padding(.vertical, 8).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(state.label + (expanded ? "，已展开" : "，已收起"))
            if expanded {
                if let thinking { Text(thinking.isEmpty ? "思考内容尚未到达。" : thinking).font(.subheadline).textSelection(.enabled).padding(.leading, 78) }
                else { ActivityTimelineToolDetail(item: row.item, baseURL: baseURL).padding(.leading, 78) }
            }
        }.overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1).offset(x: 75).allowsHitTesting(false) }
        .onDisappear { onInspection(false) }
    }
}

private struct ActivityTimelineToolDetail: View {
    let item: DisplayItem
    let baseURL: URL?
    @Environment(\.chatAPI) private var api
    @Environment(\.chatSessionID) private var sessionID
    @Environment(\.chatToolContentDidLoad) private var didLoad
    @State private var loaded: ToolContentResponse?
    @State private var error: String?
    @State private var loading = false
    @State private var retry = 0
    private var projectedItem: DisplayItem {
        guard let loaded, case .tool(let id, let name, let description, let input, let subagent, let result) = item else { return item }
        var merged = input
        for (key, value) in loaded.input { merged[key] = value }
        let fullResult = loaded.resultAvailable
            ? ToolResultInfo(toolUseId: id, text: loaded.text, isError: loaded.isError || result?.isError == true,
                truncated: false, images: loaded.images.isEmpty ? result?.images ?? [] : loaded.images,
                projection: mergingToolProjection(local: result?.projection, incoming: loaded.projection))
            : result
        return .tool(id: id, name: name, description: description, input: merged, subagent: subagent, result: fullResult)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if loading { Text("加载调用详情…").font(.caption).foregroundStyle(Theme.textSecondary) }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger); Button("重试") { retry += 1 } }
            AssistantItemView(item: projectedItem, baseURL: baseURL, showSubagentTags: false, forceExpanded: true)
                .environment(\.activityFoldCompact, true)
        }.task(id: retry) {
            guard let api, !sessionID.isEmpty, case .tool(let id, _, _, _, _, _) = item, !id.isEmpty else { return }
            loading = true; error = nil
            defer { loading = false }
            do {
                let result = try await api.fetchToolContent(id: sessionID, toolUseId: id)
                guard !Task.isCancelled, result.toolUseId == id else { return }
                loaded = result; didLoad?(result)
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}


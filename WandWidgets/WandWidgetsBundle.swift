import WidgetKit
import SwiftUI
import ActivityKit

/// WandWidgets 扩展：会话 Live Activity（灵动岛 + 锁屏长条）。
/// 所有活跃会话聚合在同一条活动里，条内逐会话显示缩略标题 + 状态。
/// 扩展与主 App 的 deployment target 均为 iOS 26，无需再做旧系统可用性守卫。
@main
struct WandWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivityWidget()
    }
}

/// 品牌色（Theme.swift 不参与扩展编译，这里独立一份常量）。
private enum WandColor {
    static let brand = Color(red: 0.851, green: 0.467, blue: 0.341)        // #D97757
    static let permission = Color.orange
    static let done = Color.green
}

private func stateTint(_ stateRaw: String) -> Color {
    switch stateRaw {
    case "permission": return WandColor.permission
    case "done": return WandColor.done
    default: return WandColor.brand
    }
}

private func sessionURL(_ id: String) -> URL {
    var components = URLComponents()
    components.scheme = "wand"
    components.host = "session"
    components.path = "/\(id)"
    return components.url ?? URL(string: "wand://session")!
}

struct SessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            // 锁屏 / 通知横幅：单行长条
            LockScreenStripView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Wand", systemImage: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(WandColor.brand)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AggregateStatusView(state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.sessions.count == 1, let only = context.state.sessions.first {
                        ConversationDetail(entry: only)
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(context.state.sessions.prefix(4), id: \.id) { entry in
                                SessionRow(entry: entry)
                            }
                            if context.state.sessions.count > 4 {
                                Text("还有 \(context.state.sessions.count - 4) 个会话…")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                    }
                }
            } compactLeading: {
                CompactLeadingMark()
            } compactTrailing: {
                CompactTrailingSummary(state: context.state)
            } minimal: {
                CompactMinimalMark(state: context.state)
            }
            .keylineTint(WandColor.brand)
        }
    }
}

private struct CompactLeadingMark: View {
    var body: some View {
        Text("W")
            .font(.system(size: 11, weight: .black))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(WandColor.brand))
    }
}

private struct CompactTrailingSummary: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        Text(summary)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(stateTint(state.aggregateStateRaw))
            .frame(minWidth: 22, minHeight: 20)
            .padding(.horizontal, 2)
            .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private var summary: String {
        if state.sessions.count > 1 { return "\(state.sessions.count)" }
        if state.queuedCount > 0 { return "+\(state.queuedCount)" }
        switch state.aggregateStateRaw {
        case "permission": return "待"
        case "done": return "完"
        default: return "答"
        }
    }
}

private struct CompactMinimalMark: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.aggregateSymbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(stateTint(state.aggregateStateRaw))
    }
}

private struct AggregateStatusView: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.aggregateSymbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(stateTint(state.aggregateStateRaw))
            if state.sessions.count == 1, let only = state.sessions.first {
                Text(only.statusText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(stateTint(only.stateRaw))
            } else {
                Text(aggregateText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
            }
        }
    }

    private var aggregateText: String {
        let permissionCount = state.sessions.filter(\.needsPermission).count
        let doneCount = state.sessions.filter(\.isDone).count
        if permissionCount > 0 {
            return "\(permissionCount) 个待授权"
        }
        if state.respondingCount > 0 {
            return "\(state.respondingCount) 个回复中"
        }
        return "\(doneCount) 个已完成"
    }
}

/// 单个对话回合展开后优先展示当前任务与排队消息，比重复一条聚合会话行更有用。
private struct ConversationDetail: View {
    let entry: SessionActivityAttributes.SessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(entry.providerText, systemImage: entry.providerSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WandColor.brand)
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                StatusBadge(entry: entry)
            }
            Text(detailText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if entry.needsPermission {
                    DetailPill(text: "待授权", systemImage: "lock.shield")
                }
                if entry.queuedCount > 0 {
                    DetailPill(text: "\(entry.queuedCount) 条排队", systemImage: "tray.full")
                }
                Spacer(minLength: 6)
                OpenSessionLink(entry: entry, compact: false)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var detailText: String {
        if let task = entry.taskTitle, !task.isEmpty { return task }
        if entry.needsPermission { return "需要你的确认后继续" }
        if entry.isDone { return "回复已完成" }
        return "正在生成回复…"
    }
}

/// 灵动岛展开态的单会话行：状态指示 + 缩略标题 + 当前任务 + 状态文字。
private struct SessionRow: View {
    let entry: SessionActivityAttributes.SessionEntry

    var body: some View {
        HStack(spacing: 7) {
            StatusIndicator(entry: entry, size: 11)
            Image(systemName: entry.providerSymbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(WandColor.brand)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(rowDetailText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.56))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            StatusBadge(entry: entry)
            OpenSessionIconLink(entry: entry)
        }
    }

    private var rowDetailText: String {
        if let task = entry.taskTitle, !task.isEmpty { return task }
        if entry.queuedCount > 0 { return "\(entry.queuedCount) 条消息排队" }
        return entry.statusText
    }
}

/// 锁屏 / 横幅：单行长条，左侧品牌图标，右侧逐会话小胶囊。
private struct LockScreenStripView: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(WandColor.brand)
            if state.sessions.count == 1, let only = state.sessions.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        StatusIndicator(entry: only, size: 10)
                        Text(only.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(only.statusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(stateTint(only.stateRaw))
                    }
                    Text(lockScreenDetailText(only))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                OpenSessionLink(entry: only, compact: true)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        AggregateStatusView(state: state)
                        if state.queuedCount > 0 {
                            Text("\(state.queuedCount) 条排队")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                    HStack(spacing: 5) {
                        ForEach(state.sessions.prefix(3), id: \.id) { entry in
                            SessionChip(entry: entry)
                        }
                        if state.sessions.count > 3 {
                            Text("+\(state.sessions.count - 3)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func lockScreenDetailText(_ entry: SessionActivityAttributes.SessionEntry) -> String {
        if let task = entry.taskTitle, !task.isEmpty { return task }
        if entry.needsPermission { return "需要确认权限请求" }
        if entry.isDone { return "回复已完成" }
        if entry.queuedCount > 0 { return "\(entry.queuedCount) 条消息排队" }
        return "正在生成回复"
    }
}

/// 单会话小胶囊：状态指示 + 缩略标题（+ 可选状态文字）。
private struct SessionChip: View {
    let entry: SessionActivityAttributes.SessionEntry
    var showsStatusText = false

    var body: some View {
        HStack(spacing: 5) {
            StatusIndicator(entry: entry, size: 10)
            Image(systemName: entry.providerSymbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(WandColor.brand)
            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(maxWidth: 76, alignment: .leading)
            if showsStatusText {
                Text(entry.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(stateTint(entry.stateRaw))
            }
            if entry.queuedCount > 0 {
                Text("+\(entry.queuedCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

/// 状态指示：运行中转小菊花，其余用 SF Symbol 着色。
private struct StatusIndicator: View {
    let entry: SessionActivityAttributes.SessionEntry
    var size: CGFloat = 10

    var body: some View {
        if entry.isResponding {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(WandColor.brand)
                .scaleEffect(size / 18)
                .frame(width: size, height: size)
        } else {
            Image(systemName: entry.statusSymbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(stateTint(entry.stateRaw))
        }
    }
}

private struct StatusBadge: View {
    let entry: SessionActivityAttributes.SessionEntry

    var body: some View {
        Text(entry.statusText)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(stateTint(entry.stateRaw))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(stateTint(entry.stateRaw).opacity(0.16)))
    }
}

private struct DetailPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white.opacity(0.66))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.10)))
    }
}

private struct OpenSessionLink: View {
    let entry: SessionActivityAttributes.SessionEntry
    var compact: Bool

    var body: some View {
        Link(destination: sessionURL(entry.id)) {
            Label(compact ? "打开" : "打开会话", systemImage: "arrow.up.forward")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, compact ? 8 : 10)
                .padding(.vertical, compact ? 5 : 6)
                .background(Capsule().fill(WandColor.brand))
        }
        .buttonStyle(.plain)
    }
}

private struct OpenSessionIconLink: View {
    let entry: SessionActivityAttributes.SessionEntry

    var body: some View {
        Link(destination: sessionURL(entry.id)) {
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(WandColor.brand.opacity(0.85)))
        }
        .buttonStyle(.plain)
    }
}

import WidgetKit
import SwiftUI
import ActivityKit

/// WandWidgets 扩展：会话 Live Activity（灵动岛 + 锁屏长条）。
/// 所有活跃会话聚合在同一条活动里，条内逐会话显示缩略标题 + 状态。
/// 扩展 deployment target 是 iOS 16.1，无需再做可用性守卫；
/// 主 App（iOS 15）侧的守卫在 SessionLiveActivityController 里。
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
                    if context.state.sessions.count == 1, let only = context.state.sessions.first {
                        Text(only.statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(stateTint(only.stateRaw))
                            .padding(.trailing, 4)
                    } else {
                        Text("\(context.state.sessions.count) 个会话")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.65))
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.sessions.count == 1, let only = context.state.sessions.first {
                        ConversationDetail(entry: only)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
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
                Image(systemName: context.state.sessions.count == 1
                    ? context.state.sessions[0].providerSymbol
                    : "wand.and.stars")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WandColor.brand)
            } compactTrailing: {
                HStack(spacing: 3) {
                    Image(systemName: context.state.aggregateSymbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(stateTint(context.state.aggregateStateRaw))
                    if context.state.sessions.count > 1 {
                        Text("\(context.state.sessions.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    } else if context.state.queuedCount > 0 {
                        Text("+\(context.state.queuedCount)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
            } minimal: {
                Image(systemName: context.state.aggregateSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(stateTint(context.state.aggregateStateRaw))
            }
            .keylineTint(WandColor.brand)
        }
    }
}

/// 单个对话回合展开后优先展示当前任务与排队消息，比重复一条聚合会话行更有用。
private struct ConversationDetail: View {
    let entry: SessionActivityAttributes.SessionEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label(entry.providerText, systemImage: entry.providerSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WandColor.brand)
                Text(entry.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                StatusIndicator(entry: entry, size: 11)
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if entry.queuedCount > 0 {
                    Label("\(entry.queuedCount) 条排队", systemImage: "tray.full")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                }
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
        HStack(spacing: 6) {
            StatusIndicator(entry: entry, size: 11)
            Image(systemName: entry.providerSymbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(WandColor.brand)
            Text(entry.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if let task = entry.taskTitle, !task.isEmpty {
                Text(task)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(entry.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(stateTint(entry.stateRaw))
        }
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
                VStack(alignment: .leading, spacing: 3) {
                    SessionChip(entry: only, showsStatusText: true)
                    if let task = only.taskTitle, !task.isEmpty {
                        Text(task)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                            .padding(.leading, 9)
                    }
                }
            } else {
                ForEach(state.sessions.prefix(3), id: \.id) { entry in
                    SessionChip(entry: entry)
                }
                if state.sessions.count > 3 {
                    Text("+\(state.sessions.count - 3)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

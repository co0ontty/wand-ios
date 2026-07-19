import WidgetKit
import SwiftUI
import ActivityKit

@main
struct WandWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivityWidget()
    }
}

private enum ActivityTint {
    static let brand = Color(red: 0.851, green: 0.467, blue: 0.341)

    static func color(for state: String) -> Color {
        switch state {
        case "permission": return .orange
        case "done": return .green
        default: return .white
        }
    }
}

private func sessionURL(_ id: String) -> URL {
    URL(string: "wand://session/\(id)")!
}

private let activityListURL = URL(string: "wand://live-activity")!

private func activityURL(_ state: SessionActivityAttributes.ContentState) -> URL {
    guard state.sessions.count == 1, let session = state.primarySession else { return activityListURL }
    return sessionURL(session.id)
}

struct SessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state, isStale: context.isStale)
                .widgetURL(activityURL(context.state))
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                expandedContent(state: context.state, isStale: context.isStale)
            } compactLeading: {
                CompactIdentity(state: context.state)
            } compactTrailing: {
                CompactStatus(state: context.state)
            } minimal: {
                MinimalStatus(state: context.state)
            }
            .widgetURL(activityURL(context.state))
            .keylineTint(ActivityTint.brand)
        }
    }

    @DynamicIslandExpandedContentBuilder
    private func expandedContent(
        state: SessionActivityAttributes.ContentState,
        isStale: Bool
    ) -> DynamicIslandExpandedContent<some View> {
        DynamicIslandExpandedRegion(.leading) {
            if let primary = state.primarySession {
                Image(systemName: primary.providerSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(primary.providerText)
            }
        }
        DynamicIslandExpandedRegion(.trailing) {
            ExpandedMetric(state: state, isStale: isStale)
        }
        DynamicIslandExpandedRegion(.bottom) {
            ExpandedActivityView(state: state, isStale: isStale)
        }
    }
}

private struct CompactIdentity: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.primarySession?.providerSymbol ?? "wand.and.stars")
            .foregroundStyle(ActivityTint.brand)
            .accessibilityLabel(state.primarySession?.providerText ?? "Wand")
    }
}

private struct CompactStatus: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        let primary = state.primarySession
        HStack(spacing: 3) {
            Image(systemName: state.aggregateSymbol)
            if state.permissionCount > 0 {
                Text(state.permissionCount == 1 ? "处理" : "\(state.permissionCount)")
            } else if state.sessions.count > 1 {
                Text("\(state.sessions.count)")
            } else if let startedAt = primary?.startedAt, primary?.isResponding == true {
                Text(startedAt, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 42)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(ActivityTint.color(for: state.aggregateStateRaw))
        .accessibilityLabel(accessibilityText(primary: primary, state: state))
    }
}

private struct ExpandedMetric: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isStale {
                Image(systemName: "wifi.exclamationmark")
                Text("已暂停")
            } else if state.permissionCount > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                Text("需授权")
            } else if state.respondingCount == 1,
                      let startedAt = state.primarySession?.startedAt {
                Text(startedAt, style: .timer)
                    .monospacedDigit()
            } else if state.respondingCount > 0 {
                Text("\(state.respondingCount) 项")
            } else {
                Image(systemName: "checkmark")
                Text("完成")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isStale ? .secondary : ActivityTint.color(for: state.aggregateStateRaw))
    }
}

private struct MinimalStatus: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.aggregateSymbol)
            .foregroundStyle(ActivityTint.color(for: state.aggregateStateRaw))
            .accessibilityLabel(accessibilityText(primary: state.primarySession, state: state))
    }
}

private struct AggregateStatus: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.aggregateSymbol)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(ActivityTint.color(for: state.aggregateStateRaw))
    }

    private var text: String {
        if state.permissionCount > 0 { return "\(state.permissionCount) 待授权" }
        if state.respondingCount > 0 { return "\(state.respondingCount) 进行中" }
        return "已完成"
    }
}

private struct ExpandedActivityView: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let primary = state.primarySession {
                Link(destination: sessionURL(primary.id)) {
                    ExpandedTaskSummary(entry: primary, isStale: isStale)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, -2)
    }
}

private struct ExpandedTaskSummary: View {
    let entry: SessionActivityAttributes.SessionEntry
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Text(entry.primaryDetail)
                    .lineLimit(1)
                if entry.queuedCount > 0 {
                    Text("·")
                    Text("\(entry.queuedCount) 条排队")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(entry.needsPermission ? .orange : .secondary)
        }
        .opacity(isStale ? 0.68 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.providerText)，\(entry.title)，\(entry.primaryDetail)")
    }
}

private struct LockScreenActivityView: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let primary = state.primarySession {
                    Label(primary.providerText, systemImage: primary.providerSymbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AggregateStatus(state: state)
            }
            if let primary = state.primarySession {
                Link(destination: sessionURL(primary.id)) {
                    PrimaryActivityCard(entry: primary, isStale: isStale)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                if state.sessions.count > 1 {
                    Link(destination: activityListURL) {
                        Label("查看全部 \(state.sessions.count) 个", systemImage: "rectangle.stack")
                    }
                }
                Spacer(minLength: 0)
                if let primary = state.primarySession {
                    Link(destination: sessionURL(primary.id)) {
                        Label(primary.needsPermission ? "处理授权" : "打开会话", systemImage: "arrow.up.right")
                    }
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(ActivityTint.color(for: state.aggregateStateRaw))
            StaleNotice(isStale: isStale, updatedAt: state.updatedAt)
        }
        .padding(.vertical, 4)
    }
}

private struct PrimaryActivityCard: View {
    let entry: SessionActivityAttributes.SessionEntry
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.statusSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ActivityTint.color(for: entry.stateRaw))
                .frame(width: 24)
                .symbolEffect(.pulse, options: .repeating, isActive: entry.isResponding && !isStale)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entry.primaryDetail)
                    .font(.subheadline)
                    .foregroundStyle(entry.needsPermission ? .primary : .secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let startedAt = entry.startedAt, entry.isResponding {
                        Label {
                            Text(startedAt, style: .timer).monospacedDigit()
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                    if entry.queuedCount > 0 {
                        Label("\(entry.queuedCount) 条排队", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .opacity(isStale ? 0.72 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var components = [entry.providerText, entry.title, entry.statusText, entry.primaryDetail]
        if entry.queuedCount > 0 { components.append("\(entry.queuedCount) 条消息等待处理") }
        if isStale { components.append("状态可能已过期") }
        return components.joined(separator: "，")
    }
}

private struct SecondarySummary: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack")
            Text("另有 \(state.sessions.count - 1) 个会话")
            Spacer(minLength: 0)
            if state.permissionCount > (state.primarySession?.needsPermission == true ? 1 : 0) {
                Text("含待授权")
                    .foregroundStyle(.orange)
            } else if state.respondingCount > (state.primarySession?.isResponding == true ? 1 : 0) {
                Text("仍在进行")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

private struct StaleNotice: View {
    let isStale: Bool
    let updatedAt: Date

    var body: some View {
        if isStale {
            Label {
                Text("状态可能已过期 · ") + Text(updatedAt, style: .relative)
            } icon: {
                Image(systemName: "wifi.exclamationmark")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("状态可能已过期，最后更新于 \(updatedAt.formatted())")
        }
    }
}

#if DEBUG
private enum ActivityPreviewFixtures {
    static let now = Date()
    static let active = SessionActivityAttributes.SessionEntry(
        id: "preview-active", title: "优化 Wand 锁屏体验", providerRaw: "codex",
        stateRaw: "responding", taskTitle: "重构灵动岛信息层级与交互",
        queuedCount: 2, startedAt: now.addingTimeInterval(-94)
    )
    static let permission = SessionActivityAttributes.SessionEntry(
        id: "preview-permission", title: "发布检查清单", providerRaw: "claude",
        stateRaw: "permission", taskTitle: "需要确认读取截图目录", queuedCount: 0
    )
    static let done = SessionActivityAttributes.SessionEntry(
        id: "preview-done", title: "回归测试", providerRaw: "opencode",
        stateRaw: "done", taskTitle: nil, queuedCount: 0
    )
    static let multi = SessionActivityAttributes.ContentState(
        sessions: [permission, active, done], updatedAt: now
    )
}

#Preview("Lock Screen · Multi") {
    LockScreenActivityView(state: ActivityPreviewFixtures.multi, isStale: false)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}

#Preview("Lock Screen · Stale") {
    LockScreenActivityView(state: ActivityPreviewFixtures.multi, isStale: true)
        .padding()
        .background(.black)
        .preferredColorScheme(.dark)
}
#endif

private func accessibilityText(
    primary: SessionActivityAttributes.SessionEntry?,
    state: SessionActivityAttributes.ContentState
) -> String {
    if state.permissionCount > 0 { return "Wand，\(state.permissionCount) 个会话等待授权" }
    if state.respondingCount > 0 { return "Wand，\(state.respondingCount) 个会话正在进行" }
    if let primary { return "Wand，\(primary.title) 已完成" }
    return "Wand 会话已完成"
}

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
        default: return brand
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
                .activityBackgroundTint(.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                expandedContent(state: context.state, isStale: context.isStale)
            } compactLeading: {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(ActivityTint.brand)
                    .accessibilityLabel("Wand")
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
            Label("Wand", systemImage: "wand.and.stars")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ActivityTint.brand)
        }
        DynamicIslandExpandedRegion(.trailing) {
            AggregateStatus(state: state)
        }
        DynamicIslandExpandedRegion(.bottom) {
            ExpandedActivityView(state: state, isStale: isStale)
        }
    }
}

private struct CompactStatus: View {
    let state: SessionActivityAttributes.ContentState

    var body: some View {
        let primary = state.primarySession
        HStack(spacing: 3) {
            Image(systemName: state.aggregateSymbol)
            if state.permissionCount > 1 {
                Text("\(state.permissionCount)")
            } else if state.permissionCount == 0, state.sessions.count > 1 {
                Text("\(state.sessions.count)")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(ActivityTint.color(for: state.aggregateStateRaw))
        .accessibilityLabel(accessibilityText(primary: primary, state: state))
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
        VStack(alignment: .leading, spacing: 10) {
            if let primary = state.primarySession {
                Link(destination: sessionURL(primary.id)) {
                    ActivitySessionRow(entry: primary, prominent: true, isStale: isStale)
                }
                .buttonStyle(.plain)
            }
            let secondary = state.sessions.filter { $0.id != state.primarySession?.id }.prefix(2)
            ForEach(secondary, id: \.id) { entry in
                Link(destination: sessionURL(entry.id)) {
                    ActivitySessionRow(entry: entry, prominent: false, isStale: isStale)
                }
                .buttonStyle(.plain)
            }
            if state.sessions.count > 3 {
                Link("查看另外 \(state.sessions.count - 3) 个会话", destination: activityListURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}

private struct LockScreenActivityView: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Wand", systemImage: "wand.and.stars")
                    .font(.headline)
                    .foregroundStyle(ActivityTint.brand)
                Spacer()
                AggregateStatus(state: state)
            }
            if let primary = state.primarySession {
                Link(destination: sessionURL(primary.id)) {
                    ActivitySessionRow(entry: primary, prominent: true, isStale: isStale)
                }
                .buttonStyle(.plain)
            }
            let secondary = state.sessions.filter { $0.id != state.primarySession?.id }.prefix(1)
            ForEach(secondary, id: \.id) { entry in
                Link(destination: sessionURL(entry.id)) {
                    ActivitySessionRow(entry: entry, prominent: false, isStale: isStale)
                }
                .buttonStyle(.plain)
            }
            if state.sessions.count > 2 {
                Link("查看全部 \(state.sessions.count) 个会话", destination: activityListURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ActivitySessionRow: View {
    let entry: SessionActivityAttributes.SessionEntry
    let prominent: Bool
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: entry.statusSymbol)
                .font(prominent ? .headline : .subheadline)
                .foregroundStyle(ActivityTint.color(for: entry.stateRaw))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.title)
                        .font(prominent ? .headline : .subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(entry.statusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ActivityTint.color(for: entry.stateRaw))
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(prominent ? 2 : 1)
            }
            Spacer(minLength: 0)
        }
        .opacity(isStale ? 0.58 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.title)，\(entry.statusText)，\(detail)")
    }

    private var detail: String {
        if entry.needsPermission { return "需要你的确认后继续" }
        if let task = entry.taskTitle, !task.isEmpty { return task }
        if entry.queuedCount > 0 { return "\(entry.queuedCount) 条消息等待处理" }
        if entry.isDone { return "回复已完成" }
        return "正在生成回复"
    }
}

private func accessibilityText(
    primary: SessionActivityAttributes.SessionEntry?,
    state: SessionActivityAttributes.ContentState
) -> String {
    if state.permissionCount > 0 { return "Wand，\(state.permissionCount) 个会话等待授权" }
    if state.respondingCount > 0 { return "Wand，\(state.respondingCount) 个会话正在进行" }
    if let primary { return "Wand，\(primary.title) 已完成" }
    return "Wand 会话已完成"
}

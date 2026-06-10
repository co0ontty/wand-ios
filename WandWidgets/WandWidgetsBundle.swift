import WidgetKit
import SwiftUI
import ActivityKit

/// WandWidgets 扩展：会话 Live Activity（灵动岛 + 锁屏横幅）。
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

private func stateTint(for state: SessionActivityAttributes.ContentState) -> Color {
    if state.needsPermission { return WandColor.permission }
    if state.isDone { return WandColor.done }
    return WandColor.brand
}

struct SessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            // 锁屏 / 通知横幅
            LockScreenActivityView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(WandColor.brand)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusBadge(context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.sessionTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let task = context.state.taskTitle, !task.isEmpty {
                        Text(task)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                    }
                }
            } compactLeading: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WandColor.brand)
            } compactTrailing: {
                Image(systemName: context.state.statusSymbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(stateTint(for: context.state))
            } minimal: {
                Image(systemName: context.state.statusSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(stateTint(for: context.state))
            }
            .keylineTint(WandColor.brand)
        }
    }

    @ViewBuilder
    private func statusBadge(_ state: SessionActivityAttributes.ContentState) -> some View {
        HStack(spacing: 5) {
            if state.isResponding {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(WandColor.brand)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: state.statusSymbol)
                    .font(.system(size: 13, weight: .medium))
            }
            Text(state.statusText)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(stateTint(for: state))
    }
}

/// 锁屏 / 横幅样式：图标 + 会话标题 + 状态行。
private struct LockScreenActivityView: View {
    let context: ActivityViewContext<SessionActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(WandColor.brand)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.sessionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: context.state.statusSymbol)
                        .font(.system(size: 11, weight: .medium))
                    Text(context.state.statusText)
                        .font(.system(size: 12, weight: .medium))
                    if let task = context.state.taskTitle, !task.isEmpty {
                        Text("· \(task)")
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                }
                .foregroundColor(stateTint(for: context.state))
            }
            Spacer(minLength: 0)
            if context.state.isResponding {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(WandColor.brand)
            }
        }
        .padding(14)
    }
}

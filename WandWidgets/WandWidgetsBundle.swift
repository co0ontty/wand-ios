import WidgetKit
import SwiftUI
import ActivityKit

@main
struct WandWidgetsBundle: WidgetBundle {
    var body: some Widget { SessionLiveActivityWidget() }
}

struct SessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            ActivityLockScreenView(state: context.state, isStale: context.isStale)
                .widgetURL(context.state.destinationURL)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityExpandedIdentity(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityExpandedMetric(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityExpandedSummary(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                ActivityCompactIdentity(state: context.state, isStale: context.isStale)
            } compactTrailing: {
                ActivityCompactStatus(state: context.state, isStale: context.isStale)
            } minimal: {
                ActivityMinimalStatus(state: context.state, isStale: context.isStale)
            }
            // The system already insets the expanded island; only horizontal breathing room is
            // added here so the card never grows taller than its content needs.
            .contentMargins(.horizontal, ActivityLayout.expandedInset, for: .expanded)
            .widgetURL(context.state.destinationURL)
            .keylineTint(context.isStale ? .gray : ActivityPresentation.tint(context.state.aggregateStateRaw))
        }
    }
}

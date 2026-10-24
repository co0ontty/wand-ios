import SwiftUI

/// ActivityKit supplies the black system surface and clipping mask; these tokens
/// describe content rhythm only, shared by WidgetKit and the native layout tests.
enum ActivityLayout {
    static let inset: CGFloat = 16
    /// The system already reserves room around the expanded island, so its content only needs a
    /// single rhythm; two stacked 16pt paddings pushed the card into the camera cutout.
    static let expandedInset: CGFloat = 12
    /// Secondary rows inside the island are read, not aimed at: 32pt keeps them tappable without
    /// spending the height a full 44pt target would cost.
    static let islandRow: CGFloat = 32
    static let group: CGFloat = 12
    static let related: CGFloat = 4
    static let identity: CGFloat = 18
    static let symbol: CGFloat = 12
    static let touch: CGFloat = 44
}

enum ActivityPresentation {
    static let accent = Color(red: 0x63 / 255, green: 0xb4 / 255, blue: 1)
    static let quiet = Color.white.opacity(0.66)
    static func tint(_ state: String) -> Color {
        switch state {
        case "permission", "waiting-input": return .orange
        case "failed": return .red
        case "done": return .green
        case "stopped": return quiet
        default: return accent
        }
    }
    static func accessibility(_ state: SessionActivityAttributes.ContentState, isStale: Bool) -> String {
        if isStale { return "Wand，状态已过期，打开应用重新连接" }
        return "Wand，" + state.aggregateText
    }
    static func status(_ state: SessionActivityAttributes.ContentState, isStale: Bool) -> String {
        if isStale { return "已过期" }
        if state.attentionCount > 1 { return "\(state.attentionCount) 项待处理" }
        return state.primarySession?.statusText ?? "已完成"
    }
    static func detail(_ entry: SessionActivityAttributes.SessionEntry, isStale: Bool) -> String {
        if isStale { return "打开 Wand 重新连接" }
        return entry.primaryDetail
    }
    /// Island variant: the capsule already carries the status, so this is nil unless there is
    /// real task content worth a second line.
    static func focusDetail(_ entry: SessionActivityAttributes.SessionEntry, isStale: Bool) -> String? {
        isStale ? nil : entry.focusDetail
    }
}

struct ActivityCompactIdentity: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        Image("WandLogo").renderingMode(.original).resizable().scaledToFit()
            .frame(width: ActivityLayout.identity, height: ActivityLayout.identity)
            .opacity(isStale ? 0.55 : 1).accessibilityLabel("Wand")
    }
}

struct ActivityCompactStatus: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        HStack(spacing: ActivityLayout.related) {
            Image(systemName: isStale ? "wifi.exclamationmark" : state.aggregateSymbol)
                .font(.system(size: ActivityLayout.symbol, weight: .semibold))
                .frame(width: 14)
            Text(state.compactText(isStale: isStale))
                .font(.caption2.weight(.medium)).monospacedDigit().lineLimit(1)
        }.foregroundStyle(isStale ? ActivityPresentation.quiet : ActivityPresentation.tint(state.aggregateStateRaw))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ActivityPresentation.accessibility(state, isStale: isStale))
    }
}

struct ActivityMinimalStatus: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        Image(systemName: isStale ? "wifi.exclamationmark" : state.aggregateSymbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isStale ? ActivityPresentation.quiet : ActivityPresentation.tint(state.aggregateStateRaw))
            .accessibilityLabel(ActivityPresentation.accessibility(state, isStale: isStale))
    }
}

struct ActivityExpandedIdentity: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        HStack(spacing: 6) {
            ActivityCompactIdentity(state: state, isStale: isStale)
            Text(state.primarySession?.providerText ?? "Wand")
                .font(.caption.weight(.medium)).foregroundStyle(ActivityPresentation.quiet).lineLimit(1)
        }
    }
}

private struct ActivityStateLabel: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isStale ? "wifi.exclamationmark" : state.aggregateSymbol)
                .font(.system(size: 10, weight: .semibold))
            Text(ActivityPresentation.status(state, isStale: isStale))
                .font(.caption.weight(.semibold)).lineLimit(1).monospacedDigit()
        }
        .foregroundStyle(isStale ? ActivityPresentation.quiet : ActivityPresentation.tint(state.aggregateStateRaw))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .glassEffect(.regular.tint((isStale ? Color.white : ActivityPresentation.tint(state.aggregateStateRaw)).opacity(0.12)), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActivityPresentation.accessibility(state, isStale: isStale))
    }
}

struct ActivityExpandedMetric: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        // Duration stays a supporting fact: bounded text, and it only appears when a single session
        // is running. Attention states and multi-session headers spend that width on the capsule.
        if !isStale, state.sessions.count == 1, let entry = state.primarySession,
           entry.isResponding, let started = entry.startedAt {
            HStack(spacing: 5) {
                Circle().fill(ActivityPresentation.accent).frame(width: 5, height: 5)
                ActivityElapsedLabel(startedAt: started)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ActivityPresentation.accent)
                    .frame(maxWidth: 58, alignment: .trailing)
            }.accessibilityLabel("本轮运行时长")
        } else {
            ActivityStateLabel(state: state, isStale: isStale)
        }
    }
}

/// Bounded elapsed time shared by the island and the lock screen. A raw `Text(style: .timer)`
/// keeps growing (238:58:42) and steals width from the status next to it, so the system timer is
/// only used while it still fits (`59:59`). Past an hour the bounded label takes over; the host
/// refreshes content at least once a minute, so the switch lands on the next update.
struct ActivityElapsedLabel: View {
    let startedAt: Date
    var body: some View {
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < 3_600 {
            Text(startedAt, style: .timer).monospacedDigit().lineLimit(1)
        } else {
            Text(activityElapsedText(elapsed)).monospacedDigit().lineLimit(1)
        }
    }
}

/// The same native header is rendered by the real system regions and the QA gallery.
struct ActivityExpandedHeader: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        HStack(alignment: .center) {
            ActivityExpandedIdentity(state: state, isStale: isStale)
            Spacer(minLength: 8)
            ActivityExpandedMetric(state: state, isStale: isStale)
        }
    }
}

private struct ActivityPrimaryLink: View {
    let entry: SessionActivityAttributes.SessionEntry
    let isStale: Bool
    let compact: Bool
    /// Island rows skip the duplicated status sentence: a title plus a capsule is the whole budget.
    private var detail: String? {
        compact
            ? ActivityPresentation.focusDetail(entry, isStale: isStale)
            : ActivityPresentation.detail(entry, isStale: isStale)
    }
    var body: some View {
        Link(destination: entry.destinationURL) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: ActivityLayout.related) {
                    Text(entry.title).font(compact ? .subheadline.weight(.semibold) : .headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true).privacySensitive()
                    if let detail {
                        Text(detail)
                            .font(compact ? .caption : .subheadline).foregroundStyle(ActivityPresentation.quiet)
                            .lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true).privacySensitive()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.36)).accessibilityHidden(true)
            }.frame(minHeight: ActivityLayout.touch).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(entry.title)，\(entry.statusText)，打开会话")
    }
}

private struct ActivityOtherSessions: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        let others = state.activeSecondarySessions
        if !others.isEmpty {
            HStack(spacing: 8) {
                if let secondary = others.min(by: { $0.priority < $1.priority }) {
                    Link(destination: secondary.destinationURL) {
                        HStack(spacing: 6) {
                            Circle().fill(isStale ? ActivityPresentation.quiet : ActivityPresentation.tint(secondary.stateRaw))
                                .frame(width: 5, height: 5)
                            Text(secondary.title).lineLimit(1).truncationMode(.middle).privacySensitive()
                            // One extra session keeps its own state; listing it without it looks identical
                            // to the primary row and hides whether the other session is the one waiting.
                            if secondary.needsAttention {
                                Text(secondary.statusText).lineLimit(1)
                                    .foregroundStyle(ActivityPresentation.tint(secondary.stateRaw))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: ActivityLayout.islandRow)
                    }.buttonStyle(.plain).foregroundStyle(ActivityPresentation.quiet)
                        .accessibilityLabel("另一个会话，\(secondary.title)，\(secondary.statusText)")
                }
                Link(destination: URL(string: "wand://live-activity")!) {
                    HStack(spacing: 3) {
                        Text("全部 \(state.sessions.count)").monospacedDigit()
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }.frame(minHeight: ActivityLayout.islandRow)
                }.buttonStyle(.plain).foregroundStyle(ActivityPresentation.accent)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("查看全部 \(state.sessions.count) 个会话")
            }.font(.caption.weight(.medium))
        }
    }
}

struct ActivityExpandedSummary: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: ActivityLayout.group) {
            if let primary = state.primarySession {
                ActivityPrimaryLink(entry: primary, isStale: isStale, compact: true)
            }
            if !state.activeSecondarySessions.isEmpty {
                ActivityOtherSessions(state: state, isStale: isStale)
            }
        }.opacity(isStale ? 0.72 : 1)
    }
}

struct ActivityLockScreenView: View {
    let state: SessionActivityAttributes.ContentState
    let isStale: Bool
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        VStack(alignment: .leading, spacing: ActivityLayout.group) {
            header
            if let primary = state.primarySession {
                ActivityPrimaryLink(entry: primary, isStale: isStale, compact: false)
                metadata(primary)
            }
            if !state.activeSecondarySessions.isEmpty {
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5).accessibilityHidden(true)
                ActivityOtherSessions(state: state, isStale: isStale)
            }
        }.padding(ActivityLayout.inset)
            .accessibilityElement(children: .contain)
    }
    @ViewBuilder private var header: some View {
        if textSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                brand
                ActivityStateLabel(state: state, isStale: isStale)
            }
        } else {
            HStack {
                brand
                Spacer(minLength: 8)
                ActivityStateLabel(state: state, isStale: isStale)
            }
        }
    }
    private var brand: some View {
        HStack(spacing: 6) {
            ActivityCompactIdentity(state: state, isStale: isStale)
            Text("Wand").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        }
    }
    private func metadata(_ entry: SessionActivityAttributes.SessionEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.providerText).lineLimit(1)
            if entry.isResponding, !isStale, let started = entry.startedAt {
                Text("·").accessibilityHidden(true)
                ActivityElapsedLabel(startedAt: started)
            }
            if entry.queuedCount > 0 && !entry.isFinished {
                Text("·").accessibilityHidden(true)
                Text("\(entry.queuedCount) 条排队").lineLimit(1)
            }
            Spacer(minLength: 0)
        }.font(.caption).foregroundStyle(ActivityPresentation.quiet)
    }
}

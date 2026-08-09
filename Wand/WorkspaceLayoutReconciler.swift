import Foundation

struct WorkspaceLayoutReconciler {
    private struct NormalizedNode {
        let node: LayoutNode
        let extras: [PaneTab]
    }

    static func orderedSessions(
        _ sessions: [WorkspaceSessionSummary]
    ) -> [WorkspaceSessionSummary] {
        sessions.enumerated().sorted { left, right in
            let leftDate = left.element.startedAt.flatMap(SessionTimeFormatting.date(from:))
            let rightDate = right.element.startedAt.flatMap(SessionTimeFormatting.date(from:))
            switch (leftDate, rightDate) {
            case (.some(let lhs), .some(let rhs)) where lhs != rhs:
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return left.offset < right.offset
            }
        }.map(\.element)
    }

    static func reconcile(
        persisted: TaskWindowLayout?,
        sessionIds validSessionIds: [String],
        preferredSessionId: String?
    ) -> TaskWindowLayout {
        let validSessions = Set(validSessionIds)
        var seenTabs = Set<String>()
        var seenSessions = Set<String>()
        var usedWindowIds = Set<String>()
        var windows: [WorkWindowLayout] = []

        for source in persisted?.windows ?? [] {
            let normalized = normalize(
                source.layout,
                validSessions: validSessions,
                seenTabs: &seenTabs,
                seenSessions: &seenSessions
            )
            if !tabs(in: normalized.node).isEmpty {
                let id = uniqueWindowId(source.id, used: &usedWindowIds)
                let active = activeTab(in: normalized.node, preferredId: source.activeTabId)
                windows.append(WorkWindowLayout(
                    id: id,
                    layout: normalized.node,
                    activeTabId: active?.id
                ))
            }
            for tab in normalized.extras {
                let id = uniqueWindowId(windowId(for: tab), used: &usedWindowIds)
                windows.append(WorkWindowLayout(
                    id: id,
                    layout: .pane(tabs: [tab], active: 0),
                    activeTabId: tab.id
                ))
            }
        }

        for sessionId in validSessionIds where !seenSessions.contains(sessionId) {
            let tab = PaneTab.session(id: "tab-\(sessionId)", sessionId: sessionId)
            seenTabs.insert(tab.id)
            seenSessions.insert(sessionId)
            let id = uniqueWindowId(windowId(for: tab), used: &usedWindowIds)
            windows.append(WorkWindowLayout(
                id: id,
                layout: .pane(tabs: [tab], active: 0),
                activeTabId: tab.id
            ))
        }

        let preferredWindow = preferredSessionId.flatMap { preferred in
            windows.first { sessionIds(in: $0.layout).contains(preferred) }
        }
        let persistedActive = windows.first { $0.id == persisted?.activeWindowId }
        return TaskWindowLayout(
            windows: windows,
            activeWindowId: preferredWindow?.id ?? persistedActive?.id ?? windows.first?.id
        )
    }

    static func activeSessionId(
        in layout: TaskWindowLayout?,
        validSessionIds: [String]
    ) -> String? {
        guard let layout else { return validSessionIds.first }
        let valid = Set(validSessionIds)
        let window = layout.windows.first { $0.id == layout.activeWindowId }
            ?? layout.windows.first
        if let window {
            if let tab = activeTab(in: window.layout, preferredId: window.activeTabId),
               let sessionId = tab.sessionId,
               valid.contains(sessionId) {
                return sessionId
            }
            if let sessionId = sessionIds(in: window.layout).first(where: valid.contains) {
                return sessionId
            }
        }
        return validSessionIds.first
    }

    static func tabs(in node: LayoutNode) -> [PaneTab] {
        switch node {
        case .pane(let tabs, _):
            return tabs
        case .split(_, _, let first, let second):
            return tabs(in: first) + tabs(in: second)
        }
    }

    static func sessionIds(in node: LayoutNode) -> [String] {
        tabs(in: node).compactMap(\.sessionId)
    }

    private static func activeTab(in node: LayoutNode, preferredId: String?) -> PaneTab? {
        if let preferredId,
           let preferred = tabs(in: node).first(where: { $0.id == preferredId }) {
            return preferred
        }
        switch node {
        case .pane(let tabs, let active):
            return tabs.indices.contains(active) ? tabs[active] : tabs.first
        case .split(_, _, let first, let second):
            return activeTab(in: first, preferredId: nil)
                ?? activeTab(in: second, preferredId: nil)
        }
    }

    private static func normalize(
        _ node: LayoutNode,
        validSessions: Set<String>,
        seenTabs: inout Set<String>,
        seenSessions: inout Set<String>
    ) -> NormalizedNode {
        switch node {
        case .pane(let sourceTabs, let activeIndex):
            let valid = sourceTabs.filter { tab in
                guard seenTabs.insert(tab.id).inserted else { return false }
                if let sessionId = tab.sessionId {
                    guard validSessions.contains(sessionId),
                          seenSessions.insert(sessionId).inserted else { return false }
                }
                return true
            }
            guard !valid.isEmpty else {
                return NormalizedNode(node: .pane(tabs: [], active: 0), extras: [])
            }
            let requested = sourceTabs.indices.contains(activeIndex) ? sourceTabs[activeIndex] : nil
            let kept = requested.flatMap { item in valid.first(where: { $0.id == item.id }) }
                ?? valid[0]
            return NormalizedNode(
                node: .pane(tabs: [kept], active: 0),
                extras: valid.filter { $0.id != kept.id }
            )

        case .split(let direction, let ratio, let first, let second):
            let left = normalize(
                first,
                validSessions: validSessions,
                seenTabs: &seenTabs,
                seenSessions: &seenSessions
            )
            let right = normalize(
                second,
                validSessions: validSessions,
                seenTabs: &seenTabs,
                seenSessions: &seenSessions
            )
            let leftEmpty = tabs(in: left.node).isEmpty
            let rightEmpty = tabs(in: right.node).isEmpty
            let extras = left.extras + right.extras
            if leftEmpty && rightEmpty {
                return NormalizedNode(node: left.node, extras: extras)
            }
            if leftEmpty { return NormalizedNode(node: right.node, extras: extras) }
            if rightEmpty { return NormalizedNode(node: left.node, extras: extras) }
            return NormalizedNode(
                node: .split(
                    direction: direction,
                    ratio: ratio,
                    first: left.node,
                    second: right.node
                ),
                extras: extras
            )
        }
    }

    private static func windowId(for tab: PaneTab) -> String {
        if let sessionId = tab.sessionId { return "window-\(sessionId)" }
        return "window-\(tab.id)"
    }

    private static func uniqueWindowId(_ base: String, used: inout Set<String>) -> String {
        let normalized = base.isEmpty ? "window" : base
        var candidate = normalized
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(normalized)-\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }
}

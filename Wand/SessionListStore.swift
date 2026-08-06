import Foundation
import Combine

protocol SessionListServing: AnyObject {
    func fetchSessionList(offset: Int, limit: Int, revision: String?) async throws -> SessionListPage
    func fetchSessionDirectories() async throws -> SessionDirectoryTreeResponse
    func renameSessionDirectory(path: String, name: String) async throws
    func resumeHistory(_ history: HistorySession) async throws -> SessionSnapshot
    func deleteSession(id: String) async throws
    func deleteHistoryBatch(provider: String, ids: [String]) async throws
    /// Presence/notification reconciliation needs the complete managed set, not a paginated
    /// session-list window whose absent rows may still be active on the server.
    func fetchManagedSessionsForPresence() async throws -> [SessionSnapshot]
}

extension WandAPI: SessionListServing {
    func fetchManagedSessionsForPresence() async throws -> [SessionSnapshot] {
        try await listSessions()
    }
}

/// 会话列表的状态边界：分页、revision 冲突、目录同步和 provider-aware 操作都
/// 收敛在这里，SwiftUI 页面只负责呈现与导航。
@MainActor
final class SessionListStore: ObservableObject {
    static let pageSize = 20
    static let maximumRefreshLimit = 200

    @Published private(set) var entries: [SessionListEntry] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = true
    @Published private(set) var loadingMore = false
    @Published private(set) var loadError: String?

    @Published private(set) var directoryTree: SessionDirectoryTreeResponse?
    @Published private(set) var directoryLoading = false
    @Published private(set) var directoryError: String?
    @Published private(set) var directoryRenamePath: String?
    @Published private(set) var restoringHistoryKeys: Set<String> = []

    let api: SessionListServing
    let serverID: String

    private var nextOffset = 0
    private var revision: String?
    private var syncTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var presenceGeneration = 0
    /// MainActor methods are re-entrant across `await`. This FIFO gate mirrors Android's
    /// operation mutex so refresh/pagination/restore/delete cannot commit out of order.
    private var operationActive = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshPending = false
    private var loadMorePending = false

    init(api: SessionListServing, serverID: String) {
        self.api = api
        self.serverID = serverID
    }

    deinit {
        syncTask?.cancel()
        presenceTask?.cancel()
    }

    var managedSessions: [SessionSnapshot] { entries.compactMap(\.session) }
    var canLoadMore: Bool { nextOffset < total }
    var isRestoringHistory: Bool { !restoringHistoryKeys.isEmpty }

    func startSync() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            guard let self else { return }
            _ = await load(silent: !entries.isEmpty)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                _ = await load(silent: true)
                if directoryTree != nil {
                    _ = await loadDirectories(silent: true)
                }
            }
        }
    }

    func stopSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    @discardableResult
    func load(silent: Bool = false) async -> Bool {
        guard !refreshPending else { return false }
        refreshPending = true
        defer { refreshPending = false }
        await enterOperation()
        defer { leaveOperation() }
        guard !Task.isCancelled else { return false }
        return await loadInsideOperation(silent: silent)
    }

    private func loadInsideOperation(silent: Bool) async -> Bool {
        if !silent { loading = true }
        defer { loading = false }

        let refreshLimit = min(max(entries.count, Self.pageSize), Self.maximumRefreshLimit)
        do {
            let page = try await api.fetchSessionList(
                offset: 0,
                limit: refreshLimit,
                revision: nil
            )
            let retainTail = entries.count > refreshLimit
                && page.entries.count == refreshLimit
                && page.revision == revision
            entries = retainTail
                ? page.entries + Array(entries.dropFirst(refreshLimit))
                : page.entries
            total = page.total
            nextOffset = entries.count
            revision = page.revision
            loadError = nil
            publishManagedSessions()
            return true
        } catch {
            if !silent || entries.isEmpty { loadError = error.localizedDescription }
            return false
        }
    }

    @discardableResult
    func loadMore() async -> Bool {
        // Reserve pagination before the first suspension so the last few visible rows cannot
        // enqueue one request each while another operation owns the gate.
        guard canLoadMore, !loadMorePending else { return false }
        loadMorePending = true
        loadingMore = true
        defer {
            loadMorePending = false
            loadingMore = false
        }
        await enterOperation()
        defer { leaveOperation() }
        guard !Task.isCancelled, canLoadMore else { return false }
        let requestedOffset = nextOffset
        let requestedRevision = revision
        do {
            let page = try await api.fetchSessionList(
                offset: requestedOffset,
                limit: Self.pageSize,
                revision: requestedRevision
            )
            guard nextOffset == requestedOffset, revision == requestedRevision else { return false }
            var known = Set(entries.map(\.key))
            entries += page.entries.filter { known.insert($0.key).inserted }
            total = page.total
            nextOffset = page.offset + page.entries.count
            revision = page.revision
            loadError = nil
            publishManagedSessions()
            return true
        } catch WandAPI.APIError.server(let status, _) where status == 409 {
            return await loadInsideOperation(silent: true)
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func loadDirectories(silent: Bool = false) async -> Bool {
        await enterOperation()
        defer { leaveOperation() }
        guard !Task.isCancelled else { return false }
        return await loadDirectoriesInsideOperation(silent: silent)
    }

    private func loadDirectoriesInsideOperation(silent: Bool) async -> Bool {
        guard !directoryLoading else { return false }
        directoryLoading = true
        defer { directoryLoading = false }
        do {
            directoryTree = try await api.fetchSessionDirectories()
            directoryError = nil
            return true
        } catch {
            if !silent || directoryTree == nil { directoryError = error.localizedDescription }
            return false
        }
    }

    @discardableResult
    func renameDirectory(path: String, name rawName: String) async -> Bool {
        await enterOperation()
        defer { leaveOperation() }
        guard !Task.isCancelled else { return false }
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty, directoryRenamePath == nil else { return false }
        let normalizedName: String
        do {
            normalizedName = try SessionDirectoryNameValidation.normalized(rawName)
        } catch {
            directoryError = error.localizedDescription
            return false
        }

        let previousTree = directoryTree
        directoryRenamePath = normalizedPath
        directoryTree?.replaceCustomName(
            path: normalizedPath,
            with: normalizedName.isEmpty ? nil : normalizedName
        )
        defer { directoryRenamePath = nil }
        do {
            try await api.renameSessionDirectory(path: normalizedPath, name: normalizedName)
            directoryError = nil
            _ = await loadDirectoriesInsideOperation(silent: true)
            return true
        } catch {
            directoryTree = previousTree
            directoryError = error.localizedDescription
            return false
        }
    }

    func isRestoring(_ history: HistorySession) -> Bool {
        restoringHistoryKeys.contains(history.id)
    }

    func restore(_ history: HistorySession) async -> SessionSnapshot? {
        // Reserve before waiting for the operation gate; two taps must collapse into one
        // provider resume even if a slow refresh is currently in flight.
        guard !restoringHistoryKeys.contains(history.id) else { return nil }
        restoringHistoryKeys.insert(history.id)
        defer { restoringHistoryKeys.remove(history.id) }
        await enterOperation()
        defer { leaveOperation() }
        guard !Task.isCancelled else { return nil }
        do {
            let resumed = try await api.resumeHistory(history)
            entries.removeAll { $0.history?.id == history.id }
            prepend(resumed)
            _ = await loadInsideOperation(silent: true)
            return resumed
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func delete(_ targets: [SessionListEntry]) async -> Bool {
        await enterOperation()
        defer { leaveOperation() }
        guard !Task.isCancelled else { return false }
        guard !targets.isEmpty else { return true }
        let previousEntries = entries
        let previousTotal = total
        let previousNextOffset = nextOffset
        let previousRevision = revision
        let keys = Set(targets.map(\.key))
        entries.removeAll { keys.contains($0.key) }
        total = max(entries.count, total - keys.count)
        nextOffset = min(nextOffset, total)

        do {
            for session in targets.compactMap(\.session) {
                try await api.deleteSession(id: session.id)
                SessionPresenceController.shared.end(
                    sessionId: session.id,
                    serverID: serverID,
                    immediately: true
                )
            }
            let histories = targets.compactMap(\.history)
            for (provider, group) in Dictionary(grouping: histories, by: \.apiProvider) {
                try await api.deleteHistoryBatch(
                    provider: provider,
                    ids: group.map(\.claudeSessionId)
                )
            }
            _ = await loadInsideOperation(silent: true)
            return true
        } catch {
            if !(await loadInsideOperation(silent: true)) {
                entries = previousEntries
                total = previousTotal
                nextOffset = previousNextOffset
                revision = previousRevision
                publishManagedSessions()
            }
            loadError = error.localizedDescription
            return false
        }
    }

    func addCreated(_ snapshot: SessionSnapshot) async {
        await enterOperation()
        defer { leaveOperation() }
        guard !Task.isCancelled else { return }
        prepend(snapshot)
        publishManagedSessions()
    }

    func clearLoadError(_ message: String) {
        if loadError == message { loadError = nil }
    }

    func clearDirectoryError(_ message: String) {
        if directoryError == message { directoryError = nil }
    }

    private func prepend(_ snapshot: SessionSnapshot) {
        let entry = SessionListEntry.managed(
            key: "session-\(snapshot.id)",
            sortTimestamp: SessionTimeFormatting.sortTimestamp(
                timestamp: snapshot.startedAt,
                mtimeMs: nil
            ),
            session: snapshot
        )
        let existed = entries.contains { $0.key == entry.key }
        entries = [entry] + entries.filter { $0.key != entry.key }
        if !existed {
            total += 1
            nextOffset += 1
        }
    }

    private func publishManagedSessions() {
        // Shortcut rows may use the loaded page, but absence-sensitive presence state must
        // only consume `/api/sessions`, which is the complete managed-session fact source.
        guard ServerStore.shared.activeServerID == serverID else { return }
        QuickActionCoordinator.updateRecentSessionShortcuts(managedSessions, serverID: serverID)
        presenceGeneration &+= 1
        let generation = presenceGeneration
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            guard let self,
                  let completeSessions = try? await self.api.fetchManagedSessionsForPresence(),
                  !Task.isCancelled,
                  generation == self.presenceGeneration,
                  ServerStore.shared.activeServerID == self.serverID else { return }
            SessionPresenceController.shared.reconcile(
                snapshots: completeSessions,
                serverID: self.serverID
            )
            if generation == self.presenceGeneration { self.presenceTask = nil }
        }
    }

    private func enterOperation() async {
        if !operationActive {
            operationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func leaveOperation() {
        guard !operationWaiters.isEmpty else {
            operationActive = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}

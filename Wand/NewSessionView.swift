import SwiftUI

/// Serializes state-changing new-session work per endpoint. Cancellation may remove an
/// operation that is still waiting, but an HTTP mutation that already started is allowed to
/// finish before the next snapshot begins. This mirrors Android's per-endpoint workflow mutex
/// and prevents an older POST from committing after a newer selection.
@MainActor
final class NewSessionEndpointMutationQueue {
    static let shared = NewSessionEndpointMutationQueue()

    private var activeEndpoints: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func pendingOperationCount(endpointID: String) -> Int {
        waiters[endpointID]?.count ?? 0
    }

    func run<Value>(
        endpointID: String,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        await acquire(endpointID)
        if Task.isCancelled {
            release(endpointID)
            throw CancellationError()
        }

        // An unstructured task does not inherit later cancellation from the debounce owner.
        // Once its first request starts, the endpoint remains locked until the whole snapshot
        // (and, for create, the session creation) has completed.
        let operationTask = Task { @MainActor in
            try await operation()
        }
        let result = await operationTask.result
        release(endpointID)
        return try result.get()
    }

    private func acquire(_ endpointID: String) async {
        guard activeEndpoints.contains(endpointID) else {
            activeEndpoints.insert(endpointID)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[endpointID, default: []].append(continuation)
        }
    }

    private func release(_ endpointID: String) {
        guard var endpointWaiters = waiters[endpointID], !endpointWaiters.isEmpty else {
            waiters[endpointID] = nil
            activeEndpoints.remove(endpointID)
            return
        }
        let next = endpointWaiters.removeFirst()
        waiters[endpointID] = endpointWaiters.isEmpty ? nil : endpointWaiters
        next.resume()
    }
}

// MARK: - 目录浏览器

/// 极简目录浏览器：基于 /api/directory 逐层进入，选中当前目录。
struct DirectoryBrowserView: View {
    let api: WandAPI
    let startPath: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = "~"
    @State private var items: [DirectoryItem] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var requestGeneration = 0

    var body: some View {
        NavigationView {
            ZStack {
                WandAmbientBackground()
                VStack(spacing: 0) {
                    pathHeader
                    Divider()
                    if loading {
                        Spacer()
                        ProgressView().tint(Theme.brand)
                        Spacer()
                    } else if let errorMessage {
                        Spacer()
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(Theme.danger)
                            .padding()
                        Spacer()
                    } else {
                        directoryList
                    }
                }
            }
            .navigationTitle("选择目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("选择此目录") { onPick(currentPath) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.brand)
                        .disabled(loading)
                }
            }
        }
        .navigationViewStyle(.stack)
        .wandKeyboardShortcuts(directoryBrowserKeyboardShortcuts)
        .task {
            currentPath = startPath.isEmpty ? "~" : startPath
            await load(path: currentPath)
        }
    }

    private var directoryBrowserKeyboardShortcuts: [WandKeyboardShortcutAction] {
        [
            WandKeyboardShortcutAction(
                id: "choose-directory",
                title: "选择此目录",
                key: .return,
                modifiers: .command,
                isEnabled: !loading
            ) {
                onPick(currentPath)
            },
            WandKeyboardShortcutAction(
                id: "refresh-directory",
                title: "刷新目录",
                key: "r",
                modifiers: .command,
                isEnabled: !loading
            ) {
                let path = currentPath
                Task { await load(path: path) }
            },
            WandKeyboardShortcutAction(
                id: "dismiss-directory-browser",
                title: "取消",
                key: .escape,
                modifiers: []
            ) {
                dismiss()
            },
        ]
    }

    private var pathHeader: some View {
        HStack(spacing: 8) {
            Button {
                guard !loading else { return }
                let parent = (currentPath as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != currentPath else { return }
                navigate(to: parent)
            } label: {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.brand)
            }
            .disabled(loading)
            Text(currentPath)
                .font(.wand(size: 12, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var directoryList: some View {
        List {
            ForEach(items.filter { $0.isDirectory }) { item in
                Button {
                    navigate(to: item.path)
                } label: {
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.brand.opacity(0.8))
                        Text(item.name)
                            .font(.wand(size: 14))
                            .foregroundColor(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
    }

    private func navigate(to path: String) {
        currentPath = path
        Task { await load(path: path) }
    }

    private func load(path requestedPath: String) async {
        requestGeneration &+= 1
        let generation = requestGeneration
        loading = true
        errorMessage = nil
        do {
            let listing = try await api.listDirectory(requestedPath)
            guard generation == requestGeneration, currentPath == requestedPath else { return }
            items = listing.items
            // 服务端会把 ~ 之类输入解析为绝对路径；用首项的父路径回填展示。
            if requestedPath == "~", let first = listing.items.first {
                currentPath = (first.path as NSString).deletingLastPathComponent
            }
        } catch {
            guard generation == requestGeneration, currentPath == requestedPath else { return }
            errorMessage = error.localizedDescription
        }
        if generation == requestGeneration { loading = false }
    }
}

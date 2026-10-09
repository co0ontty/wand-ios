import Foundation
import SwiftUI
import Combine
import Network

/// A tool is provider + engine, not another provider named "Wand Agent".
enum WandAgentTool: String, CaseIterable, Identifiable {
    case claude, codex, opencode, grok, qoder, pi
    case wandAgent = "wand-agent"
    case gemini
    var id: String { rawValue }
    var provider: WandProvider { self == .wandAgent ? .pi : WandProvider(normalizing: rawValue) }
    var engine: String? { self == .wandAgent ? "sdk" : self == .pi ? "cli" : nil }
    var title: String { self == .wandAgent ? "Wand Agent" : provider.title }
    var structuredOnly: Bool { self == .wandAgent }
    init(provider: String?, engine: String?) {
        self = provider == "pi" && ["sdk", "core"].contains(engine ?? "") ? .wandAgent : WandAgentTool(rawValue: WandProvider.normalize(provider)) ?? .claude
    }
}

func canChangeBlankSessionDirectory(_ snapshot: SessionSnapshot?, messageTotal: Int) -> Bool {
    guard let snapshot else { return false }
    return snapshot.isStructured && snapshot.status == "idle" && snapshot.archived != true
        && snapshot.claudeSessionId?.isEmpty != false && snapshot.structuredState?.inFlight != true
        && snapshot.messages?.isEmpty != false && (snapshot.messageTotal ?? 0) == 0 && messageTotal == 0
        && snapshot.queuedMessages?.isEmpty != false && snapshot.workspaceTaskId?.isEmpty != false && snapshot.directoryLocked != true
}

func activityTimelineOrder(_ timestamps: [String?]) -> [Int] {
    let times = timestamps.map { SessionTimeFormatting.date(from: $0)?.timeIntervalSince1970 }
    var carried: Double?
    let forward = times.map { time -> Double? in if let time { carried = time }; return time ?? carried }
    let first = forward.compactMap { $0 }.first ?? 0
    let keys = forward.map { $0 ?? first }
    return keys.indices.sorted { keys[$0] == keys[$1] ? $0 < $1 : keys[$0] < keys[$1] }
}

func toolActivityKind(name: String, input: [String: JSONValue]) -> String {
    if let kind = input["__wandToolActivity"]?.objectValue?["kind"]?.stringValue,
       ["edit_file", "read_file", "run_command", "other"].contains(kind) { return kind }
    let name = name.lowercased().components(separatedBy: "__").last?.components(separatedBy: "/").last ?? name.lowercased()
    let multiple = ["paths", "file_paths", "files"].contains { (input[$0]?.arrayValue?.count ?? 0) > 1 }
    let path = !multiple && ["file_path", "path", "filename", "file", "notebook_path"].contains { input[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    if ["bash", "exec", "command", "shell", "terminal"].contains(where: name.contains) { return "run_command" }
    if path && ["edit", "write", "replace", "notebookedit"].contains(where: name.contains) { return "edit_file" }
    if path && ["read", "read_file"].contains(name) { return "read_file" }
    return "other"
}

func keepThinkingRound(text: String, position: Int, lastPosition: Int, running: Bool) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (running && position == lastPosition)
}

@MainActor
final class WandNetworkState: ObservableObject {
    static let shared = WandNetworkState()
    @Published private(set) var wifi = false
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.wifi = path.status == .satisfied && path.usesInterfaceType(.wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "wand.network.timeline"))
    }
}

struct BlankSessionDirectoryPicker: View {
    @ObservedObject var store: ChatStore
    let onChanged: () -> Void
    var body: some View {
        DirectoryBrowserView(api: store.api, startPath: store.snapshot?.cwd ?? "~") { path in
            store.changeDirectory(path, onChanged: onChanged)
        }
        .disabled(store.directoryChanging)
        .overlay(alignment: .bottom) {
            if let error = store.directoryChangeError { Text(error).font(.caption).foregroundStyle(Theme.danger).padding(12).background(Theme.surface) }
            else if store.directoryChanging { ProgressView("切换目录中").padding(12).background(Theme.surface) }
        }
        .interactiveDismissDisabled(store.directoryChanging)
    }
}

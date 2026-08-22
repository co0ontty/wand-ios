import Foundation

/// `/api/session-list` 返回的统一条目。服务端负责把托管会话与可恢复的
/// provider 原生历史按时间混排，客户端只维护分页游标。
enum SessionListEntry: Decodable, Identifiable {
    case managed(key: String, sortTimestamp: Double, session: SessionSnapshot)
    case recoverable(key: String, sortTimestamp: Double, history: HistorySession)

    private enum CodingKeys: String, CodingKey {
        case type, key, sortTimestamp, session, history
    }

    private enum EntryType: String, Decodable {
        case managed, recoverable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EntryType.self, forKey: .type)
        let key = try container.decode(String.self, forKey: .key)
        guard !key.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "会话条目 key 不能为空")
        }
        let timestamp = try container.decode(Double.self, forKey: .sortTimestamp)
        switch type {
        case .managed:
            self = .managed(
                key: key,
                sortTimestamp: timestamp,
                session: try container.decode(SessionSnapshot.self, forKey: .session)
            )
        case .recoverable:
            self = .recoverable(
                key: key,
                sortTimestamp: timestamp,
                history: try container.decode(HistorySession.self, forKey: .history)
            )
        }
    }

    var id: String { key }

    var key: String {
        switch self {
        case .managed(let key, _, _), .recoverable(let key, _, _): return key
        }
    }

    var sortTimestamp: Double {
        switch self {
        case .managed(_, let timestamp, _), .recoverable(_, let timestamp, _): return timestamp
        }
    }

    var session: SessionSnapshot? {
        guard case .managed(_, _, let session) = self else { return nil }
        return session
    }

    var history: HistorySession? {
        guard case .recoverable(_, _, let history) = self else { return nil }
        return history
    }

    var cwd: String {
        switch self {
        case .managed(_, _, let session): return session.cwd ?? ""
        case .recoverable(_, _, let history): return history.cwd
        }
    }
}

struct SessionListPage: Decodable {
    let entries: [SessionListEntry]
    let offset: Int
    let total: Int
    let revision: String
    let unchanged: Bool

    init(entries: [SessionListEntry], offset: Int, total: Int, revision: String, unchanged: Bool = false) {
        self.entries = entries
        self.offset = offset
        self.total = total
        self.revision = revision
        self.unchanged = unchanged
    }

    private enum CodingKeys: String, CodingKey { case entries, offset, total, revision, unchanged }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([SessionListEntry].self, forKey: .entries) ?? []
        offset = try container.decode(Int.self, forKey: .offset)
        total = try container.decode(Int.self, forKey: .total)
        revision = try container.decode(String.self, forKey: .revision)
        unchanged = try container.decodeIfPresent(Bool.self, forKey: .unchanged) ?? false

        guard offset >= 0,
              total >= offset,
              entries.count <= total - offset,
              !revision.isEmpty,
              Set(entries.map(\.key)).count == entries.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .entries,
                in: container,
                debugDescription: "会话分页响应范围、revision 或 key 无效"
            )
        }
    }
}

/// cwd 目录树。entries 只属于当前精确目录，totalCount 包含全部后代。
struct SessionDirectoryNode: Decodable, Identifiable {
    let path: String
    let name: String
    var customName: String?
    let synthetic: Bool
    let directCount: Int
    let totalCount: Int
    let latestTimestamp: Double
    let entries: [SessionListEntry]
    var children: [SessionDirectoryNode]

    var id: String { path.isEmpty ? "synthetic:\(name)" : path }
    var displayName: String {
        customName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? name
    }

    func containsSession(_ sessionID: String?) -> Bool {
        guard let sessionID else { return false }
        return entries.contains { $0.session?.id == sessionID }
            || children.contains { $0.containsSession(sessionID) }
    }

    private enum CodingKeys: String, CodingKey {
        case path, name, customName, synthetic, directCount, totalCount
        case latestTimestamp, entries, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? container.decode(String.self, forKey: .path)) ?? ""
        name = try container.decode(String.self, forKey: .name)
        customName = try? container.decodeIfPresent(String.self, forKey: .customName)
        synthetic = (try? container.decode(Bool.self, forKey: .synthetic)) ?? false
        entries = (try? container.decode([SessionListEntry].self, forKey: .entries)) ?? []
        children = (try? container.decode([SessionDirectoryNode].self, forKey: .children)) ?? []
        directCount = (try? container.decode(Int.self, forKey: .directCount)) ?? entries.count
        totalCount = (try? container.decode(Int.self, forKey: .totalCount)) ?? entries.count
        latestTimestamp = (try? container.decode(Double.self, forKey: .latestTimestamp)) ?? 0
    }

    mutating func replaceCustomName(path targetPath: String, with name: String?) {
        if path == targetPath {
            customName = name
            return
        }
        for index in children.indices {
            children[index].replaceCustomName(path: targetPath, with: name)
        }
    }
}

struct SessionDirectoryTreeResponse: Decodable {
    var roots: [SessionDirectoryNode]
    let totalSessions: Int
    let directoryCount: Int
    let revision: String
    let treeRevision: String

    private enum CodingKeys: String, CodingKey {
        case roots, totalSessions, directoryCount, revision, treeRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        roots = (try? container.decode([SessionDirectoryNode].self, forKey: .roots)) ?? []
        totalSessions = (try? container.decode(Int.self, forKey: .totalSessions))
            ?? roots.reduce(0) { $0 + $1.totalCount }
        directoryCount = (try? container.decode(Int.self, forKey: .directoryCount)) ?? 0
        revision = (try? container.decode(String.self, forKey: .revision)) ?? ""
        treeRevision = (try? container.decode(String.self, forKey: .treeRevision)) ?? revision
    }

    mutating func replaceCustomName(path: String, with name: String?) {
        for index in roots.indices {
            roots[index].replaceCustomName(path: path, with: name)
        }
    }
}

enum SessionListViewMode: String, CaseIterable, Identifiable {
    case sessions
    case directories

    static let storageKey = "wand.sessionList.viewMode"
    var id: String { rawValue }
}

enum SessionDirectoryNameValidation {
    static let maximumCodePointCount = 80

    static func normalized(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.unicodeScalars.count <= maximumCodePointCount else {
            throw ValidationError.tooLong
        }
        // 与服务端 src/server-session-routes.ts 及 Android 的 isISOControl 校验对齐：
        // 拒绝 C0/C1 控制符与行/段分隔符，允许零宽连接符（Cf）——ZWJ emoji 名称合法。
        // CharacterSet.controlCharacters 额外包含 Cf，会误杀 🧑🏽‍💻 这类名称。
        guard !value.unicodeScalars.contains(where: { scalar in
            scalar.value <= 0x1F
                || (0x7F...0x9F).contains(scalar.value)
                || scalar.value == 0x2028
                || scalar.value == 0x2029
        }) else {
            throw ValidationError.containsControlCharacter
        }
        return value
    }

    enum ValidationError: LocalizedError, Equatable {
        case tooLong
        case containsControlCharacter

        var errorDescription: String? {
            switch self {
            case .tooLong: return "工作区名称最多 80 个字符"
            case .containsControlCharacter: return "工作区名称不能包含换行或控制字符"
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}

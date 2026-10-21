import CryptoKit
import Foundation

/// Endpoint-owned in-memory materialized view. Only fingerprints/cursors travel to the server;
/// history bodies never enter preferences, navigation persistence or another endpoint.
actor ConversationSyncBuffer {
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private var pending: [String: (UUID, Task<Data, Error>)] = [:]

    func read(_ id: String, older: Bool = false, fetch: @escaping (String) async throws -> Data) async throws -> Data {
        if let (token, task) = pending[id] {
            let data = try await task.value
            commit(id, token: token, data: data)
            return older ? try await read(id, older: true, fetch: fetch) : data
        }
        let previous = entries[id]
        let token = UUID()
        let task = Task<Data, Error> {
            var parts: [String] = []
            if let previous, let object = try JSONSerialization.jsonObject(with: previous) as? [String: Any],
               let history = object["history"] as? [String: Any] {
                for name in ["revision", "from"] {
                    if let value = history[name] as? String {
                        let key = name == "revision" ? "since" : "from"
                        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "+&=?#")
                        parts.append(key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
                    }
                }
            }
            if older { parts.append("older=1") }
            let response = try await fetch("/sync" + (parts.isEmpty ? "" : "?" + parts.joined(separator: "&")))
            guard let update = try JSONSerialization.jsonObject(with: response) as? [String: Any], update["id"] as? String == id else {
                throw WandAPI.APIError.network("对话同步身份不一致")
            }
            guard let history = update["history"] as? [String: Any] else { return response } // older service
            let old = try previous.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if update["unchanged"] as? Bool == true {
                guard var old else { throw WandAPI.APIError.network("对话同步缺少基线") }
                old["history"] = history
                return try JSONSerialization.data(withJSONObject: old)
            }
            var merged = (update["detail"] as? [String: Any]) ?? old ?? [:]
            guard merged["id"] as? String == id else { throw WandAPI.APIError.network("对话同步缺少详情") }
            var rows: [String: [String: Any]] = [:]
            if update["reset"] as? Bool != true {
                for row in old?["messages"] as? [[String: Any]] ?? [] { if let key = row["messageId"] as? String { rows[key] = row } }
            }
            for row in update["messages"] as? [[String: Any]] ?? [] { if let key = row["messageId"] as? String { rows[key] = row } }
            merged["messages"] = try (update["messageOrder"] as? [String] ?? []).map { key -> [String: Any] in
                guard let row = rows[key] else { throw WandAPI.APIError.network("对话同步缺少消息") }; return row
            }
            merged["history"] = history
            return try JSONSerialization.data(withJSONObject: merged)
        }
        pending[id] = (token, task)
        do { let data = try await task.value; commit(id, token: token, data: data); return data }
        catch { if pending[id]?.0 == token { pending.removeValue(forKey: id) }; throw error }
    }
    private func commit(_ id: String, token: UUID, data: Data) {
        guard pending[id]?.0 == token else { return }
        pending.removeValue(forKey: id); entries[id] = data
        order.removeAll { $0 == id }; order.append(id)
        while order.count > 24 { entries.removeValue(forKey: order.removeFirst()) }
    }
    func forget(_ id: String) { entries.removeValue(forKey: id); order.removeAll { $0 == id }; pending.removeValue(forKey: id)?.1.cancel() }
}

struct ConversationHistory: Decodable {
    let revision: String
    let from: String?
    let hasEarlier: Bool
    let total: Int
}


/// Only hashes and request IDs are persisted, never input, tokens, or submitted attachments.
/// Reserving before suspension prevents concurrent owners and a cold launch from repeating an unknown POST.
actor ConversationRequestLedger {
    private static let persistenceLock = NSLock()
    private let defaults: UserDefaults
    private let key: String
    private var requests: [String: String]
    init(baseURL: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "wand.conversationRequests." + ServerProfiles.stableID(for: baseURL)
        requests = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
    func reserve(fingerprint: String) throws -> String {
        Self.persistenceLock.lock(); defer { Self.persistenceLock.unlock() }
        requests = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let id = requests[fingerprint] { throw ConversationUnconfirmed(requestId: id) }
        guard requests.count < 200 else { throw WandAPI.APIError.server(status: 400, message: "请先核对未确认请求，再继续提交") }
        let id = UUID().uuidString.lowercased()
        requests[fingerprint] = id
        defaults.set(requests, forKey: key)
        return id
    }
    func finish(requestId: String) {
        Self.persistenceLock.lock(); defer { Self.persistenceLock.unlock() }
        requests = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        requests = requests.filter { $0.value != requestId }
        defaults.set(requests, forKey: key)
    }
    func pending() -> [String] {
        Self.persistenceLock.lock(); defer { Self.persistenceLock.unlock() }
        requests = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return Array(Set(requests.values)).sorted()
    }
    static func fingerprint(path: String, body: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return SHA256.hash(data: Data(path.utf8) + data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol ConversationService: AnyObject {
    func listContactEmployees() async throws -> [SiliconEmployee]
    func listContactTeams() async throws -> [ContactTeam]
    func listWorkspaces() async throws -> [Workspace]
    func conversations() async throws -> [ConversationInstance]
    func conversation(_ id: String) async throws -> ConversationInstance
    func conversationPage(_ id: String, older: Bool) async throws -> ConversationInstance
    func conversationPost(path: String, body: [String: Any]) async throws -> ConversationReceipt
    func conversationReceipt(_ id: String) async throws -> ConversationReceipt
    func pendingConversationRequests() async -> [String]
    func updateConversationListState(_ id: String, patch: [String: Bool]) async throws -> ConversationInstance
    func deleteConversation(_ id: String) async throws
}

extension ConversationService {
    func conversationPage(_ id: String, older: Bool) async throws -> ConversationInstance { try await conversation(id) }
}

extension WandAPI: ConversationService {
    func conversations() async throws -> [ConversationInstance] {
        struct Page: Decodable { let conversations: [ConversationInstance] }
        return try await request(Page.self, method: "GET", path: "/api/conversations").conversations
    }
    func conversation(_ id: String) async throws -> ConversationInstance {
        try await conversationPage(id, older: false)
    }
    func conversationPage(_ id: String, older: Bool) async throws -> ConversationInstance {
        let path = "/api/conversations/" + percentEncodePathComponent(id)
        let data = try await conversationSync.read(id, older: older) { suffix in
            do { return try await self.requestData(method: "GET", path: path + suffix) }
            catch APIError.server(let status, _) where status == 404 { return try await self.requestData(method: "GET", path: path) }
        }
        return try JSONDecoder().decode(ConversationInstance.self, from: data)
    }
    func updateConversationListState(_ id: String, patch: [String: Bool]) async throws -> ConversationInstance {
        let detail = try await request(ConversationInstance.self, method: "PATCH", path: "/api/conversations/" + percentEncodePathComponent(id) + "/list-state", body: patch)
        guard detail.id == id else { throw APIError.network("对话列表回执身份不一致") }
        return detail
    }
    func deleteConversation(_ id: String) async throws {
        _ = try await requestData(method: "DELETE", path: "/api/conversations/" + percentEncodePathComponent(id))
        await conversationSync.forget(id)
    }
    func pendingConversationRequests() async -> [String] { await conversationRequests.pending() }
    func conversationReceipt(_ id: String) async throws -> ConversationReceipt {
        let receipt = try await request(ConversationReceipt.self, method: "GET", path: "/api/conversations/requests/" + percentEncodePathComponent(id))
        guard receipt.requestId == id else { throw ConversationUnconfirmed(requestId: id) }
        if receipt.state != "pending" { await conversationRequests.finish(requestId: id) }
        return receipt
    }
    func conversationPost(path: String, body: [String: Any]) async throws -> ConversationReceipt {
        // Invalid local input is rejected before reserving an ID; never permit this helper as a general POST escape hatch.
        guard path == "/api/conversations" || path.hasPrefix("/api/conversations/") else { throw APIError.invalidURL }
        let fingerprint = try ConversationRequestLedger.fingerprint(path: path, body: body)
        let id = try await conversationRequests.reserve(fingerprint: fingerprint)
        var payload = body; payload["requestId"] = id
        do {
            let receipt = try await request(ConversationReceipt.self, method: "POST", path: path, body: payload)
            guard receipt.requestId == id, receipt.state != "pending" else { throw ConversationUnconfirmed(requestId: id) }
            if receipt.state == "rejected" { throw APIError.server(status: 400, message: receipt.error ?? "请求未接受") }
            await conversationRequests.finish(requestId: id)
            return receipt // A failed startup is still durable acceptance, not grounds to repeat the input.
        } catch {
            if isDefiniteInputRejection(error) {
                await conversationRequests.finish(requestId: id)
                throw error
            }
            throw ConversationUnconfirmed(requestId: id)
        }
    }
}

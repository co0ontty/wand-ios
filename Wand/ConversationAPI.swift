import CryptoKit
import Foundation

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
    func conversationPost(path: String, body: [String: Any]) async throws -> ConversationReceipt
    func conversationReceipt(_ id: String) async throws -> ConversationReceipt
    func pendingConversationRequests() async -> [String]
    func updateConversationListState(_ id: String, patch: [String: Bool]) async throws -> ConversationInstance
    func deleteConversation(_ id: String) async throws
}

extension WandAPI: ConversationService {
    func conversations() async throws -> [ConversationInstance] {
        struct Page: Decodable { let conversations: [ConversationInstance] }
        return try await request(Page.self, method: "GET", path: "/api/conversations").conversations
    }
    func conversation(_ id: String) async throws -> ConversationInstance {
        let detail = try await request(ConversationInstance.self, method: "GET", path: "/api/conversations/" + percentEncodePathComponent(id))
        guard detail.id == id else { throw APIError.network("对话回执身份不一致") }
        return detail
    }
    func updateConversationListState(_ id: String, patch: [String: Bool]) async throws -> ConversationInstance {
        let detail = try await request(ConversationInstance.self, method: "PATCH", path: "/api/conversations/" + percentEncodePathComponent(id) + "/list-state", body: patch)
        guard detail.id == id else { throw APIError.network("对话列表回执身份不一致") }
        return detail
    }
    func deleteConversation(_ id: String) async throws {
        _ = try await requestData(method: "DELETE", path: "/api/conversations/" + percentEncodePathComponent(id))
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

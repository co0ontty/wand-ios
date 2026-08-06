import Foundation
import Combine
import CryptoKit

/// A saved Wand endpoint and the credential that belongs only to that endpoint.
struct ServerProfile: Codable, Identifiable, Hashable {
    let id: String
    let baseURL: URL
    let token: String?
    let customName: String?

    var displayName: String {
        customName ?? ServerProfiles.endpointDisplayName(baseURL)
    }

    var hasToken: Bool { token != nil }

    /// Rebuilds endpoint-bound view state when credentials rotate without ever placing the
    /// token itself in a SwiftUI identity, log line, or diagnostic description.
    var connectionIdentity: String {
        let credentialState = token ?? "<anonymous>"
        let digest = SHA256.hash(data: Data("\(id)\u{0}\(credentialState)".utf8))
        let fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(id):\(fingerprint)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case baseURL = "baseUrl"
        case token
        case customName
    }

    init(id: String, baseURL: URL, token: String?, customName: String?) {
        self.id = id
        self.baseURL = baseURL
        self.token = ServerProfiles.normalizedToken(token)
        self.customName = ServerProfiles.normalizedName(customName)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try values.decode(URL.self, forKey: .baseURL)
        let canonicalURL: URL
        do {
            canonicalURL = try ServerProfiles.canonicalBaseURL(rawURL.absoluteString)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .baseURL,
                in: values,
                debugDescription: "Invalid Wand server endpoint"
            )
        }
        self.id = ServerProfiles.stableID(for: canonicalURL)
        self.baseURL = canonicalURL
        self.token = ServerProfiles.normalizedToken(try values.decodeIfPresent(String.self, forKey: .token))
        self.customName = ServerProfiles.normalizedName(
            try values.decodeIfPresent(String.self, forKey: .customName)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encodeIfPresent(token, forKey: .token)
        try values.encodeIfPresent(customName, forKey: .customName)
    }
}

/// Versioned value persisted atomically by `ServerStore`.
///
/// Decoding re-canonicalizes every endpoint and derives ids again, so corrupted or
/// hand-edited persistence cannot break the endpoint/credential isolation invariant.
struct ServerProfilesState: Codable, Equatable {
    static let schemaVersion = 2

    let profiles: [ServerProfile]
    let activeServerID: String?

    init(profiles: [ServerProfile] = [], activeServerID: String? = nil) {
        self.profiles = profiles
        self.activeServerID = activeServerID
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case profiles
        case activeServerID = "activeServerId"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: values,
                debugDescription: "Unsupported server profile schema"
            )
        }

        let decoded = try values.decode([ServerProfile].self, forKey: .profiles)
        var ordered: [ServerProfile] = []
        for incoming in decoded {
            if let index = ordered.firstIndex(where: { $0.id == incoming.id }) {
                let current = ordered[index]
                ordered[index] = ServerProfile(
                    id: current.id,
                    baseURL: current.baseURL,
                    token: current.token ?? incoming.token,
                    customName: current.customName ?? incoming.customName
                )
            } else {
                ordered.append(incoming)
            }
        }

        let activeID = try values.decodeIfPresent(String.self, forKey: .activeServerID)
        guard activeID == nil || ordered.contains(where: { $0.id == activeID }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .activeServerID,
                in: values,
                debugDescription: "Active server does not exist in profile list"
            )
        }
        self.profiles = ordered
        self.activeServerID = activeID
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .version)
        try values.encode(profiles, forKey: .profiles)
        try values.encodeIfPresent(activeServerID, forKey: .activeServerID)
    }
}

/// Pure endpoint normalization, persistence codec, migration, and profile transitions.
/// Callers do not need to understand how ids, legacy connection codes, or ordering work.
enum ServerProfiles {
    enum Failure: Error {
        case invalidURL
    }

    struct ParsedInput {
        let baseURL: URL
        let token: String?
    }

    static func canonicalBaseURL(_ raw: String) throws -> URL {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw Failure.invalidURL }
        if !candidate.lowercased().hasPrefix("http://") &&
            !candidate.lowercased().hasPrefix("https://") {
            candidate = "http://\(candidate)"
        }

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw Failure.invalidURL
        }

        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        guard WandEndpoint.isSafePercentEncodedPath(components.percentEncodedPath) else {
            throw Failure.invalidURL
        }
        if let port = components.port, !(1...65_535).contains(port) {
            throw Failure.invalidURL
        }
        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        while components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }

        guard let url = components.url?.standardized,
              url.host != nil,
              let standardizedComponents = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              WandEndpoint.isSafePercentEncodedPath(standardizedComponents.percentEncodedPath) else {
            throw Failure.invalidURL
        }
        return url
    }

    static func stableID(for baseURL: URL) -> String {
        let canonical = (try? canonicalBaseURL(baseURL.absoluteString)) ?? baseURL
        let digest = SHA256.hash(data: Data(canonical.absoluteString.utf8))
        let prefix = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "server_\(prefix)"
    }

    static func endpointDisplayName(_ baseURL: URL) -> String {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host else {
            return baseURL.absoluteString
        }
        var result = host
        if let port = components.port {
            result += ":\(port)"
        }
        let path = components.percentEncodedPath
        if !path.isEmpty && path != "/" {
            result += path
        }
        return result
    }

    static func normalizedToken(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func normalizedName(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func parsedInput(_ raw: String, fallbackToken: String? = nil) -> ParsedInput? {
        if let decoded = decodeConnectCode(raw) { return decoded }
        guard let url = try? canonicalBaseURL(raw) else { return nil }
        return ParsedInput(baseURL: url, token: normalizedToken(fallbackToken))
    }

    static func migrateLegacy(lastURL: String?, recentInputs: [String], legacyToken: String?) -> ServerProfilesState {
        var ordered: [ServerProfile] = []
        var activeID: String?

        @discardableResult
        func add(_ raw: String, tokenForPlainURL: String? = nil) -> ServerProfile? {
            guard let input = parsedInput(raw, fallbackToken: tokenForPlainURL) else { return nil }
            let id = stableID(for: input.baseURL)
            let incoming = ServerProfile(id: id, baseURL: input.baseURL, token: input.token, customName: nil)
            if let index = ordered.firstIndex(where: { $0.id == id }) {
                let current = ordered[index]
                ordered[index] = ServerProfile(
                    id: id,
                    baseURL: current.baseURL,
                    token: current.token ?? incoming.token,
                    customName: current.customName
                )
                return ordered[index]
            }
            ordered.append(incoming)
            return incoming
        }

        let trimmedLast = lastURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedLast.isEmpty {
            let active = decodeConnectCode(trimmedLast) == nil
                ? add(trimmedLast, tokenForPlainURL: legacyToken)
                : add(trimmedLast)
            activeID = active?.id
        }
        for raw in recentInputs {
            add(raw)
        }
        return ServerProfilesState(profiles: ordered, activeServerID: activeID)
    }

    static func saving(
        _ state: ServerProfilesState,
        baseURL rawURL: String,
        token: String?
    ) -> (state: ServerProfilesState, profile: ServerProfile)? {
        guard let input = parsedInput(rawURL, fallbackToken: token) else { return nil }
        let id = stableID(for: input.baseURL)
        let current = state.profiles.first { $0.id == id }
        // An explicit token wins. A token embedded in a connection code is picked up by
        // `parsedInput`; saving a plain endpoint with nil intentionally clears credentials.
        let effectiveToken = normalizedToken(token) ?? input.token
        let saved = ServerProfile(
            id: id,
            baseURL: input.baseURL,
            token: effectiveToken,
            customName: current?.customName
        )
        let profiles = [saved] + state.profiles.filter { $0.id != id }
        return (ServerProfilesState(profiles: profiles, activeServerID: state.activeServerID), saved)
    }

    static func activating(_ state: ServerProfilesState, id: String?) -> ServerProfilesState {
        guard let id else {
            return ServerProfilesState(profiles: state.profiles, activeServerID: nil)
        }
        guard let selected = state.profiles.first(where: { $0.id == id }) else { return state }
        return ServerProfilesState(
            profiles: [selected] + state.profiles.filter { $0.id != id },
            activeServerID: id
        )
    }

    static func prioritizing(_ state: ServerProfilesState, id: String) -> ServerProfilesState {
        guard let selected = state.profiles.first(where: { $0.id == id }) else { return state }
        return ServerProfilesState(
            profiles: [selected] + state.profiles.filter { $0.id != id },
            activeServerID: state.activeServerID
        )
    }

    static func removing(_ state: ServerProfilesState, id: String) -> ServerProfilesState {
        let remaining = state.profiles.filter { $0.id != id }
        guard remaining.count != state.profiles.count else { return state }
        let activeID: String?
        if state.activeServerID == id {
            activeID = remaining.first?.id
        } else if let current = state.activeServerID,
                  remaining.contains(where: { $0.id == current }) {
            activeID = current
        } else {
            activeID = nil
        }
        return ServerProfilesState(profiles: remaining, activeServerID: activeID)
    }

    static func renaming(_ state: ServerProfilesState, id: String, customName: String?) -> ServerProfilesState {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return state }
        var profiles = state.profiles
        let current = profiles[index]
        profiles[index] = ServerProfile(
            id: current.id,
            baseURL: current.baseURL,
            token: current.token,
            customName: customName
        )
        return ServerProfilesState(profiles: profiles, activeServerID: state.activeServerID)
    }

    static func profile(in state: ServerProfilesState, matching rawURL: String) -> ServerProfile? {
        guard let parsed = parsedInput(rawURL) else { return nil }
        let id = stableID(for: parsed.baseURL)
        return state.profiles.first { $0.id == id }
    }

    static func encode(_ state: ServerProfilesState) -> Data? {
        try? JSONEncoder().encode(state)
    }

    static func decode(_ data: Data?) -> ServerProfilesState? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ServerProfilesState.self, from: data)
    }

    static func decodeConnectCode(_ raw: String) -> ParsedInput? {
        let cleaned = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !cleaned.isEmpty else { return nil }
        let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
        let variants = [
            padded,
            padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"),
        ]
        let data = variants.lazy.compactMap { Data(base64Encoded: $0) }.first
        guard let data,
              let decoded = String(data: data, encoding: .utf8),
              let separator = decoded.range(of: "#", options: .backwards) else {
            return nil
        }
        let token = String(decoded[separator.upperBound...])
        guard token.count >= 16,
              let baseURL = try? canonicalBaseURL(String(decoded[..<separator.lowerBound])) else {
            return nil
        }
        return ParsedInput(baseURL: baseURL, token: token)
    }
}

/// Persistence module for server profiles. The full v2 state is authoritative while a safe,
/// canonical legacy projection is kept in sync so installing an older build does not lose the
/// active endpoint. The legacy token always belongs only to the projected active endpoint.
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    private let defaults: UserDefaults
    private let profilesKey = "wand.serverProfiles.v2"
    private let serverURLKey = "wand.serverURL"
    private let tokenKey = "wand.token"
    private let recentInputsKey = "wand.recentInputs"
    private let legacyFingerprintKey = "wand.serverProfiles.v2.legacyFingerprint"
    private let liveActivityKey = "wand.liveActivityEnabled"
    private let notificationsKey = "wand.notificationsEnabled"

    @Published private(set) var profileState: ServerProfilesState

    var profiles: [ServerProfile] { profileState.profiles }
    var activeServerID: String? { profileState.activeServerID }
    var activeProfile: ServerProfile? {
        guard let id = activeServerID else { return nil }
        return profiles.first { $0.id == id }
    }

    // Compatibility seam for existing single-server callers.
    var serverURL: URL? { activeProfile?.baseURL }
    var token: String? { activeProfile?.token }

    /// Compatibility list for the current connection screen. Values are canonical URLs only;
    /// connection codes and endpoint tokens are never exposed through this property.
    var recentInputs: [String] { profiles.map(\.baseURL.absoluteString) }

    /// 灵动岛 / 锁屏 Live Activity 开关（iOS 16.1+ 生效），默认开。
    @Published var liveActivityEnabled: Bool {
        didSet { defaults.set(liveActivityEnabled, forKey: liveActivityKey) }
    }
    /// 会话回复完成 / 等待授权的本地通知，默认开。
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: notificationsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persistedData = defaults.data(forKey: profilesKey)
        let decoded = ServerProfiles.decode(persistedData)
        let legacyMirror = LegacyMirror(
            lastURL: defaults.string(forKey: serverURLKey) ?? "",
            recentInputs: defaults.stringArray(forKey: recentInputsKey) ?? [],
            token: defaults.string(forKey: tokenKey)
        )
        let storedFingerprint = defaults.string(forKey: legacyFingerprintKey)
        let currentFingerprint = Self.legacyFingerprint(for: legacyMirror)
        let hasPersistedV2 = defaults.object(forKey: profilesKey) != nil
        // A token without an endpoint is not a recoverable legacy connection and must never be
        // used as a reason to replace v2. Generated mirrors always contain URL and recent keys,
        // including the explicit empty/disconnected state.
        let hasLegacyProjection = defaults.object(forKey: serverURLKey) != nil ||
            defaults.object(forKey: recentInputsKey) != nil

        let shouldPersistInitialState: Bool
        if let decoded {
            if let storedFingerprint {
                if storedFingerprint == currentFingerprint {
                    self.profileState = decoded
                } else {
                    // An older build changed the legacy projection while v2 was unavailable.
                    // Import it instead of resurrecting stale endpoint credentials.
                    self.profileState = Self.migratedState(from: legacyMirror)
                }
                shouldPersistInitialState = true
            } else if !hasLegacyProjection ||
                        Self.legacyFingerprint(for: Self.legacyMirror(for: decoded)) == currentFingerprint {
                // The previous iOS v2 build removed all legacy values and had no marker. Trust
                // that valid v2 payload once, then establish the downgrade-safe projection.
                self.profileState = decoded
                shouldPersistInitialState = true
            } else {
                // An unmarked legacy view that differs from v2 came from a downgrade-era build.
                self.profileState = Self.migratedState(from: legacyMirror)
                shouldPersistInitialState = true
            }
        } else if !hasPersistedV2 || hasLegacyProjection {
            // A missing/corrupt/unsupported v2 payload can recover from the legacy projection.
            self.profileState = Self.migratedState(from: legacyMirror)
            shouldPersistInitialState = true
        } else {
            // Do not immediately replace an unreadable v2 payload with an empty state when no
            // recovery source exists. A later explicit user mutation will write a fresh state.
            self.profileState = ServerProfilesState()
            shouldPersistInitialState = false
        }
        self.liveActivityEnabled = defaults.object(forKey: liveActivityKey) as? Bool ?? true
        self.notificationsEnabled = defaults.object(forKey: notificationsKey) as? Bool ?? true

        if shouldPersistInitialState {
            persistProfileState()
        }
    }

    @discardableResult
    func saveProfile(serverURL: URL, token: String?, activate: Bool = true) -> ServerProfile? {
        guard let result = ServerProfiles.saving(
            profileState,
            baseURL: serverURL.absoluteString,
            token: token
        ) else { return nil }
        let previous = profiles.first { $0.id == result.profile.id }
        var next = result.state
        if activate {
            next = ServerProfiles.activating(next, id: result.profile.id)
        }
        if previous?.token != result.profile.token {
            SelfSignedSession.resetEndpoint(result.profile.baseURL)
        }
        commit(next)
        return result.profile
    }

    @discardableResult
    func activateProfile(id: String) -> Bool {
        guard profiles.contains(where: { $0.id == id }) else { return false }
        commit(ServerProfiles.activating(profileState, id: id))
        return true
    }

    func removeProfile(id: String) {
        guard let removed = profiles.first(where: { $0.id == id }) else { return }
        SelfSignedSession.resetEndpoint(removed.baseURL)
        commit(ServerProfiles.removing(profileState, id: id))
    }

    func renameProfile(id: String, customName: String?) {
        commit(ServerProfiles.renaming(profileState, id: id, customName: customName))
    }

    func removeAllProfiles() {
        for profile in profiles {
            SelfSignedSession.resetEndpoint(profile.baseURL)
        }
        commit(ServerProfilesState())
    }

    func profile(id: String) -> ServerProfile? {
        profiles.first { $0.id == id }
    }

    func profile(matching rawURL: String) -> ServerProfile? {
        ServerProfiles.profile(in: profileState, matching: rawURL)
    }

    // MARK: - Single-server compatibility

    func connect(serverURL: URL, token: String?) {
        saveProfile(serverURL: serverURL, token: token, activate: true)
    }

    /// Ends the current UI session without forgetting saved endpoint credentials.
    func disconnect() {
        commit(ServerProfiles.activating(profileState, id: nil))
    }

    /// Legacy connection UI compatibility. Successful connection codes are converted into an
    /// endpoint-scoped profile immediately; only the canonical URL is subsequently displayed.
    func addRecent(_ rawInput: String) {
        guard let parsed = ServerProfiles.parsedInput(rawInput) else { return }
        let id = ServerProfiles.stableID(for: parsed.baseURL)
        if profiles.contains(where: { $0.id == id }), parsed.token == nil {
            commit(ServerProfiles.prioritizing(profileState, id: id))
            return
        }
        _ = saveProfile(serverURL: parsed.baseURL, token: parsed.token, activate: false)
    }

    func removeRecent(_ rawInput: String) {
        guard let profile = profile(matching: rawInput) else { return }
        removeProfile(id: profile.id)
    }

    private func commit(_ state: ServerProfilesState) {
        guard state != profileState else { return }
        let oldActiveID = profileState.activeServerID
        let remainingIDs = Set(state.profiles.map(\.id))
        var retiredServerIDs = Set(profileState.profiles.map(\.id)).subtracting(remainingIDs)
        let switchedActiveServer = oldActiveID != state.activeServerID
        if switchedActiveServer, let oldActiveID { retiredServerIDs.insert(oldActiveID) }
        profileState = state
        persistProfileState()
        let retiredIDs = retiredServerIDs
        if switchedActiveServer || !retiredIDs.isEmpty {
            Task { @MainActor in
                if switchedActiveServer {
                    // iOS polls only the selected endpoint; switching invalidates the entire
                    // process-wide Live Activity, including legacy entries without serverID.
                    SessionPresenceController.shared.endAll()
                } else {
                    for serverID in retiredIDs {
                        SessionPresenceController.shared.endAll(serverID: serverID)
                    }
                }
            }
        }
    }

    private func persistProfileState() {
        guard let data = ServerProfiles.encode(profileState) else { return }
        let mirror = Self.legacyMirror(for: profileState)

        // The marker is written last. If persistence is interrupted, the next launch observes a
        // mismatch and imports the legacy side instead of silently trusting a stale projection.
        defaults.removeObject(forKey: legacyFingerprintKey)
        defaults.set(data, forKey: profilesKey)
        defaults.set(mirror.lastURL, forKey: serverURLKey)
        defaults.set(mirror.recentInputs, forKey: recentInputsKey)
        if let token = mirror.token {
            defaults.set(token, forKey: tokenKey)
        } else {
            defaults.removeObject(forKey: tokenKey)
        }
        defaults.set(Self.legacyFingerprint(for: mirror), forKey: legacyFingerprintKey)
    }

    private struct LegacyMirror {
        let lastURL: String
        let recentInputs: [String]
        let token: String?
    }

    private static func legacyMirror(for state: ServerProfilesState) -> LegacyMirror {
        let active = state.activeServerID.flatMap { activeID in
            state.profiles.first { $0.id == activeID }
        }
        return LegacyMirror(
            lastURL: active?.baseURL.absoluteString ?? "",
            recentInputs: state.profiles.map(\.baseURL.absoluteString),
            token: active?.token
        )
    }

    private static func migratedState(from mirror: LegacyMirror) -> ServerProfilesState {
        ServerProfiles.migrateLegacy(
            lastURL: mirror.lastURL,
            recentInputs: mirror.recentInputs,
            legacyToken: mirror.token
        )
    }

    private static func legacyFingerprint(for mirror: LegacyMirror) -> String {
        var input = Data()
        let recent = mirror.recentInputs.map { value in
            "\(value.utf8.count):\(value)"
        }.joined()
        for value in [mirror.lastURL, recent, mirror.token ?? ""] {
            let bytes = Data(value.utf8)
            var length = UInt32(truncatingIfNeeded: bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

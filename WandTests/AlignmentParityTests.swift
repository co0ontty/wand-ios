import Foundation
import XCTest
@testable import Wand

private actor AlignmentAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class AlignmentParityTests: XCTestCase {
    // MARK: - Server profiles and endpoint isolation

    func testServerProfilesCanonicalizeEndpointsAndDeriveStableAndroidCompatibleID() throws {
        let canonical = try ServerProfiles.canonicalBaseURL(
            "  HTTPS://Example.COM:443/wand///?temporary=1#fragment  "
        )
        let equivalent = try ServerProfiles.canonicalBaseURL("https://example.com/wand")

        XCTAssertEqual(canonical.absoluteString, "https://example.com/wand")
        XCTAssertEqual(canonical, equivalent)
        XCTAssertEqual(
            ServerProfiles.stableID(for: canonical),
            "server_c29627398c24482dae36f3ef"
        )
        XCTAssertEqual(
            ServerProfiles.stableID(for: canonical),
            ServerProfiles.stableID(for: equivalent)
        )
        XCTAssertEqual(ServerProfiles.endpointDisplayName(canonical), "example.com/wand")
    }

    func testLegacyMigrationRemovesRawConnectionCodesAndKeepsTokensEndpointScoped() throws {
        let suiteName = "AlignmentParityTests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstURL = "https://one.example.test:7443/wand"
        let secondURL = "http://one.example.test:8080/other"
        let firstToken = "first-endpoint-token-1234"
        let secondToken = "second-endpoint-token-5678"
        let connectionCode = Data("\(secondURL)#\(secondToken)".utf8).base64EncodedString()

        defaults.set(firstURL, forKey: "wand.serverURL")
        defaults.set(firstToken, forKey: "wand.token")
        defaults.set([connectionCode], forKey: "wand.recentInputs")

        let store = ServerStore(defaults: defaults)
        let first = try XCTUnwrap(store.profile(matching: firstURL))
        let second = try XCTUnwrap(store.profile(matching: secondURL))

        XCTAssertEqual(store.activeServerID, first.id)
        XCTAssertEqual(first.token, firstToken)
        XCTAssertEqual(second.token, secondToken)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(store.recentInputs), Set([firstURL, secondURL]))
        XCTAssertFalse(store.recentInputs.contains(connectionCode))

        XCTAssertEqual(defaults.string(forKey: "wand.serverURL"), firstURL)
        XCTAssertEqual(defaults.string(forKey: "wand.token"), firstToken)
        XCTAssertEqual(defaults.stringArray(forKey: "wand.recentInputs"), [firstURL, secondURL])
        let fingerprint = try XCTUnwrap(
            defaults.string(forKey: "wand.serverProfiles.v2.legacyFingerprint")
        )
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertFalse(fingerprint.contains(firstToken))
        XCTAssertFalse(defaults.stringArray(forKey: "wand.recentInputs")?.contains(connectionCode) ?? true)

        let persisted = try XCTUnwrap(defaults.data(forKey: "wand.serverProfiles.v2"))
        let persistedText = try XCTUnwrap(String(data: persisted, encoding: .utf8))
        XCTAssertFalse(persistedText.contains(connectionCode))
        XCTAssertEqual(ServerProfiles.decode(persisted), store.profileState)
    }

    func testLegacyMirrorRecoversUnreadableOrUnsupportedV2WithoutMovingActiveToken() throws {
        let invalidPayloads = [
            Data("{broken".utf8),
            Data(#"{"version":3,"profiles":[],"activeServerId":null}"#.utf8),
        ]

        for payload in invalidPayloads {
            let suiteName = "AlignmentParityTests.recovery.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let activeURL = try XCTUnwrap(URL(string: "https://active.example.test:7443/wand"))
            let inactiveURL = try XCTUnwrap(URL(string: "https://inactive.example.test:8443/wand"))
            let activeToken = "active-endpoint-token-1234"
            let inactiveToken = "inactive-endpoint-token-5678"
            let original = ServerStore(defaults: defaults)
            let active = try XCTUnwrap(original.saveProfile(
                serverURL: activeURL,
                token: activeToken,
                activate: true
            ))
            let inactive = try XCTUnwrap(original.saveProfile(
                serverURL: inactiveURL,
                token: inactiveToken,
                activate: false
            ))

            XCTAssertEqual(original.profile(id: active.id)?.token, activeToken)
            XCTAssertEqual(original.profile(id: inactive.id)?.token, inactiveToken)
            defaults.set(payload, forKey: "wand.serverProfiles.v2")

            let recovered = ServerStore(defaults: defaults)
            XCTAssertEqual(recovered.activeServerID, active.id)
            XCTAssertEqual(recovered.profile(id: active.id)?.token, activeToken)
            XCTAssertNil(recovered.profile(id: inactive.id)?.token)
            XCTAssertEqual(defaults.string(forKey: "wand.serverURL"), activeURL.absoluteString)
            XCTAssertEqual(defaults.string(forKey: "wand.token"), activeToken)
            XCTAssertEqual(
                Set(defaults.stringArray(forKey: "wand.recentInputs") ?? []),
                Set([activeURL.absoluteString, inactiveURL.absoluteString])
            )
            XCTAssertNotNil(ServerProfiles.decode(defaults.data(forKey: "wand.serverProfiles.v2")))
        }
    }

    func testDisconnectClearsLegacyActiveCredentialButKeepsCanonicalRecentMirror() throws {
        let suiteName = "AlignmentParityTests.disconnect-mirror.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstURL = try XCTUnwrap(URL(string: "https://first.example.test/wand"))
        let secondURL = try XCTUnwrap(URL(string: "https://second.example.test/wand"))
        let store = ServerStore(defaults: defaults)
        _ = store.saveProfile(
            serverURL: firstURL,
            token: "first-endpoint-token-1234",
            activate: true
        )
        _ = store.saveProfile(
            serverURL: secondURL,
            token: "second-endpoint-token-5678",
            activate: false
        )

        store.disconnect()

        XCTAssertNil(store.activeServerID)
        XCTAssertEqual(defaults.string(forKey: "wand.serverURL"), "")
        XCTAssertNil(defaults.object(forKey: "wand.token"))
        XCTAssertEqual(
            defaults.stringArray(forKey: "wand.recentInputs"),
            [secondURL.absoluteString, firstURL.absoluteString]
        )
        XCTAssertNotNil(defaults.string(forKey: "wand.serverProfiles.v2.legacyFingerprint"))
        let persisted = try XCTUnwrap(ServerProfiles.decode(
            defaults.data(forKey: "wand.serverProfiles.v2")
        ))
        XCTAssertNil(persisted.activeServerID)
        XCTAssertEqual(Set(persisted.profiles.compactMap(\.token)), Set([
            "first-endpoint-token-1234",
            "second-endpoint-token-5678",
        ]))
    }

    func testLegacyMirrorChangeWinsOverStaleV2AfterDowngrade() throws {
        let suiteName = "AlignmentParityTests.downgrade.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let staleURL = try XCTUnwrap(URL(string: "https://stale.example.test/wand"))
        let downgradedURL = "https://downgrade.example.test:7443/wand"
        let downgradedToken = "downgrade-endpoint-token-1234"
        let original = ServerStore(defaults: defaults)
        _ = original.saveProfile(
            serverURL: staleURL,
            token: "stale-endpoint-token-5678",
            activate: true
        )

        defaults.set(downgradedURL, forKey: "wand.serverURL")
        defaults.set(downgradedToken, forKey: "wand.token")
        defaults.set([downgradedURL], forKey: "wand.recentInputs")

        let recovered = ServerStore(defaults: defaults)
        XCTAssertNil(recovered.profile(matching: staleURL.absoluteString))
        XCTAssertEqual(recovered.activeProfile?.baseURL.absoluteString, downgradedURL)
        XCTAssertEqual(recovered.activeProfile?.token, downgradedToken)
        XCTAssertEqual(recovered.profiles.count, 1)
    }

    func testUnmarkedV2FromPreviousIOSBuildSurvivesMissingLegacyValues() throws {
        let suiteName = "AlignmentParityTests.unmarked.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let baseURL = try ServerProfiles.canonicalBaseURL("https://unmarked.example.test/wand")
        let saved = try XCTUnwrap(ServerProfiles.saving(
            ServerProfilesState(),
            baseURL: baseURL.absoluteString,
            token: "unmarked-endpoint-token-1234"
        ))
        let state = ServerProfiles.activating(saved.state, id: saved.profile.id)
        defaults.set(try XCTUnwrap(ServerProfiles.encode(state)), forKey: "wand.serverProfiles.v2")

        let recovered = ServerStore(defaults: defaults)
        XCTAssertEqual(recovered.profileState, state)
        XCTAssertEqual(defaults.string(forKey: "wand.serverURL"), baseURL.absoluteString)
        XCTAssertEqual(defaults.string(forKey: "wand.token"), saved.profile.token)
        XCTAssertEqual(defaults.stringArray(forKey: "wand.recentInputs"), [baseURL.absoluteString])
        XCTAssertNotNil(defaults.string(forKey: "wand.serverProfiles.v2.legacyFingerprint"))
    }

    func testUnreadableV2WithoutRecoverySourceIsNotImmediatelyOverwritten() throws {
        let suiteName = "AlignmentParityTests.no-recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unreadable = Data("{broken".utf8)
        defaults.set(unreadable, forKey: "wand.serverProfiles.v2")

        let store = ServerStore(defaults: defaults)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "wand.serverProfiles.v2"), unreadable)
        XCTAssertNil(defaults.object(forKey: "wand.serverURL"))
        XCTAssertNil(defaults.object(forKey: "wand.token"))
        XCTAssertNil(defaults.object(forKey: "wand.recentInputs"))
        XCTAssertNil(defaults.object(forKey: "wand.serverProfiles.v2.legacyFingerprint"))
    }

    func testProfileTransitionsNeverMoveATokenToAnotherEndpoint() throws {
        let firstURL = try ServerProfiles.canonicalBaseURL("https://host.example.test:3000/a")
        let secondURL = try ServerProfiles.canonicalBaseURL("https://host.example.test:4000/a")
        var state = ServerProfilesState()

        let firstSave = try XCTUnwrap(ServerProfiles.saving(
            state,
            baseURL: firstURL.absoluteString,
            token: "token-for-3000"
        ))
        state = ServerProfiles.activating(firstSave.state, id: firstSave.profile.id)

        let secondSave = try XCTUnwrap(ServerProfiles.saving(
            state,
            baseURL: secondURL.absoluteString,
            token: "token-for-4000"
        ))
        state = secondSave.state

        let updatedFirst = try XCTUnwrap(ServerProfiles.saving(
            state,
            baseURL: firstURL.absoluteString,
            token: "updated-token-for-3000"
        ))
        state = updatedFirst.state

        XCTAssertEqual(
            state.profiles.first(where: { $0.id == firstSave.profile.id })?.token,
            "updated-token-for-3000"
        )
        XCTAssertEqual(
            state.profiles.first(where: { $0.id == secondSave.profile.id })?.token,
            "token-for-4000"
        )

        state = ServerProfiles.activating(state, id: secondSave.profile.id)
        XCTAssertEqual(state.activeServerID, secondSave.profile.id)
        XCTAssertEqual(state.profiles.first?.token, "token-for-4000")

        state = ServerProfiles.removing(state, id: secondSave.profile.id)
        XCTAssertEqual(state.activeServerID, firstSave.profile.id)
        XCTAssertEqual(state.profiles.map(\.token), ["updated-token-for-3000"])
    }

    func testServerProfileConnectionIdentityTracksCredentialsButNotDisplayNameOrPlaintext() throws {
        let baseURL = try ServerProfiles.canonicalBaseURL("https://identity.example.test/wand")
        let id = ServerProfiles.stableID(for: baseURL)
        let token = "plain-text-token-must-not-leak"
        let original = ServerProfile(id: id, baseURL: baseURL, token: token, customName: nil)
        let sameConnection = ServerProfile(
            id: id,
            baseURL: baseURL,
            token: token,
            customName: "个人服务器"
        )
        let rotatedCredential = ServerProfile(
            id: id,
            baseURL: baseURL,
            token: "rotated-token-must-not-leak",
            customName: "个人服务器"
        )

        XCTAssertEqual(original.connectionIdentity, sameConnection.connectionIdentity)
        XCTAssertNotEqual(original.connectionIdentity, rotatedCredential.connectionIdentity)
        XCTAssertTrue(original.connectionIdentity.hasPrefix("\(id):"))
        XCTAssertFalse(original.connectionIdentity.contains(token))
        XCTAssertFalse(rotatedCredential.connectionIdentity.contains("rotated-token-must-not-leak"))
    }

    func testSelfSignedSessionsAndCookieJarsAreIsolatedByPort() throws {
        let firstURL = try XCTUnwrap(URL(string: "https://parity.invalid:31337/wand"))
        let secondURL = try XCTUnwrap(URL(string: "https://parity.invalid:31338/wand"))
        defer {
            SelfSignedSession.resetEndpoint(firstURL)
            SelfSignedSession.resetEndpoint(secondURL)
        }

        let first = SelfSignedSession.forEndpoint(firstURL)
        let firstAgain = SelfSignedSession.forEndpoint(firstURL)
        let second = SelfSignedSession.forEndpoint(secondURL)

        XCTAssertTrue(first === firstAgain)
        XCTAssertFalse(first === second)

        let firstCookies = try XCTUnwrap(first.cookieStorage)
        let secondCookies = try XCTUnwrap(second.cookieStorage)
        XCTAssertFalse(firstCookies === secondCookies)

        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "parity.invalid",
            .path: "/",
            .name: "wand-parity",
            .value: "first-port-only",
            .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 60),
        ]))
        firstCookies.setCookie(cookie)

        XCTAssertEqual(firstCookies.cookies?.first(where: { $0.name == "wand-parity" })?.value, "first-port-only")
        XCTAssertNil(secondCookies.cookies?.first(where: { $0.name == "wand-parity" }))
    }

    func testEndpointClientsKeepTheirRetiredHandleUntilRecreated() throws {
        let baseURL = try XCTUnwrap(URL(
            string: "https://retirement-\(UUID().uuidString.lowercased()).invalid:31339/wand"
        ))
        defer { SelfSignedSession.resetEndpoint(baseURL) }

        let original = SelfSignedSession.forEndpoint(baseURL)
        let staleAPI = WandAPI(baseURL: baseURL, token: "removed-profile-token")
        let staleSocket = WandSocket(baseURL: baseURL)

        XCTAssertTrue(staleAPI.endpointSession === original)
        XCTAssertTrue(staleSocket.endpointSession === original)
        XCTAssertFalse(original.isRetired)

        SelfSignedSession.resetEndpoint(baseURL)

        XCTAssertTrue(original.isRetired)
        XCTAssertTrue(staleAPI.endpointSession === original)
        XCTAssertTrue(staleSocket.endpointSession === original)

        let replacementAPI = WandAPI(baseURL: baseURL, token: "new-profile-token")
        XCTAssertFalse(replacementAPI.endpointSession === original)
        XCTAssertFalse(replacementAPI.endpointSession.isRetired)
        XCTAssertNotEqual(
            replacementAPI.endpointSession.resourceCacheNamespace,
            original.resourceCacheNamespace
        )
    }

    func testRetiredAPIRequestsAndFileDownloadFailClosedWithoutCreatingAReplacementClient() async throws {
        let baseURL = try XCTUnwrap(URL(
            string: "https://retired-download-\(UUID().uuidString.lowercased()).invalid/wand"
        ))
        defer { SelfSignedSession.resetEndpoint(baseURL) }

        let api = WandAPI(baseURL: baseURL, token: "removed-profile-token")
        let original = api.endpointSession
        SelfSignedSession.resetEndpoint(baseURL)

        do {
            _ = try await api.listSessions()
            XCTFail("A retired endpoint client must not start a REST request")
        } catch {
            XCTAssertEqual(error.localizedDescription, "网络错误：服务器连接已关闭")
        }

        do {
            _ = try await WandServerFileLink.download(serverPath: "/tmp/private.txt", api: api)
            XCTFail("A retired endpoint client must not start a download")
        } catch {
            XCTAssertEqual(error.localizedDescription, "服务器连接已关闭")
        }

        XCTAssertTrue(api.endpointSession === original)
        XCTAssertTrue(original.isRetired)
        let replacement = SelfSignedSession.forEndpoint(baseURL)
        XCTAssertFalse(replacement === original)
    }

    func testTokenReloginUsingRetiredHandleFailsSynchronously() throws {
        let baseURL = try XCTUnwrap(URL(
            string: "https://retired-login-\(UUID().uuidString.lowercased()).invalid/wand"
        ))
        defer { SelfSignedSession.resetEndpoint(baseURL) }

        let original = SelfSignedSession.forEndpoint(baseURL)
        SelfSignedSession.resetEndpoint(baseURL)
        var loginResult: Result<[HTTPCookie], WandAuth.Failure>?

        WandAuth.loginWithToken(
            serverURL: baseURL,
            appToken: "obsolete-token",
            endpointSession: original
        ) { result in
            loginResult = result
        }

        guard let loginResult else {
            XCTFail("A retired handle must reject relogin before starting a URLSession task")
            return
        }
        switch loginResult {
        case .failure(.network(let message)):
            XCTAssertEqual(message, "服务器连接已关闭")
        default:
            XCTFail("A retired handle must fail closed")
        }
        XCTAssertTrue(original.isRetired)
    }

    func testWandEndpointPreservesBasePathRouteQueryAndWebSocketScheme() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.test:8443/reverse/wand/"))
        let apiURL = try XCTUnwrap(WandEndpoint.url(
            baseURL: baseURL,
            route: "/api/session-list?offset=20&limit=10&revision=a%2Fb"
        ))
        let apiComponents = try XCTUnwrap(URLComponents(url: apiURL, resolvingAgainstBaseURL: false))

        XCTAssertEqual(apiComponents.scheme, "https")
        XCTAssertEqual(apiComponents.host, "example.test")
        XCTAssertEqual(apiComponents.port, 8443)
        XCTAssertEqual(apiComponents.percentEncodedPath, "/reverse/wand/api/session-list")
        XCTAssertEqual(apiComponents.queryItems?.first(where: { $0.name == "offset" })?.value, "20")
        XCTAssertEqual(apiComponents.queryItems?.first(where: { $0.name == "limit" })?.value, "10")
        XCTAssertEqual(apiComponents.queryItems?.first(where: { $0.name == "revision" })?.value, "a/b")

        let socketURL = try XCTUnwrap(WandEndpoint.webSocketURL(
            baseURL: baseURL,
            route: "socket/events?ticket=endpoint-token"
        ))
        let socketComponents = try XCTUnwrap(URLComponents(url: socketURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(socketComponents.scheme, "wss")
        XCTAssertEqual(socketComponents.percentEncodedPath, "/reverse/wand/socket/events")
        XCTAssertEqual(socketComponents.queryItems?.first?.name, "ticket")
        XCTAssertEqual(socketComponents.queryItems?.first?.value, "endpoint-token")
    }

    func testEndpointScopeIncludesEffectivePortAndBasePathBoundary() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://scope.invalid:8443/reverse/wand"))
        let scope = try XCTUnwrap(WandEndpointScope(baseURL))

        XCTAssertTrue(scope.contains(try XCTUnwrap(URL(
            string: "https://scope.invalid:8443/reverse/wand/api/session-list"
        ))))
        XCTAssertFalse(scope.contains(try XCTUnwrap(URL(
            string: "https://scope.invalid:9443/reverse/wand/api/session-list"
        ))))
        XCTAssertFalse(scope.contains(try XCTUnwrap(URL(
            string: "https://scope.invalid:8443/reverse/wand-other/api/session-list"
        ))))
        XCTAssertFalse(scope.contains(try XCTUnwrap(URL(
            string: "http://scope.invalid:8443/reverse/wand/api/session-list"
        ))))
        XCTAssertFalse(scope.contains(try XCTUnwrap(URL(
            string: "https://scope.invalid:8443/reverse/wand/../outside"
        ))))
        XCTAssertFalse(scope.contains(try XCTUnwrap(URL(
            string: "https://scope.invalid:8443/reverse/wand/%2e%2e/outside"
        ))))
        XCTAssertFalse(scope.contains(try XCTUnwrap(URL(
            string: "https://scope.invalid:8443/reverse/wand/%252e%252e/outside"
        ))))

        let matchingSpace = URLProtectionSpace(
            host: "SCOPE.INVALID",
            port: 8443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let otherPortSpace = URLProtectionSpace(
            host: "scope.invalid",
            port: 9443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        XCTAssertTrue(scope.matches(matchingSpace))
        XCTAssertFalse(scope.matches(otherPortSpace))
    }

    func testEndpointQueryItemsPreserveDirectoryMetacharactersAsOneValue() throws {
        let rawPath = "/tmp/a&b+c=d?100%/你好"
        let url = try XCTUnwrap(WandEndpoint.url(
            baseURL: try XCTUnwrap(URL(string: "https://query.invalid/reverse/wand")),
            route: "/api/directory",
            queryItems: [URLQueryItem(name: "q", value: rawPath)]
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let encodedQuery = try XCTUnwrap(components.percentEncodedQuery)

        XCTAssertEqual(components.percentEncodedPath, "/reverse/wand/api/directory")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: rawPath)])
        XCTAssertFalse(encodedQuery.contains("a&b"))
        XCTAssertFalse(encodedQuery.contains("b+c"))
    }

    func testWebContentBoundaryAllowsOnlyEndpointHTTPAndWebSocketResources() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://web.invalid:8443/reverse/wand"))
        let json = try XCTUnwrap(WandEndpointContentBoundary.contentRuleListJSON(baseURL: baseURL))
        let rules = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual((rules.first?["action"] as? [String: String])?["type"], "block")

        func isAllowed(_ rawURL: String) throws -> Bool {
            var blocked = false
            for rule in rules {
                guard let trigger = rule["trigger"] as? [String: Any],
                      let filter = trigger["url-filter"] as? String,
                      let action = rule["action"] as? [String: String],
                      let actionType = action["type"] else { continue }
                let expression = try NSRegularExpression(pattern: filter, options: .caseInsensitive)
                let range = NSRange(rawURL.startIndex..<rawURL.endIndex, in: rawURL)
                guard expression.firstMatch(in: rawURL, range: range) != nil else { continue }
                if actionType == "block" {
                    blocked = true
                } else if actionType == "ignore-previous-rules" {
                    blocked = false
                }
            }
            return !blocked
        }

        XCTAssertTrue(try isAllowed("https://web.invalid:8443/reverse/wand/api/sessions"))
        XCTAssertTrue(try isAllowed("https://web.invalid:8443/reverse/wand/assets/app.min.js"))
        XCTAssertTrue(try isAllowed("wss://web.invalid:8443/reverse/wand/ws"))
        XCTAssertTrue(try isAllowed("blob:https://web.invalid:8443/fixture"))
        XCTAssertFalse(try isAllowed("https://web.invalid:9443/reverse/wand/api/sessions"))
        XCTAssertFalse(try isAllowed("https://web.invalid:8443/reverse/other/api/sessions"))
        XCTAssertFalse(try isAllowed("https://external.invalid/reverse/wand/api/sessions"))
        XCTAssertFalse(try isAllowed("https://web.invalid:8443/reverse/wand/../outside"))
        XCTAssertFalse(try isAllowed("https://web.invalid:8443/reverse/wand/%2e%2e/outside"))
        XCTAssertFalse(try isAllowed("https://web.invalid:8443/reverse/wand/a%2fb/../../outside"))
    }

    func testCanonicalEndpointRejectsAmbiguousProxyTraversal() {
        XCTAssertThrowsError(try ServerProfiles.canonicalBaseURL(
            "https://scope.invalid/reverse/wand/../outside"
        ))
        XCTAssertThrowsError(try ServerProfiles.canonicalBaseURL(
            "https://scope.invalid/reverse/wand/%2e%2e/outside"
        ))
        XCTAssertThrowsError(try ServerProfiles.canonicalBaseURL(
            "https://alice:secret@scope.invalid/reverse/wand"
        ))
        XCTAssertTrue(WandAuth.candidateURLs(
            from: "https://alice:secret@scope.invalid/reverse/wand"
        ).isEmpty)
    }

    func testSessionCheckRequiresWandJSONAndSameEndpointResponse() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://probe.invalid:8443/wand"))
        let validURL = try XCTUnwrap(URL(string: "https://probe.invalid:8443/wand/api/session-check"))
        let crossURL = try XCTUnwrap(URL(string: "https://other.invalid/api/session-check"))
        let validResponse = try XCTUnwrap(HTTPURLResponse(
            url: validURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let crossResponse = try XCTUnwrap(HTTPURLResponse(
            url: crossURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertTrue(WandAuth.isValidSessionCheckResponse(
            data: Data(#"{"authed":false}"#.utf8),
            response: validResponse,
            baseURL: baseURL
        ))
        XCTAssertFalse(WandAuth.isValidSessionCheckResponse(
            data: Data("<html>router</html>".utf8),
            response: validResponse,
            baseURL: baseURL
        ))
        XCTAssertFalse(WandAuth.isValidSessionCheckResponse(
            data: Data(#"{"authed":true}"#.utf8),
            response: crossResponse,
            baseURL: baseURL
        ))
    }

    func testCancelledConnectionAttemptCannotFinishOrCommit() {
        let attempt = WandAuth.ConnectionAttempt()
        var cleaned = false
        var committed = false
        attempt.setCleanup { cleaned = true }

        attempt.cancel()

        XCTAssertTrue(cleaned)
        XCTAssertTrue(attempt.isCancelled())
        XCTAssertFalse(attempt.finish { committed = true })
        XCTAssertFalse(committed)
    }

    func testServerFileLinksPreserveNumericColonNamesAndParseQuotedSemicolons() {
        XCTAssertEqual(WandServerFileLink.serverPath("/tmp/report:2025"), "/tmp/report:2025")
        XCTAssertEqual(
            WandServerFileLink.serverPath("file:///tmp/report%3A2025"),
            "/tmp/report:2025"
        )
        XCTAssertEqual(WandServerFileLink.serverPath("/tmp/source.swift#L12C3"), "/tmp/source.swift")
        XCTAssertEqual(
            WandServerFileLink.fileNameParameter(
                in: #"attachment; filename="report;2025.pdf""#
            ),
            "report;2025.pdf"
        )
        XCTAssertEqual(
            WandServerFileLink.fileNameParameter(
                in: "attachment; filename=legacy.txt; filename*=UTF-8''%E6%8A%A5%E5%91%8A.pdf"
            ),
            "报告.pdf"
        )
    }

    func testNewSessionEndpointMutationsAreFIFOAndDropCancelledWaiters() async throws {
        let queue = NewSessionEndpointMutationQueue()
        let endpointID = UUID().uuidString
        let firstStarted = AlignmentAsyncGate()
        let releaseFirst = AlignmentAsyncGate()
        var events: [String] = []

        let first = Task { @MainActor in
            try await queue.run(endpointID: endpointID) {
                events.append("first-start")
                await firstStarted.open()
                await releaseFirst.wait()
                events.append("first-end")
            }
        }
        await firstStarted.wait()

        let cancelled = Task { @MainActor in
            try await queue.run(endpointID: endpointID) {
                events.append("cancelled-operation")
            }
        }
        while queue.pendingOperationCount(endpointID: endpointID) < 1 {
            await Task.yield()
        }
        cancelled.cancel()

        let last = Task { @MainActor in
            try await queue.run(endpointID: endpointID) {
                events.append("last")
            }
        }
        while queue.pendingOperationCount(endpointID: endpointID) < 2 {
            await Task.yield()
        }
        XCTAssertEqual(events, ["first-start"])

        await releaseFirst.open()
        try await first.value
        do {
            try await cancelled.value
            XCTFail("A cancelled queued snapshot must not start an HTTP mutation")
        } catch is CancellationError {
            // Expected: cancellation is honored only while the mutation is still queued.
        }
        try await last.value
        XCTAssertEqual(events, ["first-start", "first-end", "last"])
    }

    // MARK: - Provider and activity parity

    func testPiProviderRunnerModelsDefaultsAndShellLabels() throws {
        XCTAssertEqual(WandProvider(normalizing: "PI-CLI-JSON"), .pi)
        XCTAssertEqual(WandProvider.pi.title, "Pi")
        XCTAssertEqual(WandProvider.pi.structuredRunner, "pi-cli-json")
        XCTAssertEqual(WandProvider.pi.supportedModeIDs, ["default", "full-access", "managed"])
        XCTAssertEqual(WandProvider.pi.clamp(mode: "native"), "managed")

        let models = try decode(
            ModelsResponse.self,
            from: #"""
            {
              "models": [{"id":"claude","label":"Claude"}],
              "piModels": [
                {"id":"default","label":"跟随 Pi 默认","alias":true},
                {"id":"openai/gpt-5.2","label":"GPT-5.2"}
              ],
              "defaultPiModel":"legacy-pi",
              "defaultModels":{"pi":"openai/gpt-5.2"}
            }
            """#
        )
        XCTAssertEqual(models.models(for: .pi).map(\.id), ["default", "openai/gpt-5.2"])
        XCTAssertEqual(models.defaultPiModel, "legacy-pi")
        XCTAssertEqual(models.defaultModelId(for: "pi"), "openai/gpt-5.2")

        let legacyModels = try decode(
            ModelsResponse.self,
            from: #"{"piModels":[],"defaultPiModel":"legacy-pi"}"#
        )
        XCTAssertEqual(legacyModels.defaultModelId(for: "pi"), "legacy-pi")

        let config = try decode(
            ServerConfigInfo.self,
            from: #"{"defaultProvider":"pi","defaultPiModel":"pi-config","defaultModels":{"pi":"pi-current"}}"#
        )
        XCTAssertEqual(config.defaultModelId(for: "pi"), "pi-current")

        let shell = try decode(
            SessionSnapshot.self,
            from: #"{"id":"shell","sessionKind":"pty","provider":null}"#
        )
        let explicitTerminal = try decode(
            SessionSnapshot.self,
            from: #"{"id":"terminal","sessionKind":"pty","provider":"terminal"}"#
        )
        let pi = try decode(
            SessionSnapshot.self,
            from: #"{"id":"pi","sessionKind":"structured","provider":"pi"}"#
        )
        XCTAssertEqual(shell.providerLabel, "终端")
        XCTAssertEqual(explicitTerminal.providerLabel, "终端")
        XCTAssertEqual(pi.providerLabel, "Pi")
    }

    func testSparseServerConfigUsesProtocolDefaultsInsteadOfPriorEndpointState() throws {
        let first = try decode(
            ServerConfigInfo.self,
            from: #"{"defaultMode":"full-access","defaultThinkingEffort":"high"}"#
        )
        let second = try decode(ServerConfigInfo.self, from: "{}")

        XCTAssertEqual(first.resolvedDefaultMode, "full-access")
        XCTAssertEqual(first.resolvedDefaultThinkingEffort, "high")
        XCTAssertEqual(second.resolvedDefaultMode, "managed")
        XCTAssertEqual(second.resolvedDefaultThinkingEffort, "off")
    }

    func testHistoryAPIProviderAndIdentityIncludeProviderNamespace() throws {
        let cases: [(raw: String?, expected: String)] = [
            (nil, "claude"),
            ("CODEX", "codex"),
            ("open_code", "opencode"),
            ("GROK", "grok"),
            ("qodercli", "qoder"),
            ("pi", "pi"),
            ("future-provider", "claude"),
        ]

        var identities = Set<String>()
        for item in cases {
            let providerJSON = item.raw.map { ",\"provider\":\"\($0)\"" } ?? ""
            let history = try decode(
                HistorySession.self,
                from: "{\"claudeSessionId\":\"shared-native-id\",\"cwd\":\"/repo\",\"firstUserMessage\":\"Hello\"\(providerJSON)}"
            )
            XCTAssertEqual(history.apiProvider, item.expected)
            XCTAssertEqual(history.id, "\(item.expected):shared-native-id")
            identities.insert(history.id)
        }

        // Unknown and missing providers intentionally share Claude's compatibility namespace.
        XCTAssertEqual(identities.count, 6)
    }

    func testQuickActionsRespectTheirTargetServer() {
        let targeted = QuickAction.openSession(id: "session-1", serverID: "server-a")
        let legacy = QuickAction.openSession(id: "session-1", serverID: nil)

        XCTAssertEqual(targeted.targetServerID, "server-a")
        XCTAssertTrue(targeted.belongs(to: "server-a"))
        XCTAssertFalse(targeted.belongs(to: "server-b"))
        XCTAssertNil(legacy.targetServerID)
        XCTAssertTrue(legacy.belongs(to: "server-a"))
        XCTAssertTrue(QuickAction.newSession.belongs(to: "server-b"))

        XCTAssertFalse(quickActionRequiresRootSessionRouting(
            .newSession,
            rootIsSessions: true,
            hasPresentedSurface: false
        ))
        XCTAssertTrue(quickActionRequiresRootSessionRouting(
            .newSession,
            rootIsSessions: false,
            hasPresentedSurface: false
        ))
        XCTAssertTrue(quickActionRequiresRootSessionRouting(
            targeted,
            rootIsSessions: true,
            hasPresentedSurface: true
        ))
        XCTAssertTrue(quickActionRequiresRootSessionRouting(
            targeted,
            rootIsSessions: false,
            hasPresentedSurface: false
        ))

        for state in [
            (rootIsSessions: true, hasPresentedSurface: false),
            (rootIsSessions: false, hasPresentedSurface: false),
            (rootIsSessions: true, hasPresentedSurface: true),
        ] {
            let rootOwns = quickActionRequiresRootSessionRouting(
                targeted,
                rootIsSessions: state.rootIsSessions,
                hasPresentedSurface: state.hasPresentedSurface
            )
            let listOwns = sessionListQuickActionsEnabled(
                rootIsSessions: state.rootIsSessions,
                hasPresentedSurface: state.hasPresentedSurface
            )
            XCTAssertNotEqual(rootOwns, listOwns, "Exactly one router must own the action")
        }
    }

    func testSessionActivityPiAndServerIDRoundTripAndLegacyDecode() throws {
        let entry = SessionActivityAttributes.SessionEntry(
            id: "pi-session",
            serverID: "server-pi",
            title: "Pi task",
            providerRaw: "pi",
            stateRaw: "responding",
            taskTitle: "Use tools",
            queuedCount: 2,
            startedAt: Date(timeIntervalSinceReferenceDate: 12_345)
        )

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SessionActivityAttributes.SessionEntry.self, from: encoded)
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.serverID, "server-pi")
        XCTAssertEqual(decoded.providerText, "Pi")
        XCTAssertEqual(decoded.providerSymbol, "pi")

        let legacy = try decode(
            SessionActivityAttributes.SessionEntry.self,
            from: #"{"id":"legacy","title":"Old","providerRaw":"claude","stateRaw":"done","taskTitle":null,"queuedCount":0}"#
        )
        XCTAssertNil(legacy.serverID)
    }

    // MARK: - Unified session list protocol

    func testSessionListPageAndDirectoryTreeDecodeManagedAndRecoverableEntries() throws {
        let page = try decode(
            SessionListPage.self,
            from: Self.pageJSON
        )

        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.revision, "revision-1")
        XCTAssertEqual(page.entries.map(\.id), ["managed-s1", "recoverable-pi-native-1"])
        XCTAssertEqual(page.entries[0].session?.providerLabel, "Pi")
        XCTAssertEqual(page.entries[1].history?.apiProvider, "pi")
        XCTAssertEqual(page.entries[1].cwd, "/repo/tools")

        let tree = try decode(
            SessionDirectoryTreeResponse.self,
            from: Self.directoryTreeJSON(customName: "iOS 对齐")
        )
        let root = try XCTUnwrap(tree.roots.first)
        XCTAssertEqual(tree.totalSessions, 2)
        XCTAssertEqual(tree.directoryCount, 2)
        XCTAssertEqual(tree.revision, "revision-1")
        XCTAssertEqual(tree.treeRevision, "tree-1")
        XCTAssertEqual(root.displayName, "iOS 对齐")
        XCTAssertEqual(root.directCount, 1)
        XCTAssertEqual(root.totalCount, 2)
        XCTAssertTrue(root.containsSession("s1"))
        XCTAssertFalse(root.containsSession("missing"))
        XCTAssertEqual(root.children.first?.entries.first?.history?.id, "pi:native-1")
    }

    func testSessionListPageRejectsInvalidRangesRevisionsAndDuplicateKeys() {
        let invalidPages = [
            #"{"entries":[],"offset":-1,"total":0,"revision":"r"}"#,
            #"{"entries":[],"offset":2,"total":1,"revision":"r"}"#,
            #"{"entries":[{"type":"recoverable","key":"a","sortTimestamp":1,"history":{"claudeSessionId":"a","cwd":"/","firstUserMessage":"a"}}],"offset":1,"total":1,"revision":"r"}"#,
            #"{"entries":[],"offset":0,"total":0,"revision":""}"#,
            #"{"entries":[{"type":"recoverable","key":"same","sortTimestamp":2,"history":{"claudeSessionId":"a","cwd":"/","firstUserMessage":"a"}},{"type":"recoverable","key":"same","sortTimestamp":1,"history":{"claudeSessionId":"b","cwd":"/","firstUserMessage":"b"}}],"offset":0,"total":2,"revision":"r"}"#,
            #"{"entries":[{"type":"recoverable","key":"","sortTimestamp":1,"history":{"claudeSessionId":"a","cwd":"/","firstUserMessage":"a"}}],"offset":0,"total":1,"revision":"r"}"#,
        ]

        for json in invalidPages {
            XCTAssertThrowsError(try decode(SessionListPage.self, from: json), json)
        }
    }

    func testDirectoryNameValidationCountsUnicodeCodePointsAndRejectsControls() throws {
        // One grapheme, four Unicode scalars: person + skin tone + ZWJ + laptop.
        let exactlyEightyCodePoints = String(repeating: "🧑🏽‍💻", count: 20)
        let overEightyCodePoints = String(repeating: "🧑🏽‍💻", count: 21)
        XCTAssertEqual(exactlyEightyCodePoints.unicodeScalars.count, 80)
        XCTAssertEqual(
            try SessionDirectoryNameValidation.normalized("  \(exactlyEightyCodePoints)  "),
            exactlyEightyCodePoints
        )
        XCTAssertEqual(try SessionDirectoryNameValidation.normalized("  "), "")

        XCTAssertThrowsError(try SessionDirectoryNameValidation.normalized(overEightyCodePoints)) { error in
            XCTAssertEqual(error as? SessionDirectoryNameValidation.ValidationError, .tooLong)
        }
        for invalid in ["line one\nline two", "tab\tinside", "left\u{2028}right", "nul\u{0000}byte"] {
            XCTAssertThrowsError(try SessionDirectoryNameValidation.normalized(invalid)) { error in
                XCTAssertEqual(
                    error as? SessionDirectoryNameValidation.ValidationError,
                    .containsControlCharacter
                )
            }
        }
    }

    // MARK: - Session list state machine

    func testSessionListStoreRefreshLoadMoreAnd409Recovery() async throws {
        let first = try recoverableEntry(key: "first", nativeID: "h1", provider: "claude", timestamp: 40)
        let second = try recoverableEntry(key: "second", nativeID: "h2", provider: "codex", timestamp: 30)
        let third = try recoverableEntry(key: "third", nativeID: "h3", provider: "opencode", timestamp: 20)
        let replacement = try recoverableEntry(key: "replacement", nativeID: "h4", provider: "qoder", timestamp: 50)
        let service = MockSessionListService()
        service.listResponses = [
            .page(SessionListPage(entries: [first, second], offset: 0, total: 4, revision: "r1")),
            .page(SessionListPage(entries: [third], offset: 2, total: 4, revision: "r1")),
            .failure(WandAPI.APIError.server(status: 409, message: "revision changed")),
            .page(SessionListPage(entries: [replacement], offset: 0, total: 1, revision: "r2")),
        ]
        let store = SessionListStore(api: service, serverID: "server-list")

        let loaded = await store.load()
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.entries.map(\.key), ["first", "second"])
        XCTAssertTrue(store.canLoadMore)

        let loadedMore = await store.loadMore()
        XCTAssertTrue(loadedMore)
        XCTAssertEqual(store.entries.map(\.key), ["first", "second", "third"])
        XCTAssertTrue(store.canLoadMore)

        // A stale load-more revision is recovered by an immediate first-page refresh.
        let recoveredFromConflict = await store.loadMore()
        XCTAssertTrue(recoveredFromConflict)
        XCTAssertEqual(store.entries.map(\.key), ["replacement"])
        XCTAssertFalse(store.canLoadMore)
        XCTAssertNil(store.loadError)

        XCTAssertEqual(service.listRequests, [
            .init(offset: 0, limit: SessionListStore.pageSize, revision: nil),
            .init(offset: 2, limit: SessionListStore.pageSize, revision: "r1"),
            .init(offset: 3, limit: SessionListStore.pageSize, revision: "r1"),
            .init(offset: 0, limit: SessionListStore.pageSize, revision: nil),
        ])
    }

    func testSessionListStoreRenamesRefreshesAndRollsBackDirectoryTree() async throws {
        let service = MockSessionListService()
        service.directoryResponses = [
            .tree(try decode(
                SessionDirectoryTreeResponse.self,
                from: Self.directoryTreeJSON(customName: nil)
            )),
            .tree(try decode(
                SessionDirectoryTreeResponse.self,
                from: Self.directoryTreeJSON(customName: "新名称")
            )),
        ]
        let store = SessionListStore(api: service, serverID: "server-directory")

        let loadedDirectories = await store.loadDirectories()
        XCTAssertTrue(loadedDirectories)
        XCTAssertEqual(store.directoryTree?.roots.first?.displayName, "wand")

        let renamed = await store.renameDirectory(path: "  /repo/wand  ", name: "  新名称  ")
        XCTAssertTrue(renamed)
        XCTAssertEqual(service.renameRequests.count, 1)
        XCTAssertEqual(service.renameRequests.first?.path, "/repo/wand")
        XCTAssertEqual(service.renameRequests.first?.name, "新名称")
        XCTAssertEqual(store.directoryTree?.roots.first?.customName, "新名称")

        service.renameError = MockSessionListService.MockError.renameDenied
        let rejectedRename = await store.renameDirectory(path: "/repo/wand", name: "不会保留")
        XCTAssertFalse(rejectedRename)
        XCTAssertEqual(store.directoryTree?.roots.first?.customName, "新名称")
        XCTAssertNotNil(store.directoryError)

        let callsBeforeInvalidName = service.renameRequests.count
        let invalidRename = await store.renameDirectory(
            path: "/repo/wand",
            name: String(repeating: "界", count: 81)
        )
        XCTAssertFalse(invalidRename)
        XCTAssertEqual(service.renameRequests.count, callsBeforeInvalidName)
    }

    func testSessionListStoreRestoresAndDeletesUsingProviderAwareRoutes() async throws {
        let managed = try managedEntry(key: "managed-old", sessionID: "managed-old", provider: "claude")
        let openCode = try recoverableEntry(
            key: "recoverable-open",
            nativeID: "open-native",
            provider: "opencode",
            timestamp: 20
        )
        let qoder = try recoverableEntry(
            key: "recoverable-qoder",
            nativeID: "qoder-native",
            provider: "qodercli",
            timestamp: 10
        )
        let resumedSnapshot = try decode(
            SessionSnapshot.self,
            from: #"{"id":"resumed-open","sessionKind":"structured","provider":"opencode","status":"idle"}"#
        )
        let resumed = SessionListEntry.managed(
            key: "session-resumed-open",
            sortTimestamp: 30,
            session: resumedSnapshot
        )
        let service = MockSessionListService()
        service.resumeResult = resumedSnapshot
        service.listResponses = [
            .page(SessionListPage(entries: [managed, openCode, qoder], offset: 0, total: 3, revision: "r1")),
            .page(SessionListPage(entries: [resumed, managed, qoder], offset: 0, total: 3, revision: "r2")),
            .page(SessionListPage(entries: [resumed], offset: 0, total: 1, revision: "r3")),
        ]
        let store = SessionListStore(api: service, serverID: "server-actions")

        let loaded = await store.load()
        XCTAssertTrue(loaded)
        let history = try XCTUnwrap(openCode.history)
        let restored = await store.restore(history)
        XCTAssertEqual(restored?.id, "resumed-open")
        XCTAssertEqual(service.resumedHistories.map(\.id), ["opencode:open-native"])
        XCTAssertEqual(store.entries.map(\.key), ["session-resumed-open", "managed-old", "recoverable-qoder"])

        let deleteTargets = store.entries.filter {
            $0.session?.id == "managed-old" || $0.history?.id == "qoder:qoder-native"
        }
        let deleted = await store.delete(deleteTargets)
        XCTAssertTrue(deleted)
        XCTAssertEqual(service.deletedSessionIDs, ["managed-old"])
        XCTAssertEqual(service.deletedHistoryBatches.count, 1)
        XCTAssertEqual(service.deletedHistoryBatches.first?.provider, "qoder")
        XCTAssertEqual(service.deletedHistoryBatches.first?.ids, ["qoder-native"])
        XCTAssertEqual(store.entries.map(\.key), ["session-resumed-open"])
    }

    func testSessionListStoreCoalescesPaginationAndDuplicateRestoreRequests() async throws {
        let initial = try (0..<20).map { index in
            try recoverableEntry(
                key: "initial-\(index)",
                nativeID: "initial-\(index)",
                provider: "claude",
                timestamp: Double(100 - index)
            )
        }
        let next = try recoverableEntry(
            key: "next",
            nativeID: "next",
            provider: "opencode",
            timestamp: 1
        )
        let resumedSnapshot = try decode(
            SessionSnapshot.self,
            from: #"{"id":"resumed-once","sessionKind":"structured","provider":"claude"}"#
        )
        let resumedEntry = SessionListEntry.managed(
            key: "session-resumed-once",
            sortTimestamp: 200,
            session: resumedSnapshot
        )
        let service = MockSessionListService()
        service.listResponses = [
            .page(SessionListPage(entries: initial, offset: 0, total: 40, revision: "r1")),
            .page(SessionListPage(entries: [next], offset: 20, total: 21, revision: "r1")),
            .page(SessionListPage(entries: [resumedEntry, next], offset: 0, total: 2, revision: "r2")),
        ]
        let store = SessionListStore(api: service, serverID: "server-coalesce")
        let loaded = await store.load()
        XCTAssertTrue(loaded)

        service.listDelayNanoseconds = 50_000_000
        let paginationTasks = (0..<4).map { _ in Task { await store.loadMore() } }
        var paginationResults: [Bool] = []
        for task in paginationTasks { paginationResults.append(await task.value) }
        XCTAssertEqual(paginationResults.filter { $0 }.count, 1)
        XCTAssertEqual(service.listRequests.filter { $0.offset == 20 }.count, 1)

        let history = try XCTUnwrap(initial.first?.history)
        service.resumeResult = resumedSnapshot
        service.resumeDelayNanoseconds = 50_000_000
        let firstRestore = Task { await store.restore(history) }
        let secondRestore = Task { await store.restore(history) }
        let restoreResults = [await firstRestore.value, await secondRestore.value]
        XCTAssertEqual(restoreResults.compactMap { $0 }.count, 1)
        XCTAssertEqual(service.resumedHistories.map(\.id), [history.id])
    }

    func testSessionListDeleteFailureRestoresPaginationCursorAndRevision() async throws {
        let entries = try (0..<40).map { index in
            try managedEntry(
                key: "managed-\(index)",
                sessionID: "session-\(index)",
                provider: "claude"
            )
        }
        let service = MockSessionListService()
        service.listResponses = [
            .page(SessionListPage(entries: entries, offset: 0, total: 40, revision: "stable")),
            .failure(MockSessionListService.MockError.refreshDenied),
        ]
        service.deleteSessionError = MockSessionListService.MockError.deleteDenied
        let store = SessionListStore(api: service, serverID: "server-rollback")

        let loaded = await store.load()
        XCTAssertTrue(loaded)
        XCTAssertFalse(store.canLoadMore)
        let deleted = await store.delete(store.entries)
        XCTAssertFalse(deleted)
        XCTAssertEqual(store.entries.map(\.key), entries.map(\.key))
        XCTAssertEqual(store.total, 40)
        XCTAssertFalse(store.canLoadMore, "回滚后 nextOffset 必须恢复到已加载的 40")
    }

    // MARK: - Fixtures

    private static let pageJSON = #"""
    {
      "entries": [
        {
          "type": "managed",
          "key": "managed-s1",
          "sortTimestamp": 20,
          "session": {
            "id": "s1",
            "sessionKind": "structured",
            "provider": "pi",
            "cwd": "/repo",
            "status": "running"
          }
        },
        {
          "type": "recoverable",
          "key": "recoverable-pi-native-1",
          "sortTimestamp": 10,
          "history": {
            "claudeSessionId": "native-1",
            "cwd": "/repo/tools",
            "firstUserMessage": "Continue",
            "provider": "pi"
          }
        }
      ],
      "offset": 0,
      "total": 2,
      "revision": "revision-1"
    }
    """#

    private static func directoryTreeJSON(customName: String?) -> String {
        let customNameJSON = customName.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "roots": [
            {
              "path": "/repo/wand",
              "name": "wand",
              "customName": \(customNameJSON),
              "synthetic": false,
              "directCount": 1,
              "totalCount": 2,
              "latestTimestamp": 20,
              "entries": [
                {
                  "type": "managed",
                  "key": "managed-s1",
                  "sortTimestamp": 20,
                  "session": {"id":"s1","sessionKind":"structured","provider":"pi","cwd":"/repo/wand"}
                }
              ],
              "children": [
                {
                  "path": "/repo/wand/tools",
                  "name": "tools",
                  "synthetic": false,
                  "directCount": 1,
                  "totalCount": 1,
                  "latestTimestamp": 10,
                  "entries": [
                    {
                      "type": "recoverable",
                      "key": "recoverable-pi-native-1",
                      "sortTimestamp": 10,
                      "history": {
                        "claudeSessionId":"native-1",
                        "cwd":"/repo/wand/tools",
                        "firstUserMessage":"Continue",
                        "provider":"pi"
                      }
                    }
                  ],
                  "children": []
                }
              ]
            }
          ],
          "totalSessions": 2,
          "directoryCount": 2,
          "revision": "revision-1",
          "treeRevision": "tree-1"
        }
        """
    }

    private func managedEntry(
        key: String,
        sessionID: String,
        provider: String
    ) throws -> SessionListEntry {
        let session = try decode(
            SessionSnapshot.self,
            from: "{\"id\":\"\(sessionID)\",\"sessionKind\":\"structured\",\"provider\":\"\(provider)\",\"status\":\"idle\"}"
        )
        return .managed(key: key, sortTimestamp: 1, session: session)
    }

    private func recoverableEntry(
        key: String,
        nativeID: String,
        provider: String,
        timestamp: Double
    ) throws -> SessionListEntry {
        let history = try decode(
            HistorySession.self,
            from: "{\"claudeSessionId\":\"\(nativeID)\",\"cwd\":\"/repo\",\"firstUserMessage\":\"Continue\",\"provider\":\"\(provider)\"}"
        )
        return .recoverable(key: key, sortTimestamp: timestamp, history: history)
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(json.data(using: .utf8)))
    }
}

private final class MockSessionListService: SessionListServing {
    struct ListRequest: Equatable {
        let offset: Int
        let limit: Int
        let revision: String?
    }

    struct RenameRequest: Equatable {
        let path: String
        let name: String
    }

    struct HistoryBatch: Equatable {
        let provider: String
        let ids: [String]
    }

    enum MockError: LocalizedError {
        case unexpectedCall(String)
        case renameDenied
        case deleteDenied
        case refreshDenied

        var errorDescription: String? {
            switch self {
            case .unexpectedCall(let name): return "Unexpected mock call: \(name)"
            case .renameDenied: return "Rename denied"
            case .deleteDenied: return "Delete denied"
            case .refreshDenied: return "Refresh denied"
            }
        }
    }

    enum ListResponse {
        case page(SessionListPage)
        case failure(Error)
    }

    enum DirectoryResponse {
        case tree(SessionDirectoryTreeResponse)
        case failure(Error)
    }

    var listResponses: [ListResponse] = []
    var directoryResponses: [DirectoryResponse] = []
    var resumeResult: SessionSnapshot?
    var renameError: Error?
    var deleteSessionError: Error?
    var listDelayNanoseconds: UInt64 = 0
    var resumeDelayNanoseconds: UInt64 = 0

    private(set) var listRequests: [ListRequest] = []
    private(set) var renameRequests: [RenameRequest] = []
    private(set) var resumedHistories: [HistorySession] = []
    private(set) var deletedSessionIDs: [String] = []
    private(set) var deletedHistoryBatches: [HistoryBatch] = []

    func fetchSessionList(offset: Int, limit: Int, revision: String?) async throws -> SessionListPage {
        listRequests.append(.init(offset: offset, limit: limit, revision: revision))
        if listDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: listDelayNanoseconds)
        }
        guard !listResponses.isEmpty else { throw MockError.unexpectedCall("fetchSessionList") }
        switch listResponses.removeFirst() {
        case .page(let page): return page
        case .failure(let error): throw error
        }
    }

    func fetchSessionDirectories() async throws -> SessionDirectoryTreeResponse {
        guard !directoryResponses.isEmpty else {
            throw MockError.unexpectedCall("fetchSessionDirectories")
        }
        switch directoryResponses.removeFirst() {
        case .tree(let tree): return tree
        case .failure(let error): throw error
        }
    }

    func renameSessionDirectory(path: String, name: String) async throws {
        renameRequests.append(.init(path: path, name: name))
        if let renameError { throw renameError }
    }

    func resumeHistory(_ history: HistorySession) async throws -> SessionSnapshot {
        resumedHistories.append(history)
        if resumeDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: resumeDelayNanoseconds)
        }
        guard let resumeResult else { throw MockError.unexpectedCall("resumeHistory") }
        return resumeResult
    }

    func deleteSession(id: String) async throws {
        deletedSessionIDs.append(id)
        if let deleteSessionError { throw deleteSessionError }
    }

    func deleteHistoryBatch(provider: String, ids: [String]) async throws {
        deletedHistoryBatches.append(.init(provider: provider, ids: ids))
    }

    func fetchManagedSessionsForPresence() async throws -> [SessionSnapshot] {
        throw MockError.unexpectedCall("fetchManagedSessionsForPresence")
    }
}

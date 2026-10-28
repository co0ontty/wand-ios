import XCTest
import SwiftUI
import UIKit
@testable import Wand

private func parityDecode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONDecoder().decode(type, from: Data(text.utf8)) }
private let parityURL = URL(string: "http://127.0.0.1:9")!
private func parityReceipt(_ state: String = "accepted", id: String = "req", conversation: String = "dm_e", extra: String = "") throws -> ConversationReceipt {
    try parityDecode(ConversationReceipt.self, "{\"requestId\":\"\(id)\",\"state\":\"\(state)\",\"conversationId\":\"\(conversation)\"\(extra)}")
}

@MainActor
private final class ConversationFake: ConversationService {
    var rows: [ConversationInstance] = []
    var people: [SiliconEmployee] = []
    var teams: [ContactTeam] = []
    var detail = try! parityDecode(ConversationInstance.self, #"{"id":"dm_e","kind":"dm","title":"员工"}"#)
    var posts: [(String, [String: Any])] = []
    var pending: [String] = []
    var receipt = try! parityReceipt()
    var failure: Error?
    var postContinuation: CheckedContinuation<ConversationReceipt, Error>?
    var suspendPost = false
    var suspendLoads = false
    var loads: [CheckedContinuation<ConversationInstance, Error>] = []
    func listContactEmployees() async throws -> [SiliconEmployee] { people }
    func listContactTeams() async throws -> [ContactTeam] { teams }
    func listWorkspaces() async throws -> [Workspace] { [] }
    func conversations() async throws -> [ConversationInstance] { rows }
    func conversation(_ id: String) async throws -> ConversationInstance {
        if suspendLoads { return try await withCheckedThrowingContinuation { loads.append($0) } }
        return detail
    }
    func conversationPost(path: String, body: [String: Any]) async throws -> ConversationReceipt {
        posts.append((path, body))
        if suspendPost { return try await withCheckedThrowingContinuation { postContinuation = $0 } }
        if let failure { throw failure }
        return receipt
    }
    func conversationReceipt(_ id: String) async throws -> ConversationReceipt { receipt }
    func pendingConversationRequests() async -> [String] { pending }
    var managementFailure: Error?
    var applyManagementPatches = false
    var listPatches: [(String, [String: Bool])] = []
    var deletedIDs: [String] = []
    func updateConversationListState(_ id: String, patch: [String: Bool]) async throws -> ConversationInstance {
        listPatches.append((id, patch))
        if let managementFailure { throw managementFailure }
        if applyManagementPatches {
            var body: [String: Any] = ["id": detail.id, "kind": detail.kind, "title": detail.title]
            if patch["dissolved"] == true { body["dissolvedAt"] = "2026-10-24T10:00:00Z" }
            detail = try JSONDecoder().decode(ConversationInstance.self, from: JSONSerialization.data(withJSONObject: body))
            rows = [detail]
        }
        return detail
    }
    func deleteConversation(_ id: String) async throws {
        deletedIDs.append(id)
        if let managementFailure { throw managementFailure }
    }
}

@MainActor
private final class FilesFake: SessionFilesService {
    var preview = SessionFilePreview(path: "/work/a.txt", name: "a.txt", kind: "text", size: 3, mtime: "t1", content: "old")
    var writeFailure: Error?
    var writeContinuation: CheckedContinuation<SessionFileWriteResult, Error>?
    var writes: [(SessionFilePreview, String)] = []
    var previews: [String] = []
    var suspendWrites = false
    func listDirectory(_ query: String) async throws -> DirectoryListing { try parityDecode(DirectoryListing.self, #"{"items":[]}"#) }
    func previewFile(_ path: String) async throws -> SessionFilePreview { previews.append(path); return preview }
    func writeFile(_ file: SessionFilePreview, content: String) async throws -> SessionFileWriteResult {
        writes.append((file, content))
        if suspendWrites { return try await withCheckedThrowingContinuation { writeContinuation = $0 } }
        if let writeFailure { throw writeFailure }
        return SessionFileWriteResult(ok: true, size: content.utf8.count, mtime: "t2")
    }
}

@MainActor
private final class PiFake: PiResourcesService {
    var response = try! parityDecode(PiResourcesResponse.self, #"{"settings":{"resources":{"skills":[],"mcpServers":[]}},"resourceCatalog":{"supported":true,"skills":[{"id":"skill","name":"Installed Skill"}],"mcpServers":[{"id":"mcp","name":"Installed MCP"}]},"controls":{"codemodeOverride":true,"codemodeOnly":false},"skillLocksAvailable":true,"autoResourcesAvailable":true}"#)
    var failure: Error?
    var bodies: [[String: Any]] = []
    var ack: PiResourcesResponse.Settings?
    func piResources(_ id: String) async throws -> PiResourcesResponse { response }
    func savePiResources(_ id: String, body: [String: Any]) async throws -> PiResourcesResponse.Settings {
        bodies.append(body); if let failure { throw failure }; return ack ?? response.settings
    }
}

@MainActor
private final class PiResourceContractService: PiResourcesService {
    var response: PiResourcesResponse
    var ack: PiResourcesResponse.Settings?
    var bodies: [[String: Any]] = []
    var suspendSave = false
    var continuation: CheckedContinuation<PiResourcesResponse.Settings, Error>?
    init(_ response: PiResourcesResponse) { self.response = response }
    func piResources(_ id: String) async throws -> PiResourcesResponse { response }
    func savePiResources(_ id: String, body: [String: Any]) async throws -> PiResourcesResponse.Settings {
        bodies.append(body)
        if suspendSave { return try await withCheckedThrowingContinuation { continuation = $0 } }
        if let ack { return ack }
        let saved = try JSONDecoder().decode(PiResourcesResponse.Settings.self, from: JSONSerialization.data(withJSONObject: body))
        response.settings = saved
        return saved
    }
}

@MainActor
final class PiResourcesTests: XCTestCase {
    private func fixture(skills: [String] = ["live", "removed"], locks: [String] = ["live", "removed"],
                         installed: [String] = ["live"], mcp: [String] = ["mcp"]) throws -> PiResourcesResponse {
        try JSONDecoder().decode(PiResourcesResponse.self, from: JSONSerialization.data(withJSONObject: [
            "settings": ["resources": ["skills": skills, "mcpServers": mcp], "lockedSkills": locks,
                         "autoResources": false],
            "resourceCatalog": ["supported": true,
                                "skills": installed.map { ["id": $0, "name": "可用技能 " + $0] },
                                "mcpServers": [["id": "mcp", "name": "可用 MCP"]]],
            "controls": ["codemodeOverride": true, "codemodeOnly": false],
            "skillLocksAvailable": true, "autoResourcesAvailable": true
        ]))
    }
    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Pi resource operation did not settle")
        throw URLError(.timedOut)
    }
    func testUnlockRemovedSkillDropsSelectionAndLockButKeepsInstalledSkills() async throws {
        let service = PiResourceContractService(try fixture())
        let store = PiResourcesStore(sessionID: "fixture", service: service); await store.load()
        store.setSkill("removed", mode: "on")
        XCTAssertEqual(store.draft.resources?.skills, ["live"])
        XCTAssertEqual(store.draft.lockedSkills, ["live"])
        XCTAssertEqual(store.draft.resources?.mcpServers, ["mcp"])
        store.save(); try await settle { store.phase == .sent }
        XCTAssertFalse(store.dirty); XCTAssertTrue(store.unavailableSkillIDs.isEmpty)
    }
    func testUnlockInstalledSkillPreservesSelectionAndOtherMissingReferences() async throws {
        let service = PiResourceContractService(try fixture())
        let store = PiResourcesStore(sessionID: "fixture", service: service); await store.load()
        store.setSkill("live", mode: "on")
        XCTAssertEqual(Set(store.draft.resources?.skills ?? []), ["live", "removed"])
        XCTAssertEqual(store.draft.lockedSkills, ["removed"])
        XCTAssertEqual(store.unavailableSkillIDs, ["removed"])
        store.save(); try await settle { store.phase == .sent }
        XCTAssertFalse(store.dirty)
    }
    func testMissingRowsIncludeLockOnlyReferencesAndCanClearEachIndependently() async throws {
        let service = PiResourceContractService(try fixture(skills: ["live", "selected-only", "removed"],
            locks: ["live", "locked-only", "removed"], mcp: ["mcp", "missing-mcp"]))
        let store = PiResourcesStore(sessionID: "fixture", service: service); await store.load()
        XCTAssertEqual(store.unavailableSkillIDs, ["locked-only", "removed", "selected-only"])
        XCTAssertEqual(store.unavailableMcpIDs, ["missing-mcp"])
        store.setSkill("locked-only", mode: "off")
        XCTAssertEqual(store.unavailableSkillIDs, ["removed", "selected-only"])
        XCTAssertEqual(store.draft.resources?.skills, service.response.settings.resources?.skills)
        store.setMcp("missing-mcp", enabled: false)
        XCTAssertEqual(store.draft.resources?.mcpServers, ["mcp"])
        XCTAssertEqual(store.draft.lockedSkills, ["live", "removed"])
    }
    func testServerCanRemoveSkillUninstalledAfterPanelLoadOnlyWhenExplicitlyUnlocked() async throws {
        let service = PiResourceContractService(try fixture(installed: ["live", "removed"]))
        let store = PiResourcesStore(sessionID: "fixture", service: service); await store.load()
        store.setSkill("removed", mode: "on")
        XCTAssertTrue(store.draft.resources?.skills.contains("removed") == true)
        var canonical = store.draft; canonical.resources?.skills.removeAll { $0 == "removed" }
        service.ack = canonical; store.save(); try await settle { store.phase != .sending }
        XCTAssertEqual(store.phase, .sent); XCTAssertEqual(store.draft, canonical); XCTAssertFalse(store.dirty)
    }
    func testUnrelatedOrMalformedAcknowledgementsNeverConfirmSave() async throws {
        for variant in 0..<6 {
            let service = PiResourceContractService(try fixture(installed: ["live", "removed"]))
            let store = PiResourcesStore(sessionID: "fixture", service: service); await store.load()
            store.setSkill("removed", mode: "on")
            let submitted = store.draft
            var wrong = submitted
            switch variant {
            case 0: wrong.lockedSkills = ["live", "removed"]
            case 1: wrong.resources?.skills.removeAll { $0 == "live" }
            case 2: wrong.resources?.skills.append("unexpected")
            case 3: wrong.resources?.skills.append("live")
            case 4: wrong.resources?.mcpServers = []
            default: wrong.resources?.skills.reverse()
            }
            service.ack = wrong; store.save(); try await settle { store.phase != .sending }
            XCTAssertEqual(store.phase, .failed, "variant \(variant)"); XCTAssertTrue(store.uncertain)
            XCTAssertEqual(store.draft, submitted); XCTAssertEqual(store.response?.settings, service.response.settings)
            store.save(); XCTAssertEqual(service.bodies.count, 1, "Unknown save must not repeat")
        }
    }
    func testLateSaveCannotUpdateClosedStore() async throws {
        let service = PiResourceContractService(try fixture()); service.suspendSave = true
        let store = PiResourcesStore(sessionID: "fixture", service: service); await store.load()
        store.setSkill("removed", mode: "off"); let submitted = store.draft; store.save()
        try await settle { service.continuation != nil }; store.close()
        service.continuation?.resume(returning: submitted)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.response?.settings, service.response.settings)
        XCTAssertEqual(store.draft, submitted); XCTAssertNotEqual(store.phase, .sent)
    }
    func testNewDraftSurvivesAnEarlierSaveAcknowledgement() async throws {
        let service = PiResourceContractService(try fixture()); service.suspendSave = true
        let store = PiResourcesStore(sessionID: "fixture", service: service); await store.load()
        store.setSkill("removed", mode: "off"); let submitted = store.draft; store.save()
        try await settle { service.continuation != nil }
        store.setMcp("mcp", enabled: false); let newer = store.draft
        service.continuation?.resume(returning: submitted)
        try await settle { store.phase != .sending }
        XCTAssertEqual(store.draft, newer); XCTAssertEqual(store.response?.settings, submitted); XCTAssertTrue(store.dirty)
    }
    func testInstalledServicePiSettingsReadOnly() async throws {
        let pointer = "/tmp/wand-ios-pi-acceptance-input.json"
        guard FileManager.default.fileExists(atPath: pointer) else { throw XCTSkip("Requires explicit installed-service acceptance input") }
        struct Input: Decodable { let connectionPath: String; let sessionID: String }
        struct Connection: Decodable { let connectionCode: String }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: pointer)))
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: URL(fileURLWithPath: input.connectionPath)))
        let target = try XCTUnwrap(WandAuth.decodeConnectCode(connection.connectionCode))
        let api = WandAPI(baseURL: target.url, token: target.token)
        let response = try await api.piResources(input.sessionID)
        XCTAssertTrue(response.editable); XCTAssertEqual(response.skillLocksAvailable, true)
        let catalog = try XCTUnwrap(response.resourceCatalog)
        XCTAssertFalse(catalog.skills.isEmpty)
        let store = PiResourcesStore(sessionID: input.sessionID, service: api); await store.load()
        XCTAssertNotNil(store.response); XCTAssertFalse(store.dirty)
    }
    func testNativeMissingResourceButtonsRemoveHiddenReferencesAndSave() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-ios-pi-ui-replay-enabled") else {
            throw XCTSkip("Run scripts/test-pi-resources.py for native accessibility taps")
        }
        let service = PiResourceContractService(try fixture(skills: ["removed"], locks: ["removed"], installed: [], mcp: []))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: PiResourcesView(sessionID: "fixture", service: service))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        let before = XCTAttachment(image: UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }); before.name = "pi-missing-before"; before.lifetime = .keepAlways; add(before)
        print("PI_RESOURCES_UI_READY")
        let deadline = Date().addingTimeInterval(75)
        while service.bodies.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(service.bodies.count, 1, "Tap the real missing-resource button, then Save")
        guard let body = service.bodies.first else { return }
        let resources = try XCTUnwrap(body["resources"] as? [String: [String]])
        XCTAssertEqual(resources["skills"], []); XCTAssertEqual(body["lockedSkills"] as? [String], [])
        XCTAssertEqual(resources["mcpServers"], [])
        let after = XCTAttachment(image: UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }); after.name = "pi-missing-after"; after.lifetime = .keepAlways; add(after)
    }
}

@MainActor
private final class DispatchFake: TeamDispatchService {
    var plans = 0, starts = 0
    var startFailure: Error?
    var planContinuation: CheckedContinuation<TeamDispatchPlan, Error>?
    var suspendPlan = false
    var plan = try! parityDecode(TeamDispatchPlan.self, #"{"members":[{"employeeId":"e1","name":"甲","duty":"写代码","avatar":"","probability":0.9,"isLeader":true},{"employeeId":"e2","name":"乙","duty":"检查","avatar":"","probability":0.8,"isLeader":false}],"bench":[],"considered":2,"omitted":0,"note":"确认后开工","maxMembers":3}"#)
    func planTeamDispatch(note: String, maxMembers: Int) async throws -> TeamDispatchPlan {
        plans += 1
        if suspendPlan { return try await withCheckedThrowingContinuation { planContinuation = $0 } }
        return plan
    }
    func startTeamDispatch(workspaceID: String, note: String, selection: TeamDispatchSelection) async throws -> ContactRunDetail {
        starts += 1; if let startFailure { throw startFailure }
        return try parityDecode(ContactRunDetail.self, #"{"run":{"id":"r1","teamId":"t1","taskId":"task1","status":"running","updatedAt":"2026-10-08T00:00:00Z"},"steps":[]}"#)
    }
}

private struct MarkdownTableReadabilityFixture: View {
    let finished: () -> Void
    @State private var dark = false
    static let first = "第一列：" + String(repeating: "中文长句和完整要求必须自动换行，不应永久省略。", count: 5) + "第一列结尾"
    static let second = "第二列：" + String(repeating: "包含 `command_argument_with_long_name` 的长句，也应完整阅读。", count: 4) + "第二列结尾"
    static let third = "第三列：" + String(repeating: "包含 [文件说明链接](https://example.com/design.md) 的建议，也应完整阅读。", count: 4) + "第三列结尾"
    var body: some View {
        VStack {
            HStack {
                Button("切换表格主题") { dark.toggle() }
                Spacer()
                Button("结束表格验收", action: finished)
            }.frame(height: 44).padding(.horizontal)
            ScrollView {
                MarkdownText(text: "| 当前观察 | 代码要求 | 建议改动 |\n| --- | --- | --- |\n| \(Self.first) | \(Self.second) | \(Self.third) |")
                    .padding(12)
            }
        }
        .background(Theme.background)
        .environment(\.colorScheme, dark ? .dark : .light)
        .preferredColorScheme(dark ? .dark : .light)
    }
}

private struct ExistingTimelineReplayFixture: View {
    let group: ActivityGroup
    let finished: () -> Void
    @State private var narrow = false
    var body: some View {
        VStack(spacing: 8) {
            Text("既有Read工具受控重放").font(.headline)
            Text("非用户原UF故障截图").font(.caption)
            Button(narrow ? "恢复标准宽度" : "切换窄屏大字体") { narrow.toggle() }.frame(minHeight: 44)
            ScrollView {
                ActivityFoldCard(group: group, isLastTurn: true).padding(8)
                    .environment(\.sizeCategory, narrow ? .accessibilityExtraExtraLarge : .large)
            }.frame(width: narrow ? 320 : 440, height: 500).border(Theme.border)
            Button("结束时间线验收", action: finished).frame(minHeight: 44)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.background)
    }
}

private final class MessageImageReplayProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var codes: [Int] = [200]
    private static var bytes = Data()
    private static var requests = 0
    static func configure(data: Data, responses: [Int], reset: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        bytes = data; codes = responses
        if reset { requests = 0 }
    }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" && request.url?.port == 31387 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let status = Self.codes.first ?? 200
        if Self.codes.count > 1 { Self.codes.removeFirst() }
        let data = Self.bytes; Self.requests += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class MessageImageReplayState: ObservableObject {
    let baseURL = URL(string: "http://127.0.0.1:31387")!
    let data: Data
    @Published var generation = 0
    @Published var inline = false
    init(data: Data) {
        self.data = data
        install(responses: [403, 200], reset: true)
    }
    var source: String { inline ? "data:image/png;base64," + data.base64EncodedString() : "/tool-image.png" }
    func install(responses: [Int], reset: Bool = false) {
        MessageImageReplayProtocol.configure(data: data, responses: responses, reset: reset)
        SelfSignedSession.resetEndpoint(baseURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessageImageReplayProtocol.self]
        SelfSignedSession.forEndpoint(baseURL).session = URLSession(configuration: configuration)
    }
    func changeConnection() { install(responses: [404]); generation += 1 }
}

private struct MessageImageReplayFixture: View {
    @ObservedObject var state: MessageImageReplayState
    let finished: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text("已有图片受控重放").font(.headline)
            Text("测试夹具，非用户原UF故障截图").font(.caption)
            HStack {
                Button("切换图片连接") { state.changeConnection() }.frame(minHeight: 44)
                Button("显示内联图片") { state.inline = true }.frame(minHeight: 44)
            }
            WandToolImageThumbnail(baseURL: state.baseURL, source: state.source).id(state.generation).frame(height: 220)
            Button("结束图片验收", action: finished).frame(minHeight: 44)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.background)
    }
}

private struct AppleNamedIdentityFixture: View {
    private var metrics = ChatIdentityLayoutMetrics()
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text("首条消息从身份与按钮下方开始。长姓名、当前状态和右侧操作分别可读，不靠打开菜单辨认对象。")
                    .font(.body).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.top, metrics.clearance).clipped()
            Text("隔离布局夹具 · 不发送消息").font(.caption).padding(16)
        }.background(Theme.background).overlay(alignment: .top) {
            ZStack(alignment: .top) {
                TopChatCompanion(title: "小试 · 相同头像的长名称项目协作负责人", status: "等待你的确认") { size in
                    WorkingAvatar(id: "e_wand_default", name: "小试", avatar: "plush-cat:v1:silver", size: size)
                }
                FloatingChatControls(onBack: {}) { FloatingChatIcon(symbol: "ellipsis") }
            }
        }
    }
}

@MainActor
final class CurrentAndroidParityTests: XCTestCase {
    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("异步状态未在限定时间内收敛")
    }
    private func defaults() -> UserDefaults {
        let name = "wand.currentParity." + UUID().uuidString
        return UserDefaults(suiteName: name)!
    }
    private func api() -> WandAPI { WandAPI(baseURL: parityURL, token: nil) }
    func testDefaultAndExplicitRootModesMatchAndroid() {
        XCTAssertEqual(HomeListMode.fromStorage(nil), .im)
        XCTAssertEqual(HomeListMode.fromStorage("bogus"), .im)
        for mode in [HomeListMode.im, .contacts, .sessions, .knowledge, .board] { XCTAssertEqual(HomeListMode.fromStorage(mode.rawValue), mode) }
    }
    func testIMPreviewHasBoundedProjectionAndExactLinks() throws {
        let data: [String: Any] = ["messageId": "m", "role": "assistant", "content": [], "sessionLink": ["sessionId": "s1", "title": "会话"], "sessionPreview": ["status": "running", "text": String(repeating: "字", count: 9000)]]
        let message = try JSONDecoder().decode(ConversationMessage.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertEqual(message.id, "m"); XCTAssertEqual(message.sessionLink?.sessionId, "s1"); XCTAssertEqual(message.sessionPreview?.text.count, 4000)
    }
    func testMalformedAndPendingReceiptsCannotMasqueradeAsAcceptance() throws {
        XCTAssertThrowsError(try parityDecode(ConversationReceipt.self, #"{"requestId":"r","state":"ok"}"#))
        XCTAssertThrowsError(try parityDecode(ConversationReceipt.self, #"{"state":"accepted"}"#))
        XCTAssertEqual(try parityReceipt("pending").state, "pending")
    }
    func testRequestFingerprintIsCanonicalAndEndpointLedgerPersistsOnlyIDs() async throws {
        let a = try ConversationRequestLedger.fingerprint(path: "/api/conversations/dm_e/messages", body: ["input": "private", "target": NSNull()])
        let b = try ConversationRequestLedger.fingerprint(path: "/api/conversations/dm_e/messages", body: ["target": NSNull(), "input": "private"])
        XCTAssertEqual(a, b); XCTAssertFalse(a.contains("private"))
        let d = defaults(), ledger = ConversationRequestLedger(baseURL: parityURL, defaults: d)
        let id = try await ledger.reserve(fingerprint: a)
        let reopened = ConversationRequestLedger(baseURL: parityURL, defaults: d)
        do { _ = try await reopened.reserve(fingerprint: b); XCTFail("重复请求不应发送") }
        catch let error as ConversationUnconfirmed { XCTAssertEqual(error.requestId, id) }
        await reopened.finish(requestId: id)
        let pending = await reopened.pending()
        XCTAssertTrue(pending.isEmpty)
    }
    func testPerServerRequestLedgersDoNotShareIdentity() async throws {
        let d = defaults(), one = ConversationRequestLedger(baseURL: parityURL, defaults: d), two = ConversationRequestLedger(baseURL: URL(string: "http://127.0.0.1:10")!, defaults: d)
        let first = try await one.reserve(fingerprint: "a"), second = try await two.reserve(fingerprint: "a")
        XCTAssertNotEqual(first, second)
    }
    func testConversationMessagePreferenceIsExplicitAndNeverTargetsExistingRuns() {
        let preference = ConversationExecutionPreference(provider: "pi", engine: "sdk", model: "model-x", thinkingEffort: "pi:high")
        let body = conversationMessageBody(input: "work", target: nil, cwd: nil, executionPreference: preference)
        XCTAssertEqual(body["executionPreference"] as? [String: Any] as? NSDictionary,
                       ["provider": "pi", "engine": "sdk", "model": "model-x", "thinkingEffort": "pi:high"] as NSDictionary)
        XCTAssertNil(conversationMessageBody(input: "work", target: nil, cwd: nil, executionPreference: nil)["executionPreference"])
        let target = ConversationTarget(taskId: "task", runId: "run")
        XCTAssertNil(conversationMessageBody(input: "work", target: target, cwd: nil, executionPreference: preference)["executionPreference"])
    }
    func testExecutionPreferenceOutlivesComposerRebuildsAndFollowsEmployeeBinding() {
        let store = ConversationStore(api: api(), service: ConversationFake(), drafts: SessionDraftStore(), defaults: defaults())
        let first = ConversationExecutionPreference(provider: "claude", engine: nil, model: "model-a", thinkingEffort: "high")
        store.setExecutionPreference(first, for: "dm_e", employeeID: "e1")
        XCTAssertEqual(store.executionPreference(for: "dm_e", employeeID: "e1"), first)
        XCTAssertNil(store.executionPreference(for: "dm_e", employeeID: "e2"))
        let second = ConversationExecutionPreference(provider: "pi", engine: "cli", model: "default", thinkingEffort: "off")
        store.setExecutionPreference(second, for: "dm_e", employeeID: "e2")
        XCTAssertNil(store.executionPreference(for: "dm_e", employeeID: "e1"))
        XCTAssertEqual(store.executionPreference(for: "dm_e", employeeID: "e2"), second)
        store.clearExecutionPreference(for: "dm_e")
        XCTAssertNil(store.executionPreference(for: "dm_e", employeeID: "e2"))
    }
    func testToolImageFigureNamesPreferReadPathThenSourceFile() {
        XCTAssertEqual(toolImageDisplayName(inputPath: "/tmp/wand-ios-new-12.png",
                                            source: "/tmp/wand-ios-new-12.png", index: 0, total: 1),
                       "wand-ios-new-12.png")
        XCTAssertEqual(toolImageDisplayName(inputPath: nil,
                                            source: "https://host/api/sessions/s/tool-images/t/0.png?token=1",
                                            index: 0, total: 1), "0.png")
        XCTAssertEqual(toolImageDisplayName(inputPath: nil,
                                            source: "data:image/png;base64,AAAA", index: 0, total: 1), "图片")
        XCTAssertEqual(toolImageDisplayName(inputPath: nil,
                                            source: "data:image/png;base64,AAAA", index: 1, total: 2), "图片 2")
    }
    func testIMSendOwnsFrozenDraftAndAckCannotClearNewerInput() async throws {
        let fake = ConversationFake(); fake.suspendPost = true
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let draft = store.composer("dm_e", target: nil); draft.text = "original"
        store.send("dm_e", target: nil, dispatch: false, workspaceID: nil, cwd: nil)
        await settle { fake.postContinuation != nil }
        draft.text = "newer"
        fake.postContinuation?.resume(returning: try parityReceipt())
        await settle { draft.sendPhase != .sending }
        XCTAssertEqual(draft.text, "newer"); XCTAssertEqual(fake.posts.count, 1)
        XCTAssertTrue(fake.posts[0].0.hasSuffix("/messages")); XCTAssertEqual(fake.posts[0].1["input"] as? String, "original")
    }
    func testUnknownIMDeliveryBlocksRepeatAndRequiresGETReconciliation() async throws {
        let fake = ConversationFake(); fake.failure = ConversationUnconfirmed(requestId: "req"); fake.pending = ["req"]
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let draft = store.composer("dm_e", target: nil); draft.text = "once"
        store.send("dm_e", target: nil, dispatch: false, workspaceID: nil, cwd: nil)
        await settle { store.hasUnknown("dm_e", target: nil) }
        store.send("dm_e", target: nil, dispatch: false, workspaceID: nil, cwd: nil)
        XCTAssertEqual(fake.posts.count, 1)
        fake.failure = nil; fake.pending = []; await store.reconcile("req")
        XCTAssertFalse(store.hasUnknown("dm_e", target: nil)); XCTAssertEqual(draft.text, ""); XCTAssertNil(draft.unconfirmedInput)
    }
    func testExplicitRejectionKeepsIMDraftRetryable() async {
        let fake = ConversationFake(); fake.failure = WandAPI.APIError.server(status: 400, message: "invalid")
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let draft = store.composer("dm_e", target: nil); draft.text = "keep"
        store.send("dm_e", target: nil, dispatch: false, workspaceID: nil, cwd: nil)
        await settle { draft.sendPhase == .failed }
        XCTAssertEqual(draft.text, "keep"); XCTAssertFalse(store.hasUnknown("dm_e", target: nil))
    }
    func testDeletionRetiresDraftAndLateAckCannotResurrectInstance() async throws {
        let fake = ConversationFake(); fake.suspendPost = true
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let draft = store.composer("dm_e", target: nil); draft.text = "pending"
        store.send("dm_e", target: nil, dispatch: false, workspaceID: nil, cwd: nil)
        await settle { fake.postContinuation != nil }; try await store.remove("dm_e")
        fake.postContinuation?.resume(returning: try parityReceipt()); await Task.yield()
        XCTAssertTrue(draft.retired); XCTAssertEqual(draft.text, ""); XCTAssertNil(store.details["dm_e"])
    }
    func testLateDetailLoadCannotOverwriteNewerProjection() async throws {
        let fake = ConversationFake(); fake.suspendLoads = true
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let first = Task { await store.load("dm_e") }; await settle { fake.loads.count == 1 }
        let second = Task { await store.load("dm_e") }; await settle { fake.loads.count == 2 }
        fake.loads[1].resume(returning: try parityDecode(ConversationInstance.self, #"{"id":"dm_e","kind":"dm","title":"new"}"#)); await second.value
        fake.loads[0].resume(returning: fake.detail); await first.value
        XCTAssertEqual(store.details["dm_e"]?.title, "new")
    }
    func testDispatchIntentSurvivesPanelClosingAndTargetsHaveDistinctDrafts() {
        let store = ConversationStore(api: api(), service: ConversationFake(), drafts: SessionDraftStore(), defaults: defaults())
        store.dispatchIntent.insert("dm_e")
        let talk = store.composer("dm_e", target: nil), task = store.composer("dm_e", target: ConversationTarget(taskId: "t", runId: "r"))
        talk.text = "talk"; task.text = "task"
        XCTAssertEqual(talk.text, "talk"); XCTAssertEqual(task.text, "task"); XCTAssertTrue(store.dispatchIntent.contains("dm_e"))
    }
    func testTask142ProductionCancelButtonNeverPostsTheDraft() async throws {
        let fake = ConversationFake()
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        await store.load("dm_e")
        let draft = store.composer("dm_e", target: nil); draft.text = "TASK-142 UI 草稿，绝不执行"
        store.dispatchIntent.insert("dm_e")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ConversationDetailView(id: "dm_e", store: store, onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in }))
        window.rootViewController = host; window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; store.shutdown() }
        try await Task.sleep(for: .milliseconds(300))
        func editor(in view: UIView) -> ComposerUITextView? {
            if let view = view as? ComposerUITextView { return view }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let input = try XCTUnwrap(editor(in: host.view))
        input.becomeFirstResponder()
        input.setMarkedText("未确认中文组字", selectedRange: NSRange(location: 7, length: 0))
        XCTAssertNotNil(input.markedTextRange)
        try await Task.sleep(for: .milliseconds(200))
        print("TASK142_CANCEL_READY")
        // Dedicated runner queries the real AX tree and taps the production cancel button.
        for _ in 0..<600 where store.dispatchIntent.contains("dm_e") {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !store.dispatchIntent.contains("dm_e") else {
            throw XCTSkip("运行 scripts/test-dispatch-cancellation.py 进行真实取消按钮触控回归")
        }
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(draft.attachments.attachments.isEmpty)
        // UIKit is allowed to retain the old editor during its dismissal animation.
        // A late marked-text commit from that editor must still be rejected by the owner.
        input.unmarkText()
        input.delegate?.textViewDidChange?(input)
        for dispatch in [false, true] {
            store.send("dm_e", target: nil, dispatch: dispatch, workspaceID: "project", cwd: nil)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(draft.text, "", "迟到组字提交不得复活已取消草稿")
        XCTAssertTrue(fake.posts.isEmpty, "取消不得创建 channel、消息或任务")
        let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        screenshot.name = "task142-after-production-cancel"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testTask143ProductionDefaultsAreReadOnlyAndNavigateAfterDismissal() async throws {
        let fake = ConversationFake()
        fake.detail = try parityDecode(ConversationInstance.self, #"{"id":"dm_e","kind":"dm","title":"只读配置验证","peerEmployeeId":"e1"}"#)
        fake.people = try parityDecode([SiliconEmployee].self, #"[{"id":"e1","name":"验证员工","agents":[{"provider":"codex","model":"default","mode":"default","thinkingEffort":"high"},{"provider":"pi","engine":"core","model":"provider/long-model-name-for-read-only-preview","mode":"default","thinkingEffort":"deep"}]}]"#)
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        await store.refresh(); await store.load("dm_e")
        let draft = store.composer("dm_e", target: nil); draft.text = "TASK-143 未发送草稿"
        store.dispatchIntent.insert("dm_e")
        var openedEmployeeID: String?
        var navigatedWhileSheetVisible = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ConversationDetailView(id: "dm_e", store: store,
            onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: {
                openedEmployeeID = $0
                navigatedWhileSheetVisible = window.rootViewController?.presentedViewController != nil
            }))
        window.rootViewController = host; window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; store.shutdown() }
        try await Task.sleep(for: .milliseconds(300))
        func editor(in view: UIView) -> ComposerUITextView? {
            if let view = view as? ComposerUITextView { return view }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let input = try XCTUnwrap(editor(in: host.view))
        input.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(300))
        print("TASK143_DEFAULTS_READY")
        for _ in 0..<900 where openedEmployeeID == nil { try await Task.sleep(for: .milliseconds(50)) }
        guard openedEmployeeID != nil else { throw XCTSkip("运行 scripts/test-dispatch-defaults.py 验证生产浮层真实触控") }
        XCTAssertEqual(openedEmployeeID, "e1")
        XCTAssertFalse(navigatedWhileSheetVisible, "关闭只读浮层后才进入真正的编辑入口")
        XCTAssertEqual(draft.text, "TASK-143 未发送草稿")
        XCTAssertTrue(store.dispatchIntent.contains("dm_e"))
        XCTAssertNil(store.executionPreference(for: "dm_e", employeeID: "e1"))
        XCTAssertEqual(store.employees.first?.agents.map(\.model), ["default", "provider/long-model-name-for-read-only-preview"])
        XCTAssertTrue(fake.posts.isEmpty, "查看、点候选、关闭和前往配置均不得发送或保存")
    }

    func testCancelDispatchDiscardsBeforeEitherSendPathCanReadTheDraft() async {
        let fake = ConversationFake(), api = api()
        let store = ConversationStore(api: api, service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let draft = store.composer("dm_e", target: nil)
        draft.text = "TASK-129 不得执行"
        draft.requestInitialSend()
        let oldEditorRevision = draft.discardRevision
        draft.attachments.attachments = [UploadedFile(originalName: "draft.txt", savedPath: "/draft.txt", size: 3, mimeType: "text/plain")]
        store.dispatchIntent.insert("dm_e")
        XCTAssertTrue(store.cancelDispatch("dm_e", target: nil))
        XCTAssertFalse(store.dispatchIntent.contains("dm_e"))
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(draft.attachments.attachments.isEmpty)
        XCTAssertFalse(draft.claimInitialSend())
        draft.setText("迟到的组字", ifDiscardRevision: oldEditorRevision)
        XCTAssertEqual(draft.text, "")
        // Even a stale send action after the layout change has no payload to submit.
        for dispatch in [false, true] {
            store.send("dm_e", target: nil, dispatch: dispatch, workspaceID: "project", cwd: nil)
        }
        await Task.yield()
        XCTAssertTrue(fake.posts.isEmpty)
        let reopened = ComposerDraftState(sessionId: store.draftKey("dm_e", target: nil), api: api)
        XCTAssertEqual(reopened.text, "")
        XCTAssertTrue(reopened.attachments.attachments.isEmpty)
    }

    func testCancelDispatchDoesNotAffectOtherTargetsOrOrdinaryDrafts() {
        let store = ConversationStore(api: api(), service: ConversationFake(), drafts: SessionDraftStore(), defaults: defaults())
        let target = ConversationTarget(taskId: "t", runId: "r")
        let talk = store.composer("dm_e", target: nil), reply = store.composer("dm_e", target: target)
        talk.text = "保留沟通草稿"; reply.text = "取消本轮派发草稿"
        XCTAssertFalse(store.cancelDispatch("dm_e", target: nil))
        XCTAssertEqual(talk.text, "保留沟通草稿")
        store.dispatchIntent.insert("dm_e")
        XCTAssertTrue(store.cancelDispatch("dm_e", target: target))
        XCTAssertEqual(talk.text, "保留沟通草稿")
        XCTAssertEqual(reply.text, "")
    }

    func testCancelDispatchInvalidatesAnUploadWaitingForItsChannel() async throws {
        let fake = ConversationFake(); fake.suspendPost = true
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let draft = store.composer("dm_e", target: nil); draft.text = "取消附件派发"
        store.dispatchIntent.insert("dm_e")
        draft.attachments.handleFileSelection(.success([URL(fileURLWithPath: "/tmp/not-uploaded-task142.txt")]))
        await settle { fake.postContinuation != nil }
        XCTAssertTrue(store.cancelDispatch("dm_e", target: nil))
        XCTAssertFalse(draft.attachments.isUploading)
        fake.postContinuation?.resume(returning: try parityReceipt(extra: ",\"sessionId\":\"never-upload\""))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(draft.text, "")
        XCTAssertTrue(draft.attachments.attachments.isEmpty)
        XCTAssertEqual(fake.posts.map(\.0), ["/api/conversations/dm_e/channel"])
    }

    func testOnlyExplicitDispatchSubmitsOnceAndCancelCannotForgetInFlightInput() async throws {
        let fake = ConversationFake(); fake.suspendPost = true
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let draft = store.composer("dm_e", target: nil); draft.text = "明确确认的任务"
        store.dispatchIntent.insert("dm_e")
        store.send("dm_e", target: nil, dispatch: true, workspaceID: "project", cwd: nil)
        XCTAssertFalse(store.cancelDispatch("dm_e", target: nil))
        XCTAssertEqual(draft.text, "明确确认的任务")
        store.send("dm_e", target: nil, dispatch: true, workspaceID: "project", cwd: nil)
        await settle { fake.postContinuation != nil }
        XCTAssertEqual(fake.posts.count, 1)
        XCTAssertEqual(fake.posts.first?.0, "/api/conversations/dm_e/tasks")
        fake.postContinuation?.resume(returning: try parityReceipt())
        await settle { draft.sendPhase != .sending }
        XCTAssertEqual(draft.text, "")
    }

    func testCancelDispatchCannotEraseUnknownDelivery() async {
        let fake = ConversationFake(); fake.failure = ConversationUnconfirmed(requestId: "unknown")
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        let draft = store.composer("dm_e", target: nil); draft.text = "核对送达前保留"
        store.dispatchIntent.insert("dm_e")
        store.send("dm_e", target: nil, dispatch: true, workspaceID: "project", cwd: nil)
        await settle { store.hasUnknown("dm_e", target: nil) }
        XCTAssertFalse(store.cancelDispatch("dm_e", target: nil))
        XCTAssertEqual(draft.text, "核对送达前保留")
        XCTAssertTrue(store.dispatchIntent.contains("dm_e"))
        XCTAssertEqual(fake.posts.count, 1)
    }

    func testGroupOperationRetainsAcceptedStartupFailureRatherThanRepeating() async throws {
        let operation = ConversationOperation(), receipt = try parityReceipt(extra: ",\"startup\":\"failed\",\"error\":\"engine unavailable\"")
        var calls = 0
        operation.submit({ calls += 1; return receipt }, accepted: { _ in })
        await settle { operation.receipt != nil }
        operation.submit({ calls += 1; return receipt }, accepted: { _ in })
        XCTAssertEqual(calls, 1); XCTAssertFalse(operation.canSubmit); XCTAssertEqual(operation.phase, .sent)
    }
    func testGroupManagementNativeReplay() async throws {
        guard ProcessInfo.processInfo.environment["WAND_GROUP_MANAGEMENT_TOUCH"] == "1" else {
            throw XCTSkip("Requires explicit native touch driver; never mutates real groups")
        }
        let fake = ConversationFake()
        fake.detail = try parityDecode(ConversationInstance.self, #"{"id":"group-replay","kind":"group","title":"群聊管理验收"}"#)
        fake.rows = [fake.detail]; fake.applyManagementPatches = true
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        await store.refresh()
        let draft = store.composer(fake.detail.id, target: nil); draft.text = "解散及失败后保留的草稿"
        let finished = expectation(description: "native management replay complete")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
            HStack {
                Button("模拟失败") { fake.managementFailure = URLError(.notConnectedToInternet) }
                Button("恢复网络") { fake.managementFailure = nil }
                Button("结束验收") { finished.fulfill() }
            }.font(.caption).frame(minHeight: 44)
            NavigationStack {
                NavigationLink("打开验收群聊") {
                    ConversationDetailView(id: fake.detail.id, store: store, onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in })
                }
            }
        }.environment(\.usesSystemHomeNavigation, false))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; store.shutdown() }
        await fulfillment(of: [finished], timeout: 240)
        XCTAssertEqual(fake.listPatches.map { $0.1 }, [["dissolved": true], ["dissolved": false]])
        XCTAssertEqual(fake.deletedIDs, ["group-replay", "group-replay"])
        XCTAssertNil(store.details["group-replay"]); XCTAssertNil(store.selectedID)
        XCTAssertTrue(fake.posts.isEmpty)
    }

    func testGroupManagementActionsRespectLifecycleAndExternalBoundary() throws {
        let group = try parityDecode(ConversationInstance.self, #"{"id":"g","kind":"group"}"#)
        let dissolved = try parityDecode(ConversationInstance.self, #"{"id":"g","kind":"group","dissolvedAt":"now"}"#)
        let deleting = try parityDecode(ConversationInstance.self, #"{"id":"g","kind":"group","deleting":true}"#)
        let dm = try parityDecode(ConversationInstance.self, #"{"id":"dm","kind":"dm"}"#)
        let external = try parityDecode(ConversationInstance.self, #"{"id":"ext","kind":"group","external":{"provider":"dingtalk","groupId":"g","syncState":"live"}}"#)
        XCTAssertEqual(ConversationManagementAction.available(for: group), [.dissolve, .delete])
        XCTAssertEqual(ConversationManagementAction.available(for: dissolved), [.restore, .delete])
        XCTAssertTrue(ConversationManagementAction.available(for: deleting).isEmpty)
        XCTAssertTrue(ConversationManagementAction.available(for: dm).isEmpty)
        XCTAssertEqual(ConversationManagementAction.available(for: external), [.delete])
        XCTAssertEqual(ConversationManagementAction.delete.title(for: external), "删除本地群镜像")
        XCTAssertTrue(ConversationManagementAction.delete.explanation(for: external).contains("不退出或解散钉钉群"))
        XCTAssertTrue(ConversationManagementAction.dissolve.explanation(for: group).contains("不会因此停止"))
    }

    func testGroupManagementFailureRetainsDetailDraftAndSelectionThenDeleteCleansUp() async throws {
        let fake = ConversationFake()
        fake.detail = try parityDecode(ConversationInstance.self, #"{"id":"g","kind":"group","title":"管理回归"}"#)
        fake.rows = [fake.detail]
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        defer { store.shutdown() }
        await store.refresh(); store.select("g"); await store.load("g")
        let draft = store.composer("g", target: nil); draft.text = "保留输入"
        fake.managementFailure = URLError(.notConnectedToInternet)
        let updated = await store.update("g", patch: ["dissolved": true])
        XCTAssertFalse(updated)
        do { try await store.remove("g"); XCTFail("failed delete must throw") } catch {}
        XCTAssertNotNil(store.details["g"]); XCTAssertEqual(store.selectedID, "g")
        XCTAssertEqual(draft.text, "保留输入"); XCTAssertFalse(store.mutationBusy)
        fake.managementFailure = nil
        fake.detail = try parityDecode(ConversationInstance.self, #"{"id":"g","kind":"group","dissolvedAt":"now"}"#)
        let dissolved = await store.update("g", patch: ["dissolved": true])
        XCTAssertTrue(dissolved); XCTAssertNotNil(store.details["g"]?.dissolvedAt)
        XCTAssertEqual(draft.text, "保留输入")
        fake.detail = try parityDecode(ConversationInstance.self, #"{"id":"g","kind":"group"}"#)
        let restored = await store.update("g", patch: ["dissolved": false])
        XCTAssertTrue(restored); XCTAssertNil(store.details["g"]?.dissolvedAt)
        XCTAssertEqual(fake.listPatches.last?.1, ["dissolved": false])
        try await store.remove("g")
        XCTAssertNil(store.details["g"]); XCTAssertFalse(store.items.contains { $0.id == "g" }); XCTAssertNil(store.selectedID)
        XCTAssertEqual(fake.deletedIDs, ["g", "g"])
    }

    func testPrivateAndDissolvedListTiersUseActualInstanceState() throws {
        let dm = try parityDecode(ConversationInstance.self, #"{"id":"dm_e","kind":"dm"}"#)
        let group = try parityDecode(ConversationInstance.self, #"{"id":"g","kind":"group","dissolvedAt":"now"}"#)
        XCTAssertTrue(ConversationListTier.dm.contains(dm)); XCTAssertFalse(ConversationListTier.all.contains(group)); XCTAssertTrue(ConversationListTier.dissolved.contains(group))
    }
    func testToolCallsWithOnlyInputRemainInspectableDuringExecutionAndAfterMissingReceipt() {
        let input: [String: JSONValue] = ["query": .string("fixture query")]
        let running = ToolCallPresentation(name: "mcp__search", input: input, result: nil, sessionRunning: true)
        XCTAssertTrue(running.hasBody); XCTAssertTrue(running.hasInput); XCTAssertEqual(running.state, .running)
        let stopped = ToolCallPresentation(name: "mcp__search", input: input, result: nil, sessionRunning: false)
        XCTAssertTrue(stopped.hasBody); XCTAssertEqual(stopped.state, .unreturned)
        XCTAssertEqual(stopped.state.label, "未返回")
        XCTAssertFalse(ToolCallPresentation(name: "empty", input: [:], result: nil, sessionRunning: false).hasBody)
        XCTAssertFalse(ToolCallPresentation(name: "metadata", input: ["__wandToolPreview": .string("preview")], result: nil, sessionRunning: false).hasBody)
    }
    func testEmptyResultFailureAndTaskSnapshotAreDistinctFromPending() {
        let empty = ToolResultInfo(toolUseId: "t", text: "", isError: false, truncated: false)
        XCTAssertEqual(ToolCallPresentation(name: "tool", input: [:], result: empty, sessionRunning: true).state, .completed)
        XCTAssertTrue(ToolCallPresentation(name: "tool", input: [:], result: empty, sessionRunning: false).hasBody)
        let failed = ToolResultInfo(toolUseId: "t", text: "failed", isError: true, truncated: false)
        XCTAssertEqual(ToolCallPresentation(name: "tool", input: [:], result: failed, sessionRunning: true).state, .failed)
        let update = ToolCallPresentation(name: "provider_operation", input: ["__wandTasks": .array([])], result: nil, sessionRunning: true)
        XCTAssertEqual(update.state, .completed, "Protocol task-list snapshots do not wait for a nonexistent result")
        XCTAssertEqual(ToolCallPresentation(name: "TodoWrite", input: [:], result: nil, sessionRunning: true).state, .completed)
        XCTAssertEqual(ToolCallPresentation(name: "tool", input: ["status": .string("done")], result: nil, sessionRunning: true).state, .running)
    }
    func testNewTaskDispatchDoesNotOverwriteContactsDraftAndKeepsSameScopedOwner() {
        let cache = TeamDispatchStoreCache()
        let contacts = cache.store(api: api())
        let creation = cache.store(api: api(), scope: "new-task")
        contacts.note = "保留通讯录原草稿"
        creation.note = "新建任务的独立草稿"
        XCTAssertFalse(contacts === creation)
        XCTAssertTrue(creation === cache.store(api: api(), scope: "new-task"))
        XCTAssertEqual(contacts.note, "保留通讯录原草稿")
    }
    func testUnknownCreationRecoveryBelongsToWorkspaceOwnerUntilExplicitAcknowledgement() {
        let store = WorkspaceStore(api: api(), serverID: UUID().uuidString)
        store.markUnconfirmedTaskCreation(prompt: "原始草稿，不自动重发")
        XCTAssertTrue(store.taskCreationUnconfirmed)
        XCTAssertEqual(store.unconfirmedCreationPrompt, "原始草稿，不自动重发")
        store.markUnconfirmedTaskCreation()
        XCTAssertEqual(store.unconfirmedCreationPrompt, "原始草稿，不自动重发")
        store.acknowledgeUnconfirmedTaskCreation()
        XCTAssertFalse(store.taskCreationUnconfirmed)
        XCTAssertNil(store.unconfirmedCreationPrompt)
    }
    func testOfflineReplayUsesOneScenarioGateForAppAndStartupServices() {
        for scenario in ["tools", "task", "new"] {
            XCTAssertEqual(mobileOperationParityScenario(["WAND_DEBUG_MOBILE_PARITY": scenario]), scenario)
        }
        XCTAssertNil(mobileOperationParityScenario([:]))
        XCTAssertNil(mobileOperationParityScenario(["WAND_DEBUG_MOBILE_PARITY": "unknown"]))
    }
    func testReadOnlyChoiceIsNotAnEnabledNoOp() {
        XCTAssertTrue(SearchableChoiceItem(id: "active", label: "可选").enabled)
        XCTAssertFalse(SearchableChoiceItem(id: "locked", label: "已固定", enabled: false).enabled)
    }
    func testActivityTimelineModeMatchesAndroidThreeWayPreference() {
        XCTAssertTrue(activityTimelineEnabled(mode: "all", wifiConnected: false))
        XCTAssertTrue(activityTimelineEnabled(mode: "all", wifiConnected: true))
        XCTAssertFalse(activityTimelineEnabled(mode: "wifi", wifiConnected: false))
        XCTAssertTrue(activityTimelineEnabled(mode: "wifi", wifiConnected: true))
        XCTAssertFalse(activityTimelineEnabled(mode: "never", wifiConnected: false))
        XCTAssertFalse(activityTimelineEnabled(mode: "never", wifiConnected: true))
        XCTAssertFalse(activityTimelineEnabled(mode: "never_wifi", wifiConnected: false))
        XCTAssertFalse(activityTimelineEnabled(mode: "never_wifi", wifiConnected: true))
        XCTAssertFalse(activityTimelineEnabled(mode: "unknown", wifiConnected: true), "未知档位不能回落到按 Wi-Fi 自动展开")
    }

    /// 手动收放只翻开闭轴：用户选过的网络范围不能被这一下吞掉。
    func testActivityTimelineManualToggleKeepsNetworkScope() {
        XCTAssertEqual(activityTimelineScope("wifi"), "wifi")
        XCTAssertEqual(activityTimelineScope("all"), "all")
        XCTAssertEqual(activityTimelineScope("never"), "all")
        XCTAssertEqual(activityTimelineScope("never_wifi"), "wifi")
        XCTAssertEqual(activityTimelineScope("unknown"), "wifi", "未知档位走保守口径")

        let collapsed = activityTimelineModeAfterToggle("wifi", open: false)
        XCTAssertEqual(collapsed, "never_wifi")
        XCTAssertTrue(activityTimelineCollapsed(collapsed))
        XCTAssertEqual(activityTimelineModeAfterToggle(collapsed, open: true), "wifi")

        let collapsedAll = activityTimelineModeAfterToggle("all", open: false)
        XCTAssertEqual(collapsedAll, "never")
        XCTAssertEqual(activityTimelineModeAfterToggle(collapsedAll, open: true), "all")
    }

    /// 设置页三档与内部存储值的映射：两个折叠档在界面上都是「一直折叠」。
    func testActivityTimelineSettingsOptionMapping() {
        XCTAssertEqual(activityTimelineDisplayOption("all"), "all")
        XCTAssertEqual(activityTimelineDisplayOption("wifi"), "wifi")
        XCTAssertEqual(activityTimelineDisplayOption("never"), "never")
        XCTAssertEqual(activityTimelineDisplayOption("never_wifi"), "never")
        XCTAssertEqual(activityTimelineMode(forOption: "never", current: "wifi"), "never_wifi")
        XCTAssertEqual(activityTimelineMode(forOption: "never", current: "all"), "never")
        XCTAssertEqual(activityTimelineMode(forOption: "all", current: "never_wifi"), "all")
        XCTAssertEqual(activityTimelineMode(forOption: "wifi", current: "never_wifi"), "wifi")
    }
    func testActivityAutoExpansionRequiresLatestRunningGroupAndRespectsViewport() {
        for newest in [false, true] { for running in [false, true] { for allowed in [false, true] {
            XCTAssertEqual(activityShouldAutoExpand(newest: newest, running: running, timelineEnabled: allowed), newest && running && allowed)
        } } }
        XCTAssertEqual(activityPanelHeight(viewportHeight: 300), 120)
        XCTAssertEqual(activityPanelHeight(viewportHeight: 600), 200)
        XCTAssertEqual(activityPanelHeight(viewportHeight: 1200), 240)
        XCTAssertEqual(activityPanelHeight(viewportHeight: 0), 240)
    }
    func testCompanionWorkStatusMatchesAndroidAndLeavesDetailedProgressToActivityArea() {
        XCTAssertEqual(identityWorkStatus(activity: .idle, hasDetailedProgress: true), "")
        XCTAssertEqual(identityWorkStatus(activity: .idle, hasDetailedProgress: false), "正在处理")
        XCTAssertEqual(identityWorkStatus(activity: .reading, hasDetailedProgress: true), "正在读文件")
        XCTAssertEqual(identityWorkStatus(activity: .writing, hasDetailedProgress: true), "正在写文件")
    }

    /// 会话顶栏身份：主标题是任务名（独立会话回落会话标题），小字是「员工名 · 目录缩写」；
    /// 目录只取最后一段，和 macOS SessionHeaderView 的 basename 显示同语义。
    func testChatTopIdentityUsesTaskNameWithEmployeeAndLeafDirectory() {
        XCTAssertEqual(abbreviatedDirectory("/Users/co0ontty/Self/vibe_coding/wand"), "wand")
        XCTAssertEqual(abbreviatedDirectory("/Users/co0ontty/Self/vibe_coding/wand/"), "wand")
        XCTAssertEqual(abbreviatedDirectory("/"), "")
        XCTAssertEqual(abbreviatedDirectory("   "), "")
        let task = chatTopIdentity(taskTitle: " 图片自适应放大 ", sessionTitle: "会话标题",
            employeeName: "赛博虎妞", cwd: "/Users/co0ontty/Self/vibe_coding/wand")
        XCTAssertEqual(task.title, "图片自适应放大", "任务名不能被会话标题覆盖")
        XCTAssertEqual(task.subtitle, "赛博虎妞 · wand")
        let standalone = chatTopIdentity(taskTitle: "   ", sessionTitle: "会话标题", employeeName: nil, cwd: nil)
        XCTAssertEqual(standalone.title, "会话标题")
        XCTAssertEqual(standalone.subtitle, "", "缺项不能留下光秃秃的分隔符")
        XCTAssertEqual(chatTopIdentity(taskTitle: nil, sessionTitle: "", employeeName: "赛博虎妞", cwd: "/tmp/x").title, "当前会话")
    }

    /// 状态点由真实状态位判定，不从展示文案反推；异常优先于等待确认，等待确认优先于运行。
    func testChatTopAttentionFollowsRealSessionState() {
        XCTAssertEqual(ChatTopAttention.resolve(connected: false, blocked: false, sending: true, responding: true, status: "running"), .fault)
        XCTAssertEqual(ChatTopAttention.resolve(connected: true, blocked: true, sending: false, responding: false, status: "failed"), .fault)
        XCTAssertEqual(ChatTopAttention.resolve(connected: true, blocked: true, sending: true, responding: true, status: "running"), .needsYou)
        XCTAssertEqual(ChatTopAttention.resolve(connected: true, blocked: false, sending: true, responding: false, status: "running"), .running)
        XCTAssertEqual(ChatTopAttention.resolve(connected: true, blocked: false, sending: false, responding: true, status: "running"), .running)
        XCTAssertEqual(ChatTopAttention.resolve(connected: true, blocked: false, sending: false, responding: false, status: "stopped"), .quiet)
    }

    /// 会话页（结构化 + 终端）不再画大头像伙伴，IM 私聊保留；两条链路的身份都走
    /// 同一个 chatTopIdentity，任务名由宿主任务页注入。顶栏标题改为胶囊：左侧圆圈头像，右侧标题。
    func testSessionTopBarReplacesAvatarWithTaskIdentity() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Wand/ChatView.swift"), encoding: .utf8)
        let destination = try String(contentsOf: root.appendingPathComponent("Wand/SessionDestinationView.swift"), encoding: .utf8)
        let workspace = try String(contentsOf: root.appendingPathComponent("Wand/WorkspaceTaskView.swift"), encoding: .utf8)
        let capsule = try String(contentsOf: root.appendingPathComponent("Wand/TopCapsuleTitle.swift"), encoding: .utf8)
        XCTAssertTrue(chat.contains("ChatTopIdentityBar(title: topIdentity.title"))
        XCTAssertFalse(chat.contains("TopChatCompanion"), "结构化会话仍在画头像")
        XCTAssertFalse(chat.contains("companionFace"), "结构化会话残留头像绘制")
        XCTAssertTrue(chat.contains("chatTopIdentity(taskTitle: hostTitle"))
        XCTAssertTrue(destination.contains("chatTopIdentity(taskTitle: hostTitle"), "终端顶栏没走同一份身份判定")
        XCTAssertTrue(destination.contains("TopCapsuleTitle("), "终端顶栏没用胶囊标题")
        XCTAssertTrue(workspace.contains("TopCapsuleTitle("), "任务顶栏没用胶囊标题")
        XCTAssertTrue(capsule.contains("WorkingAvatar("), "胶囊头像没有用 3D 场景")
        XCTAssertTrue(capsule.contains("activity: activity"), "胶囊头像没有接读/写/思考活动")
        XCTAssertTrue(chat.contains("activity: avatarActivity"), "会话顶栏没有接读文件活动")
        XCTAssertTrue(chat.contains("thinking: avatarIsThinking"), "会话顶栏没有接思考状态")
        XCTAssertTrue(workspace.contains("hostTitle: task.name"), "宿主任务名没有注入顶栏")
    }

    /// TODO、队列和输入区按同一层级排列；输入组件只拥有自身附件操作。
    /// 尺寸、滚动和背景由 InputOpeningTests 的真实共享组件布局验证。
    func testQueuedCountHasSingleOwnerAboveComposer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Wand/ChatView.swift"), encoding: .utf8)
        XCTAssertFalse(chat.contains("\"待发 \\(store.queuedMessages.count)\""), "进度行与队列条重复计数")
        let bottomStart = try XCTUnwrap(chat.range(of: "private var bottomBar: some View"))
        let bottomEnd = try XCTUnwrap(chat.range(of: "private var accessoryMaximumHeight:", range: bottomStart.upperBound..<chat.endIndex))
        let bottom = String(chat[bottomStart.lowerBound..<bottomEnd.lowerBound])
        let todo = try XCTUnwrap(bottom.range(of: "TodoProgressBar("))
        let queue = try XCTUnwrap(bottom.range(of: "composerQueueAccessory"))
        let input = try XCTUnwrap(bottom.range(of: "inputBar"))
        XCTAssertLessThan(todo.lowerBound, queue.lowerBound)
        XCTAssertLessThan(queue.lowerBound, input.lowerBound)
        XCTAssertTrue(bottom.contains(".background(Theme.workspaceReading)"))
        XCTAssertFalse(bottom.contains("workspaceInputDock"))
        XCTAssertEqual(chat.components(separatedBy: "composerQueueAccessory").count - 1, 2,
            "Queue content has one declaration and one dock use, outside the text field")
        XCTAssertTrue(chat.contains("if !store.queuedMessages.isEmpty || composerDraft.queueRecoveryText != nil"),
            "A recovered message must remain visible after the queue itself becomes empty")
        XCTAssertTrue(chat.contains("recovery: composerDraft.queueRecoveryText == nil ? nil : AnyView(queueRecoveryAccessory)"),
            "Recovery content belongs to the same bounded queue list")
        let accessoryStart = try XCTUnwrap(chat.range(of: "private var composerAccessories: some View"))
        let accessoryEnd = try XCTUnwrap(chat.range(of: "private var growingTextField:", range: accessoryStart.upperBound..<chat.endIndex))
        XCTAssertFalse(chat[accessoryStart.lowerBound..<accessoryEnd.lowerBound].contains("composerQueueAccessory"))
        let queueStart = try XCTUnwrap(chat.range(of: "struct QueueBar: View"))
        XCTAssertTrue(chat[queueStart.lowerBound...].contains("ComposerAccessoryHeader("))
        XCTAssertTrue(chat[queueStart.lowerBound...].contains(".accessibilityValue(\"待发送 \\(items.count) 条，\""),
            "The icon-and-summary layout keeps its complete VoiceOver queue count")
    }
    func testPendingFullToolFetchCannotFabricateSuccessOrEraseKnownResult() throws {
        let pending = try parityDecode(ToolContentResponse.self, #"{"tool_use_id":"t","input":{"query":"full"},"content":"","pending":true,"resultAvailable":false}"#)
        XCTAssertFalse(pending.resultAvailable)
        let legacy = try parityDecode(ToolContentResponse.self, #"{"tool_use_id":"t","input":{},"content":""}"#)
        XCTAssertTrue(legacy.resultAvailable, "Old servers without flags retain their documented result response")
        let store = ChatStore(sessionId: UUID().uuidString, api: api(), drafts: SessionDraftStore())
        defer { store.composerDraft.retire(); store.shutdown() }
        store.messages = [try parityDecode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"lookup","input":{"query":"short"}},{"type":"tool_result","tool_use_id":"t","content":"keep known output"}]}"#)]
        store.applyLoadedToolContent(pending)
        guard case .toolResult(_, let text, _, _, _, _, _) = store.messages[0].content[1] else { return XCTFail("Keep the actual result") }
        XCTAssertEqual(text, "keep known output")
        guard case .toolUse(_, _, _, let input, _) = store.messages[0].content[0] else { return XCTFail("Keep invocation") }
        XCTAssertEqual(input["query"]?.stringValue, "full")
    }
    func testTerminalShortcutOrderMatchesAndroidWithoutChangingBytes() {
        XCTAssertEqual(TerminalShortcuts.defaults.map(\.id),
            ["enter", "arrow-up", "tab", "escape", "ctrl-c", "shift-tab", "arrow-left", "arrow-right", "arrow-down"])
        XCTAssertEqual(TerminalShortcuts.defaults.first?.bytes, "\r")
        XCTAssertTrue(TerminalShortcuts.defaults.allSatisfy { !$0.bytes.isEmpty })
    }
    func testFilesBackNavigatesParentAndRootShortcutKeepsOwner() async {
        let store = SessionFilesStore(service: FilesFake())
        store.show(cwd: "/work")
        store.requestDirectory("/work/nested")
        store.requestBack()
        XCTAssertEqual(store.directory, "/work"); XCTAssertTrue(store.open)
        store.requestDirectory("/elsewhere")
        store.requestDirectory(store.root)
        XCTAssertEqual(store.directory, "/work"); XCTAssertTrue(store.open)
        store.requestBack(); XCTAssertFalse(store.open)
    }
    func testFilesAreEditableOnlyWithTextAndCASMetadata() {
        XCTAssertTrue(FilesFake().preview.canEdit)
        XCTAssertFalse(SessionFilePreview(path: "/a", name: "a", kind: "text", size: nil, mtime: nil, content: "x").canEdit)
        XCTAssertFalse(SessionFilePreview(path: "/a", name: "a", kind: "binary", size: 1, mtime: "t", content: "x").canEdit)
    }
    private func editor(_ fake: FilesFake) async -> SessionFilesStore {
        let store = SessionFilesStore(service: fake); store.show(cwd: "/work"); store.requestFile("/work/a.txt")
        await settle { store.file != nil }; store.toggleEditing(); store.edit("new"); return store
    }
    func testFileNavigationRequiresExplicitDiscardAndKeepsDraftOnCancel() async {
        let fake = FilesFake(), store = await editor(fake)
        store.requestDirectory("/another"); XCTAssertNotNil(store.pendingDiscard); XCTAssertEqual(store.draft, "new")
        store.cancelDiscard(); XCTAssertEqual(store.filePath, "/work/a.txt")
        store.requestClose(); store.confirmDiscard(); XCTAssertFalse(store.open)
    }
    func testFileSaveUsesOriginalMtimeAndSizeAndSettlesSameButtonState() async {
        let fake = FilesFake(), store = await editor(fake); store.save()
        await settle { store.savePhase == .done }
        XCTAssertEqual(fake.writes[0].0.mtime, "t1"); XCTAssertEqual(fake.writes[0].0.size, 3); XCTAssertEqual(fake.writes[0].1, "new")
        XCTAssertEqual(store.file?.mtime, "t2"); XCTAssertFalse(store.dirty)
    }
    func testFileConflictPreservesDraftAndCannotBlindlyRetry() async {
        let fake = FilesFake(); fake.writeFailure = WandAPI.APIError.server(status: 409, message: "conflict")
        let store = await editor(fake); store.save(); await settle { store.saveConflict }
        store.edit("still new"); store.save()
        XCTAssertEqual(store.draft, "still new"); XCTAssertFalse(store.canSave); XCTAssertEqual(fake.writes.count, 1)
    }
    func testUnknownFileWriteRequiresReadNotAnotherWrite() async {
        let fake = FilesFake(); fake.writeFailure = WandAPI.APIError.network("ack lost")
        let store = await editor(fake); store.save(); await settle { store.savePhase == .uncertain }
        store.save(); XCTAssertEqual(fake.writes.count, 1); XCTAssertEqual(store.draft, "new")
    }
    func testFileCannotNavigateOrEditWhileSaving() async {
        let fake = FilesFake(); fake.suspendWrites = true
        let store = await editor(fake); store.save(); await settle { fake.writeContinuation != nil }
        store.requestClose(); store.edit("late"); XCTAssertTrue(store.open); XCTAssertEqual(store.draft, "new")
        fake.writeContinuation?.resume(returning: SessionFileWriteResult(ok: true, size: 3, mtime: "t2")); await settle { store.savePhase == .done }
    }
    func testPiAndWandAgentRemainDistinctWithSameProvider() throws {
        XCTAssertEqual(WandAgentTool.pi.provider, WandAgentTool.wandAgent.provider)
        XCTAssertEqual(WandAgentTool.pi.engine, "cli"); XCTAssertEqual(WandAgentTool.wandAgent.engine, "sdk")
        let snapshot = try parityDecode(SessionSnapshot.self, #"{"id":"s","provider":"pi","sessionKind":"structured","structuredState":{"engine":"core"}}"#)
        XCTAssertEqual(snapshot.providerLabel, "Wand Agent"); XCTAssertEqual(WandProvider.pi.title, "Pi")
        let candidate = try parityDecode(ContactCandidate.self, #"{"provider":"pi","engine":"sdk"}"#)
        XCTAssertEqual(candidate.body()["engine"] as? String, "sdk")
    }
    func testWorkspaceWandAgentAlwaysCreatesStructuredAndNeverPretendsToBePTY() {
        let request = workspaceTaskWindowRequest(target: .wandAgent, binding: WorkspaceBinding(workspaceId: "w", workspaceTaskId: "t", cwd: "/work"), kind: .pty)
        XCTAssertEqual(request.path, "/api/sessions"); XCTAssertEqual(request.body["kind"], .string("structured")); XCTAssertEqual(request.body["provider"], .string("pi")); XCTAssertEqual(request.body["engine"], .string("sdk"))
    }
    func testDirectoryChangeRequiresBlankUnlockedUnboundSession() throws {
        let empty = try parityDecode(SessionSnapshot.self, #"{"id":"s","sessionKind":"structured","status":"idle"}"#)
        XCTAssertTrue(canChangeBlankSessionDirectory(empty, messageTotal: 0)); XCTAssertFalse(canChangeBlankSessionDirectory(empty, messageTotal: 1))
        for extra in [#",\"workspaceTaskId\":\"t\""#, #",\"directoryLocked\":true"#, #",\"claudeSessionId\":\"resume\""#] {
            let text = "{\"id\":\"s\",\"sessionKind\":\"structured\",\"status\":\"idle\"" + extra.replacingOccurrences(of: "\\\"", with: "\"") + "}"
            XCTAssertFalse(canChangeBlankSessionDirectory(try parityDecode(SessionSnapshot.self, text), messageTotal: 0))
        }
    }
    func testTimelineOrderUsesRealTimeWithStableUnknownPlacement() {
        let times: [String?] = [nil, "2026-10-08T00:00:03Z", nil, "2026-10-08T00:00:01Z", "2026-10-08T00:00:02Z"]
        XCTAssertEqual(activityTimelineOrder(times), [3, 4, 0, 1, 2]); XCTAssertEqual(activityTimelineOrder([nil, nil]), [0, 1])
    }
    func testThinkingRoundFilteringMatchesAndroidAndDoesNotLoseLivePlaceholder() {
        XCTAssertFalse(keepThinkingRound(text: "", position: 0, lastPosition: 2, running: true))
        XCTAssertFalse(keepThinkingRound(text: "", position: 2, lastPosition: 2, running: false))
        XCTAssertTrue(keepThinkingRound(text: "", position: 2, lastPosition: 2, running: true))
        XCTAssertTrue(keepThinkingRound(text: "reason", position: 0, lastPosition: 2, running: false))
    }
    func testThinkingAndTextIdentityDoesNotChangeWithStreamedBody() {
        XCTAssertEqual(displayItemIdentity(.plain(.thinking(thinking: "a", subagent: nil))), displayItemIdentity(.plain(.thinking(thinking: "a longer", subagent: nil))))
        XCTAssertEqual(displayItemIdentity(.plain(.text(text: "a", subagent: nil))), displayItemIdentity(.plain(.text(text: "longer", subagent: nil))))
    }
    func testThinkingServerTimesAreDecodedAndCompactMergeKeepsBothBodyAndActivity() throws {
        let local = try parityDecode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"thinking","thinking":"long body","occurredAt":"2026-10-08T00:00:00Z"}]}"#)
        let incoming = try parityDecode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"thinking","thinking":"x","lastActivityAt":"2026-10-08T00:00:05Z"}]}"#)
        let result = applyingIncrementalMessage(incoming, expectedCount: 1, to: SessionMessageWindow(messages: [local], loadedOffset: 0, messageTotal: 1, leadingBlockOffset: 0, leadingBlockTotal: 1))
        if case .thinking(let body, _, let at, let last) = result.messages[0].content[0] { XCTAssertEqual(body, "long body"); XCTAssertNotNil(at); XCTAssertNotNil(last) } else { XCTFail("思考块丢失") }
    }
    func testUnknownFileActivityNeverFabricatesFileCounts() {
        XCTAssertEqual(toolActivityKind(name: "Read", input: [:]), "other")
        XCTAssertEqual(toolActivityKind(name: "Read", input: ["path": .string("/a")]), "read_file")
        XCTAssertEqual(toolActivityKind(name: "read", input: ["path": .string("/a"), "paths": .array([.string("/a"), .string("/b")])]), "other")
        XCTAssertEqual(toolActivityKind(name: "anything", input: ["__wandToolActivity": .object(["kind": .string("edit_file")])]), "edit_file")
    }
    func testOldPiServiceDoesNotInventCapabilityControls() throws {
        let response = try parityDecode(PiResourcesResponse.self, #"{"settings":{}}"#)
        XCTAssertFalse(response.editable); XCTAssertFalse(response.codemodeAvailable); XCTAssertFalse(response.codemodeOnlyAvailable)
    }
    func testPiLocksAndAutoResourcesAreExplicitlySaved() async {
        let fake = PiFake(), store = PiResourcesStore(sessionID: "s", service: fake); await store.load()
        store.setSkill("skill", mode: "locked"); store.setMcp("mcp", enabled: true); store.draft.autoResources = true
        fake.ack = store.draft; store.save(); await settle { store.phase == .sent }
        XCTAssertEqual(fake.bodies[0]["lockedSkills"] as? [String], ["skill"]); XCTAssertEqual(fake.bodies[0]["autoResources"] as? Bool, true)
    }
    func testPiInvalidOrUnknownAckKeepsSelectionAndRequiresRead() async {
        let fake = PiFake(), store = PiResourcesStore(sessionID: "s", service: fake); await store.load(); store.setSkill("skill", mode: "on")
        fake.ack = PiResourcesResponse.Settings(); store.save(); await settle { store.uncertain }
        XCTAssertEqual(store.draft.resources?.skills, ["skill"]); store.save(); XCTAssertEqual(fake.bodies.count, 1)
    }
    func testModelGroupValidationProtectsFreeBoundaryAndConcreteIDs() {
        XCTAssertNotNil(modelGroupValidation([ModelGroup(id: "openrouter-free", provider: "pi", name: "免费分组", models: ["paid-model"])]))
        XCTAssertNotNil(modelGroupValidation([ModelGroup(id: "x", provider: "claude", name: "x", models: ["wand-auto-assign/auto"])]))
        XCTAssertNil(modelGroupValidation([ModelGroup(id: "x", provider: "claude", name: "组", models: ["model-a", "model-b"])]))
        XCTAssertNotNil(modelGroupValidation([ModelGroup(id: "x", provider: "claude", name: "组", models: ["model-a", "model-a"])]))
    }
    func testOpenCodeFreeGroupKeepsNativeSelectorAndSavedServerMembership() throws {
        let group = ModelGroup(id: "opencode-free", provider: "opencode", name: "免费分组", models: ["opencode/a-free", "opencode/b-free"])
        XCTAssertTrue(group.builtIn)
        XCTAssertEqual(group.selector, "wand-model-group/opencode/opencode-free")
        XCTAssertNil(modelGroupValidation([group]))
        XCTAssertNil(modelGroupValidation([ModelGroup(id: group.id, provider: group.provider, name: group.name, models: [])]))
        XCTAssertNil(modelGroupValidation([ModelGroup(id: group.id, provider: group.provider, name: group.name, models: ["opencode/big-pickle"])]))
        XCTAssertNotNil(modelGroupValidation([ModelGroup(id: group.id, provider: group.provider, name: group.name, models: ["other/paid"])]))
        XCTAssertNotNil(modelGroupValidation([ModelGroup(id: group.id, provider: group.provider, name: group.name, models: ["opencode/default"])]))
        let catalog = try parityDecode(ModelsResponse.self, #"{"modelGroups":[],"freeModels":[]}"#)
        XCTAssertEqual(modelGroupsDraft([group], catalog: catalog).first { $0.openCodeFree }, group)
    }
    func testFreeGroupKeepsPriorityAndAppendsOnlyVerifiedNewMembers() throws {
        let catalog = try parityDecode(ModelsResponse.self, #"{"modelGroupsSupported":true,"freeModels":[{"id":"wand-openrouter-free/a","label":"a"},{"id":"wand-openrouter-free/b","label":"b"}]}"#)
        let rows = modelGroupsDraft([ModelGroup(id: "openrouter-free", provider: "pi", name: "免费分组", models: ["wand-openrouter-free/b", "removed"])], catalog: catalog)
        XCTAssertEqual(rows.first?.models, ["wand-openrouter-free/b", "wand-openrouter-free/a"])
    }
    func testTeamSuggestionDoesNotStartAndLateSuggestionCannotReplaceNewNote() async {
        let fake = DispatchFake(); fake.suspendPlan = true
        let store = TeamDispatchStore(service: fake, baseURL: parityURL, defaults: defaults()); store.note = "old"; store.suggest()
        await settle { fake.planContinuation != nil }; store.note = "new"
        fake.planContinuation?.resume(returning: fake.plan); await settle { store.phase != .sending }
        XCTAssertNil(store.plan); XCTAssertEqual(fake.starts, 0); XCTAssertEqual(store.note, "new")
    }
    func testTeamStartRequiresConfirmedMembersAndUnknownStartIsNotRepeated() async {
        let fake = DispatchFake(), d = defaults(), store = TeamDispatchStore(service: fake, baseURL: parityURL, defaults: d)
        store.note = "work"; store.workspaceID = "w"; store.start(onAccepted: { _ in }); XCTAssertEqual(fake.starts, 0)
        store.suggest(); await settle { store.plan != nil }; fake.startFailure = WandAPI.APIError.network("unknown")
        store.start(onAccepted: { _ in }); await settle { store.uncertain }
        store.start(onAccepted: { _ in }); XCTAssertEqual(fake.starts, 1)
        let reopened = TeamDispatchStore(service: fake, baseURL: parityURL, defaults: d); XCTAssertTrue(reopened.uncertain)
    }
    func testDraftLeaseCannotDeactivateAnotherMountedSurface() {
        let draft = ComposerDraftState(sessionId: "lease", api: api(), defaults: defaults()), a = UUID(), b = UUID()
        draft.acquire(a); draft.acquire(b); let revision = draft.lifecycleRevision
        draft.release(a); XCTAssertTrue(draft.active); XCTAssertEqual(draft.lifecycleRevision, revision)
        draft.release(b); XCTAssertFalse(draft.active)
    }
    func testHistoricalQuestionCannotSendAnAnswerToCurrentExecution() throws {
        let store = ChatStore(sessionId: "s", api: api(), drafts: SessionDraftStore())
        store.messages = [try parityDecode(ConversationTurn.self, #"{"role":"assistant","content":[{"type":"tool_use","id":"old","name":"AskUserQuestion","input":{}}]}"#), ConversationTurn(role: "user", content: [.text(text: "new turn", subagent: nil)])]
        XCTAssertFalse(store.activeQuestionIDs.contains("old")); XCTAssertTrue(store.displayedAskSelections["old"]?.submitted == true)
        store.submitAskUser(toolUseId: "old", answerText: "old answer"); XCTAssertFalse(store.inputSending)
    }
    func testPlainIMStreamingChangesRenderRevisionAfterLongPrefix() throws {
        let prefix = String(repeating: "a", count: 4000)
        let data: (String) throws -> ConversationMessage = { text in
            try JSONDecoder().decode(ConversationMessage.self, from: JSONSerialization.data(withJSONObject: ["messageId": "m", "role": "assistant", "content": [["type": "text", "text": text]]]))
        }
        XCTAssertNotEqual(try data(prefix).renderRevision, try data(prefix + "next").renderRevision)
    }
    func testMultipleAPIOwnersCannotEraseAnotherPendingRequest() async throws {
        let d = defaults(), first = ConversationRequestLedger(baseURL: parityURL, defaults: d), second = ConversationRequestLedger(baseURL: parityURL, defaults: d)
        let a = try await first.reserve(fingerprint: "a"), b = try await second.reserve(fingerprint: "b")
        await first.finish(requestId: a)
        let pending = await second.pending()
        XCTAssertEqual(pending, [b])
    }
    func testReturningFromSessionToConversationDoesNotDuplicateNavigationParent() {
        XCTAssertEqual(contactNavigationPath(parents: ["wand:conversation:dm_e"], selection: "wand:conversation:dm_e"), ["wand:conversation:dm_e"])
        XCTAssertEqual(contactNavigationPath(parents: ["wand:conversation:dm_e"], selection: "s1"), ["wand:conversation:dm_e", "s1"])
    }
    func testPendingWorkspaceOrderSurvivesPollAndKeepsNewServerGroups() throws {
        let groups = try parityDecode([TaskDirectoryGroup].self, #"[{"workspaceId":"a","workspaceName":"a","workspaceCwd":"/a","tasks":[],"standaloneSessions":[]},{"workspaceId":"b","workspaceName":"b","workspaceCwd":"/b","tasks":[],"standaloneSessions":[]},{"workspaceId":"c","workspaceName":"c","workspaceCwd":"/c","tasks":[],"standaloneSessions":[]}]"#)
        XCTAssertEqual(applyingWorkspaceGroupOrder(groups, order: ["b", "gone", "a"]).map(\.id), ["b", "a", "c"])
        XCTAssertEqual(applyingWorkspaceGroupOrder(groups, order: nil).map(\.id), ["a", "b", "c"])
    }
    func testBoardKeepsPiCLIAndWandAgentInSeparateGroups() throws {
        let rows = try parityDecode([WandBoardTaskSession].self, #"[{"id":"cli","provider":"pi","sessionKind":"structured","engine":"cli"},{"id":"sdk","provider":"pi","sessionKind":"structured","engine":"sdk"}]"#)
        let groups = wandBoardSessionGroups(sessions: rows, assigned: nil)
        XCTAssertEqual(groups.count, 2); XCTAssertEqual(groups.map(\.toolLabel), ["Pi", "Wand Agent"])
        XCTAssertNotEqual(groups[0].id, groups[1].id)
    }
    func testPaletteMatchesCurrentAndroidInBothAppearances() {
        let rows: [(Color, UInt32, UInt32)] = [(Theme.brand, 0x0076D6, 0x63B4FF), (Theme.background, 0xF2F3F7, 0x101114), (Theme.surface, 0xFFFFFF, 0x1C1D21), (Theme.surfaceSoft, 0xEDEEF2, 0x27282D), (Theme.textPrimary, 0x1C1D21, 0xF4F5F7), (Theme.textSecondary, 0x60636B, 0xC4C7CF)]
        for (color, light, dark) in rows {
            for (style, expected) in [(UIUserInterfaceStyle.light, light), (.dark, dark)] {
                let actual = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; actual.getRed(&r, green: &g, blue: &b, alpha: &a)
                let hex = UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
                XCTAssertEqual(hex, expected)
            }
        }
    }
    func testMarkdownBlocksPreserveStructureAndUnfinishedStreamingCode() {
        XCTAssertEqual(MarkdownText.parseBlocks("# 标题\n\n**粗体** 与 [链接](https://example.com)\n\n- 第一项\n  - [x] 已完成\n2. 第二项\n\n> 引用\n\n---"), [
            .heading(1, "标题"), .paragraph("**粗体** 与 [链接](https://example.com)"),
            .listItem(marker: "•", text: "第一项", indent: 0, checked: nil),
            .listItem(marker: "•", text: "已完成", indent: 1, checked: true),
            .listItem(marker: "2.", text: "第二项", indent: 0, checked: nil),
            .quote("引用"), .divider
        ])
        XCTAssertEqual(MarkdownText.parseBlocks("```swift\nlet value = 1\n"), [.code("let value = 1", "swift")])
        XCTAssertEqual(MarkdownText.parseBlocks("```swift\nlet value = 1\n```\n\n后续正文"), [.code("let value = 1", "swift"), .paragraph("后续正文")])
        XCTAssertEqual(MarkdownText.parseBlocks("| 名称 | 结果 |\n| --- | --- |\n| Markdown | **支持** |"), [.table(headers: ["名称", "结果"], rows: [["Markdown", "**支持**"]])])
    }

    func testConversationPreviewsShareMarkdownAndDestinationsOwnNavigationChrome() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("Wand/" + name), encoding: .utf8) }
        let conversation = try source("ConversationViews.swift")
        XCTAssertTrue(conversation.contains("MarkdownText(text: text.isEmpty"))
        XCTAssertTrue(conversation.contains("MarkdownText(text: message.taskPreview?"))
        XCTAssertTrue(conversation.contains(".environment(\\.serverFileLinkController, messageLinks)"))
        let nativeRoot = try source("NativeRootView.swift")
        XCTAssertTrue(nativeRoot.contains("usesSystemNavigation && enabled"),
                      "The workspace toolbar must be scoped to its system-owned destination")
        XCTAssertTrue(nativeRoot.contains("else if !usesSystemNavigation"),
                      "Inline navigation hiding must not suppress a system-owned child title")
        XCTAssertTrue(try source("SessionDestinationView.swift").contains(".toolbar(showsNavigationChrome ? .visible : .automatic, for: .navigationBar)"))
        // 单层导航：普通布局隐藏任务栏；Duo 系统布局继承会话标题与动作。
        let taskPage = try source("WorkspaceTaskView.swift")
        XCTAssertTrue(taskPage.contains(".toolbar(presentsSession && !usesSystemNavigation ? .hidden : .visible, for: .navigationBar)"),
                      "普通会话布局不叠第二条顶栏，系统布局保留会话原生栏")
        XCTAssertTrue(taskPage.contains("TaskNavigationTitle(inheritsSessionTitle: usesSystemNavigation && presentsSession)"),
                      "系统模式必须继承当前会话标题，不能被任务容器清空")
        XCTAssertTrue(taskPage.contains("hostActions: taskActions"))
        for name in ["ChatView.swift", "SessionDestinationView.swift"] {
            let destination = try source(name)
            XCTAssertTrue(destination.contains("SessionActionPalette(actions: hostActions.map(\\.menuAction))"),
                          "Host task actions must keep their callbacks and disabled state in the shared native icon menu: " + name)
        }
        XCTAssertTrue(conversation.contains("SessionActionPalette(actions: conversationMenuActions)"))
        for name in ["ChatView.swift", "SessionDestinationView.swift", "WorkspaceTaskView.swift", "ConversationViews.swift"] {
            let page = try source(name)
            XCTAssertFalse(page.contains("sessionStrip("), name)
            XCTAssertFalse(page.contains("TaskSessionTabStrip"), name)
            XCTAssertFalse(page.contains("taskSessionSwipeTarget"), name)
        }
        XCTAssertTrue(try source("ChatView.swift").contains("SessionBackSwipeEnabler()"))
        XCTAssertTrue(try source("SessionDestinationView.swift").contains("SessionBackSwipeEnabler()"))
        XCTAssertTrue(try source("ConversationViews.swift").contains("SessionBackSwipeEnabler()"))
        let swipePage = try source("SessionDestinationView.swift")
        XCTAssertTrue(swipePage.contains("nav.interactivePopGestureRecognizer"))
        XCTAssertTrue(swipePage.contains("originalDelegate = pop.delegate"))
        XCTAssertTrue(swipePage.contains("pop.delegate = originalDelegate") || swipePage.contains("gesture.delegate = originalDelegate"))
        XCTAssertFalse(swipePage.contains("handleEdgePan"), "UIKit, not an app pan, must drive the interactive pop")
        XCTAssertFalse(swipePage.contains("renderedSnapshot"), "Back navigation must reveal the live previous page")
        XCTAssertFalse(swipePage.contains("SessionBackSwipePreview"), "No cached list image is a navigation destination")
        XCTAssertFalse(swipePage.contains("UIImageView"), "No app-owned bitmap layers may imitate either page")
        let nativeNavigationSource = try source("NativeRootView.swift")
        XCTAssertTrue(nativeNavigationSource.contains("NavigationStack(path: systemNavigationPath)"))
        XCTAssertFalse(nativeNavigationSource.contains("systemSidebarPreview"))

    }

    func testWorkspaceTaskInlineSessionSelectionStaysSynchronizedAndSheetsBlockCompletionAck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Wand/WorkspaceTaskView.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(".onChange(of: store.visibleSessionID)"), "Direct store selection changes must update the inline session destination")
        XCTAssertTrue(source.contains("syncPresentedSession(id)"), "The root task selection must stay aligned with the visible session")
        XCTAssertTrue(source.contains("sessionSwitcherPresented || store.pickerPresented"), "The session switcher sheet must suppress completion acknowledgement")
    }

    func testInstalledOwnSessionMarkdownReadOnly() async throws {
        let pointer = URL(fileURLWithPath: "/tmp/wand-ios-markdown-profile-path")
        guard let path = try? String(contentsOf: pointer, encoding: .utf8) else {
            throw XCTSkip("Requires an explicit private installed-service acceptance profile")
        }
        struct Profile: Decodable { let baseUrl: String; let token: String?; let sessionId: String }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = WandAPI(baseURL: URL(string: profile.baseUrl)!, token: profile.token)
        let session = try await api.getSession(id: profile.sessionId)
        XCTAssertEqual(session.id, profile.sessionId)
        let texts = (session.messages ?? []).flatMap(\.content).compactMap { block -> String? in
            if case .text(let text, _) = block { return text }; return nil
        }
        XCTAssertFalse(texts.isEmpty)
        XCTAssertTrue(texts.contains { !MarkdownText.parseBlocks($0).isEmpty })
        _ = try await api.iosIpaUpdate(currentVersion: "0.0.0")
        // Only this task's own session; no other employee's private conversation is fetched.
    }

    func testInstalledServiceReadOnlyNativeContracts() async throws {
        let pointer = URL(fileURLWithPath: "/tmp/wand-ios-current-parity-profile-path")
        let path = ProcessInfo.processInfo.environment["WAND_INSTALLED_PARITY_PROFILE"] ?? (try? String(contentsOf: pointer, encoding: .utf8))
        guard let path else { throw XCTSkip("Installed acceptance requires a private profile supplied explicitly") }
        struct Profile: Decodable { let baseUrl: String; let token: String?; let repositoryPath: String }
        let data = try Data(contentsOf: URL(fileURLWithPath: path)); XCTAssertLessThan(data.count, 16 * 1024)
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        let api = WandAPI(baseURL: URL(string: profile.baseUrl)!, token: profile.token)
        _ = try await api.serverConfig() // Endpoint-scoped native authentication; no password/admin escalation.
        let summaries = try await api.conversations(); XCTAssertTrue(summaries.allSatisfy { !$0.id.isEmpty })
        if summaries.contains(where: { $0.id == "dm_e_wand_default" }) {
            let ownConversation = try await api.conversation("dm_e_wand_default")
            XCTAssertEqual(ownConversation.kind, "dm") // No other employee's private conversation/knowledge is read or copied.
        }
        _ = try await api.listWorkspaces(); _ = try await api.listTaskGroups(); _ = try await api.models()
        let preview = try await api.previewFile(profile.repositoryPath + "/AGENTS.md")
        XCTAssertEqual(preview.kind, "text"); XCTAssertTrue(preview.canEdit)
        _ = try await api.iosIpaUpdate(currentVersion: "0.0.0")
        // Only GETs (apart from native token login): no session creation, input, CAS, file write, or model execution.
    }
    /// Bounded diagnostic for IOS-04: no live credentials, cache clearing or model calls.
    /// These captures distinguish controlled loading from the unexplained 58s live observation.
    func testConversationColdLoadDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["WAND_CHAT_LOAD_DIAGNOSTIC"] == "1" else {
            throw XCTSkip("Opt-in cold/slow/failure diagnostic captures")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func capture(_ window: UIWindow, name: String) {
            let host = window.rootViewController!.view!
            host.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: host.bounds.size).image { _ in host.drawHierarchy(in: host.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "ios04-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        for failing in [false, true] {
            let fake = ConversationFake(); fake.suspendLoads = true
            let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: ConversationDetailView(id: "dm_e", store: store,
                onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in }))
            window.makeKeyAndVisible()
            await settle { fake.loads.count == 1 }
            try await Task.sleep(for: .seconds(1.5))
            XCTAssertNil(store.details["dm_e"])
            capture(window, name: failing ? "cold-before-failure" : "slow-loading")
            if failing {
                fake.loads[0].resume(throwing: WandAPI.APIError.network("诊断夹具：网络不可用"))
                await settle { store.error != nil }
                try await Task.sleep(for: .milliseconds(200))
                capture(window, name: "failed-with-retry")
            } else {
                fake.loads[0].resume(returning: try parityDecode(ConversationInstance.self,
                    #"{"id":"dm_e","kind":"dm","title":"冷加载诊断","messages":[{"messageId":"loaded","role":"assistant","content":[{"type":"text","text":"历史内容自然出现：没有打开键盘或附件层。"}]}]}"#))
                await settle { store.details["dm_e"]?.messages.count == 1 }
                try await Task.sleep(for: .milliseconds(300))
                capture(window, name: "loaded-without-interaction")
            }
            window.isHidden = true; store.shutdown()
        }
        let empty = ConversationStore(api: api(), service: ConversationFake(), drafts: SessionDraftStore(), defaults: defaults())
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ConversationDetailView(id: "dm_e", store: empty,
            onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in }))
        window.makeKeyAndVisible()
        await settle { empty.details["dm_e"] != nil }
        try await Task.sleep(for: .milliseconds(200))
        capture(window, name: "confirmed-empty")
        window.isHidden = true; empty.shutdown()
    }

    func testFirstConversationReplyKeepsShortTranscriptAtTop() async throws {
        let fake = ConversationFake()
        func detail(_ text: String) throws -> ConversationInstance {
            let payload: [String: Any] = ["id": "dm_e", "kind": "dm", "title": "首轮滚动验证", "messages": [
                ["messageId": "user", "role": "user", "content": [["type": "text", "text": "你好"]]],
                ["messageId": "reply", "role": "assistant", "content": [["type": "text", "text": text]]]
            ]]
            return try JSONDecoder().decode(ConversationInstance.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        fake.detail = try detail("开始回复")
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        await store.load("dm_e")
        let host = UIHostingController(rootView: ConversationDetailView(id: "dm_e", store: store,
            onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; store.shutdown() }
        func scrollViews(_ root: UIView) -> [UIScrollView] {
            (root is UITextView ? [] : (root as? UIScrollView).map { [$0] } ?? []) + root.subviews.flatMap(scrollViews)
        }
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(scrollViews(host.view).max { $0.bounds.height < $1.bounds.height })
        var shortSamples = 0
        var overflowSamples = 0
        for chunk in 1...32 {
            fake.detail = try detail(Array(repeating: "首条回复增长时不应把整段对话上下推拉。", count: chunk).joined(separator: "\n"))
            await store.load("dm_e")
            try await Task.sleep(for: .milliseconds(60))
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            print("IM-FIRST-REPLY chunk=\(chunk) content=\(scroll.contentSize.height) viewport=\(scroll.bounds.height) offset=\(scroll.contentOffset.y)")
            if scroll.contentSize.height < scroll.bounds.height - 1 {
                shortSamples += 1
                // A bottom-aligned ScrollView synthesizes a positive top inset;
                // comparing against -adjustedContentInset.top would wrongly accept
                // the very drift this test must catch. This list has no top inset.
                XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 1, "Like Android, short conversations stay at the top during streaming")
            } else if bottom > top {
                overflowSamples += 1
                XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 14, "Long conversations still follow the tail with 12pt padding")
            }
        }
        XCTAssertGreaterThan(shortSamples, 2)
        XCTAssertGreaterThan(overflowSamples, 2)
        let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        screenshot.name = "first-reply-streamed-tail"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testColdConversationFillsViewportBeforeDetailArrives() {
        let store = ConversationStore(api: api(), service: ConversationFake(), drafts: SessionDraftStore(), defaults: defaults())
        let host = UIHostingController(rootView: ConversationDetailView(id: "dm_e", store: store,
            onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in }))
        let size = host.sizeThatFits(in: CGSize(width: 440, height: 956))
        XCTAssertEqual(size.width, 440, accuracy: 1)
        XCTAssertEqual(size.height, 956, accuracy: 1)
    }

    func testExistingToolTimelineReadabilityReplay() async throws {
        guard ProcessInfo.processInfo.environment["WAND_TIMELINE_REPLAY_TEST"] == "1" else {
            throw XCTSkip("Requires existing own tool sample and isolated native touch driver")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("output/ios-client-fixes-task86-97/batch1-20261017/existing-own-timeline-tool.json"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try JSONDecoder().decode([ContentBlock].self, from: JSONSerialization.data(withJSONObject: raw["blocks"]!))
        guard content.count == 2,
              case .toolUse(let id, let name, let description, let input, let subagent) = content[0],
              case .toolResult(let resultID, let text, let failed, let truncated, let images, _, let projection) = content[1] else {
            return XCTFail("Expected the captured own tool/result pair")
        }
        XCTAssertEqual(id, resultID)
        let item = DisplayItem.tool(id: id, name: name, description: description, input: input, subagent: subagent,
            result: ToolResultInfo(toolUseId: id, text: text, isError: failed, truncated: truncated, images: images, projection: projection))
        let group = ActivityGroup(latest: "Read", meta: "已有源码读取结果", count: 1, items: [item], newest: true)
        let finished = expectation(description: "existing native timeline controls and detail checked")
        let original = UserDefaults.standard.object(forKey: "wand.trafficTimelineMode")
        UserDefaults.standard.set("all", forKey: "wand.trafficTimelineMode")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ExistingTimelineReplayFixture(group: group, finished: { finished.fulfill() }))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            if let original { UserDefaults.standard.set(original, forKey: "wand.trafficTimelineMode") }
            else { UserDefaults.standard.removeObject(forKey: "wand.trafficTimelineMode") }
        }
        await fulfillment(of: [finished], timeout: 120)
    }

    func testToolImageErrorRetryViewerAndCredentialLifetimeIsolation() async throws {
        guard ProcessInfo.processInfo.environment["WAND_MESSAGE_IMAGE_TEST"] == "1" else {
            throw XCTSkip("Requires isolated image replay and external touch driver")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("output/ios-client-fixes-task86-97/batch1-20261017/existing-own-tool-image.png"))
        XCTAssertNotNil(UIImage(data: data), "The existing own tool PNG must decode natively")
        let state = MessageImageReplayState(data: data)
        let finished = expectation(description: "image failure, retry, viewer and new credential lifetime driven")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MessageImageReplayFixture(state: state, finished: { finished.fulfill() }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; SelfSignedSession.resetEndpoint(state.baseURL) }
        await fulfillment(of: [finished], timeout: 120)
        XCTAssertEqual(MessageImageReplayProtocol.requestCount, 3, "403, successful retry, and fresh-lifetime 404; data URI must not request the network")
        XCTAssertEqual(state.generation, 1)
        XCTAssertTrue(state.inline, "The final displayed image must use the data-URI path")
    }

    func testConversationSearchEmptyRecoveryNativeReplay() async throws {
        guard ProcessInfo.processInfo.environment["WAND_SEARCH_EMPTY_TEST"] == "1" else {
            throw XCTSkip("Requires controlled native list/search touch replay")
        }
        let fake = ConversationFake()
        fake.rows = try parityDecode([ConversationInstance].self, #"[{"id":"dm_search","kind":"dm","title":"样例员工","preview":"已有对话A"},{"id":"group_search","kind":"group","title":"样例群","preview":"已有对话B"}]"#)
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults())
        await store.refresh()
        let finished = expectation(description: "search empty action and closing restore the existing list")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 8) {
            Text("搜索空态受控回归").font(.headline)
            ConversationListView(store: store, onSelect: { _ in }, onEmployee: { _ in }, onSettings: {}, onSwitchServer: {})
            Button("结束搜索验收") { finished.fulfill() }.frame(minHeight: 44)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.background))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; store.shutdown() }
        await fulfillment(of: [finished], timeout: 150)
        XCTAssertEqual(store.items.map(\.id), ["dm_search", "group_search"])
        XCTAssertTrue(fake.posts.isEmpty, "Search recovery must not mutate/create conversations")
    }

    func testNativeGroupDraftToggleProjectsPresetSelectionWithoutDuplicates() throws {
        let employees = try parityDecode([SiliconEmployee].self, #"[{"id":"e0","name":"员工零"},{"id":"e1","name":"员工一"}]"#)
        let team = try parityDecode(ContactTeam.self, #"{"id":"preset","name":"预设","members":[{"id":"preset-member","employeeId":"e0","name":"员工零","isLeader":true}]}"#)
        var draft = ConversationGroupDraft(); draft.templateId = team.id; draft.leaderId = "preset-member"
        XCTAssertEqual(draft.members(employees: employees, presets: [team]).count, 1)
        draft.selectEmployee("e0", selected: false, employees: employees, presets: [team])
        XCTAssertTrue(draft.members(employees: employees, presets: [team]).isEmpty)
        XCTAssertEqual(draft.leaderId, "")
        draft.selectEmployee("e0", selected: true, employees: employees, presets: [team])
        XCTAssertEqual(draft.members(employees: employees, presets: [team]).map(\.employeeId), ["e0"])
        draft.selectEmployee("e1", selected: true, employees: employees, presets: [team])
        XCTAssertEqual(draft.members(employees: employees, presets: [team]).count, 2)
        draft.selectEmployee("e1", selected: false, employees: employees, presets: [team])
        XCTAssertEqual(draft.members(employees: employees, presets: [team]).count, 1)
    }

    func testConversationIdentityStatusDoesNotResurrectHistoricalFailures() throws {
        func instance(_ runs: [[String: Any]], extra: [String: Any] = [:]) throws -> ConversationInstance {
            var value: [String: Any] = ["id": "header", "kind": "group", "title": "协作群", "tasks": [["task": ["id": "task"], "runs": runs]]]
            value.merge(extra) { _, new in new }
            return try JSONDecoder().decode(ConversationInstance.self, from: JSONSerialization.data(withJSONObject: value))
        }
        func run(_ status: String, _ time: String) -> [String: Any] {
            ["id": status + time, "teamId": "team", "taskId": "task", "status": status, "updatedAt": time]
        }
        let history = [run("failed", "2026-10-16"), run("done", "2026-10-17")]
        XCTAssertEqual(try instance(history).identityStatus, "群聊 · 可派发任务")
        XCTAssertEqual(try instance(history + [run("waiting_user", "2026-10-18")]).identityStatus, "等待你的回复")
        XCTAssertEqual(try instance([run("running", "2026-10-18")], extra: ["dissolvedAt": "2026-10-19"]).identityStatus, "群聊已解散")
        XCTAssertEqual(try instance([], extra: ["unavailableReason": "拒绝访问"]).identityStatus, "当前对象暂不可用")
        XCTAssertEqual(try instance([], extra: ["unavailableReason": " "]).identityStatus, "群聊 · 可派发任务")
    }

    func testAppleNamedChatHeaderNativeSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["WAND_APPLE_IDENTITY_SNAPSHOTS"] == "1" else { throw XCTSkip("Native identified header captures") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, width, height, compact, dark, type) in [
            ("phone-light", CGFloat(440), CGFloat(956), false, false, DynamicTypeSize.large),
            ("phone-dark", 440, 956, false, true, DynamicTypeSize.large),
            ("narrow-large", 320, 780, false, false, DynamicTypeSize.accessibility3),
            ("landscape", 956, 440, true, false, DynamicTypeSize.large)
        ] {
            let window = UIWindow(windowScene: scene)
            let root = AppleNamedIdentityFixture().environment(\.dynamicTypeSize, type)
                .environment(\.verticalSizeClass, compact ? .compact : .regular).environment(\.colorScheme, dark ? .dark : .light)
            let host = UIHostingController(rootView: root)
            window.rootViewController = host; window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            window.makeKeyAndVisible(); host.view.frame = window.bounds
            host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let a = XCTAttachment(image: image); a.name = "apple-b92-" + name; a.lifetime = .keepAlways; add(a)
            window.isHidden = true
        }
    }

    func testAppleConversationNativeMenuInteraction() async throws {
        guard ProcessInfo.processInfo.environment["WAND_APPLE_ACTION_TOUCH"] == "1" else { throw XCTSkip("Owned native add-menu interaction fixture") }
        let fake = ConversationFake()
        fake.detail = try parityDecode(ConversationInstance.self, #"{"id":"menu-fixture","kind":"dm","title":"菜单验证员工"}"#)
        fake.rows = [fake.detail]
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults()); await store.refresh()
        let draft = store.composer(fake.detail.id, target: nil); draft.text = "retained-draft"
        let finished = expectation(description: "native anchored menu and file-picker cancellation")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
            HStack {
                Text("原生加号操作验收夹具").font(.caption); Spacer()
                Button("结束菜单验收") { finished.fulfill() }.frame(minHeight: 44)
            }.padding(.horizontal, 12)
            ConversationDetailView(id: fake.detail.id, store: store, onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in })
        }.background(Theme.background))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; store.shutdown() }
        await fulfillment(of: [finished], timeout: 180)
        XCTAssertEqual(draft.text, "retained-draft more")
        XCTAssertTrue(fake.posts.isEmpty)
        XCTAssertTrue(draft.attachments.attachments.isEmpty)
    }

    func testAppleDesignGroupInteraction() async throws {
        guard ProcessInfo.processInfo.environment["WAND_APPLE_DESIGN_TOUCH"] == "1" else {
            throw XCTSkip("Owned native group-selection touch fixture")
        }
        let fake = ConversationFake()
        fake.people = try (0..<10).map { try parityDecode(SiliconEmployee.self, "{\"id\":\"touch-e\($0)\",\"name\":\"员工\($0)\",\"duty\":\"实际协作职责\"}") }
        fake.rows = try parityDecode([ConversationInstance].self, #"[{"id":"existing","kind":"dm","title":"已有对话","preview":"打开和取消建群后保留列表与草稿。"}]"#)
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults()); await store.refresh()
        let finished = expectation(description: "group selection, cancel, reopen and retained draft driven")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
            HStack {
                Text("设计A原生交互夹具").font(.caption)
                Spacer()
                Button("结束验收") { finished.fulfill() }.frame(minHeight: 44)
            }.padding(.horizontal, 12)
            ConversationListView(store: store, onSelect: { _ in }, onEmployee: { _ in }, onSettings: {}, onSwitchServer: {})
        }.background(Theme.background))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; store.shutdown() }
        await fulfillment(of: [finished], timeout: 180)
        XCTAssertEqual(store.groupDrafts["create"]?.employeeIds.count, 2)
        XCTAssertEqual(store.groupDrafts["create"]?.name, "design-A")
        XCTAssertTrue(fake.posts.isEmpty)
    }

    func testAppleDesignListAndGroupNativeSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["WAND_APPLE_DESIGN_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Opt-in real native appearance/dynamic-type captures")
        }
        let fake = ConversationFake()
        fake.people = try (0..<10).map { try parityDecode(SiliconEmployee.self, "{\"id\":\"design-e\($0)\",\"name\":\"员工\($0) · 很长的身份名称\",\"duty\":\"负责实际项目协作与交付，保留全部职责和上下文\"}") }
        fake.rows = try parityDecode([ConversationInstance].self, #"[{"id":"design-dm","kind":"dm","title":"当前员工的长对话名字与项目协作上下文","preview":"已有消息与附件保留，加载失败也不清空输入。"},{"id":"design-group","kind":"group","title":"协作小组","preview":"任务与对话层级清楚。"}]"#)
        let store = ConversationStore(api: api(), service: fake, drafts: SessionDraftStore(), defaults: defaults()); await store.refresh()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, width, height, dark, category) in [
            ("phone-light", CGFloat(440), CGFloat(956), false, ContentSizeCategory.large),
            ("phone-dark", 440, 956, true, ContentSizeCategory.large),
            ("narrow-large", 320, 780, false, ContentSizeCategory.accessibilityExtraExtraLarge)
        ] {
            for group in [false, true] {
                store.creatingPresetID = group ? "" : nil
                let window = UIWindow(windowScene: scene)
                let content = ConversationListView(store: store, onSelect: { _ in }, onEmployee: { _ in }, onSettings: {}, onSwitchServer: {})
                    .environment(\.colorScheme, dark ? .dark : .light).environment(\.sizeCategory, category)
                    .transaction { $0.disablesAnimations = true }
                let host = UIHostingController(rootView: content)
                window.rootViewController = host; window.frame = CGRect(x: 0, y: 0, width: width, height: height)
                window.makeKeyAndVisible(); host.view.frame = window.bounds
                host.traitOverrides.userInterfaceStyle = dark ? UIUserInterfaceStyle.dark : .light
                host.traitOverrides.preferredContentSizeCategory = category == .large ? UIContentSizeCategory.large : .accessibilityExtraExtraLarge
                host.traitOverrides.accessibilityContrast = category == .large ? .normal : .high
                host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(host.view.bounds.width, width, accuracy: 1)
                XCTAssertEqual(host.view.bounds.height, height, accuracy: 1)
                let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "apple-a-" + name + (group ? "-group" : "-list"); attachment.lifetime = .keepAlways; add(attachment)
                window.isHidden = true
            }
        }
        store.shutdown()
        XCTAssertTrue(fake.posts.isEmpty)
    }

    func testConversationListEmptyStatesDoNotConfuseSearchWithMissingData() {
        XCTAssertEqual(ConversationListEmptyState.resolve(query: "", totalCount: 0, defaultFilter: true), .empty)
        XCTAssertEqual(ConversationListEmptyState.resolve(query: "zzqa404", totalCount: 5, defaultFilter: true), .search)
        XCTAssertEqual(ConversationListEmptyState.resolve(query: "zzqa404", totalCount: 0, defaultFilter: false), .search)
        XCTAssertEqual(ConversationListEmptyState.resolve(query: " \n ", totalCount: 5, defaultFilter: false), .filtered)
        XCTAssertEqual(ConversationListEmptyState.resolve(query: "", totalCount: 5, defaultFilter: true), .historyOnly)
        XCTAssertEqual(ConversationListEmptyState.search.actionTitle, "清空搜索")
        XCTAssertEqual(ConversationListEmptyState.filtered.actionTitle, "查看全部对话")
        XCTAssertEqual(ConversationListEmptyState.historyOnly.actionTitle, "查看已解散")
    }

    func testImageOnlyAttachmentsRemainVisibleAfterSubmissionTrim() {
        let files = [UploadedFile(originalName: "图片.png", savedPath: "/work/图片.png", size: 20, mimeType: "image/png")]
        let prompt = buildAttachmentPrompt(files, body: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = parseUserAttachmentMessage(prompt)
        XCTAssertEqual(parsed.attachmentPaths, ["/work/图片.png"])
        XCTAssertEqual(parsed.body, "")
        let withBody = parseUserAttachmentMessage(buildAttachmentPrompt(files, body: "请看图片").trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(withBody.attachmentPaths, parsed.attachmentPaths)
        XCTAssertEqual(withBody.body, "请看图片")
        XCTAssertEqual(parseUserAttachmentMessage("普通正文").body, "普通正文")
        XCTAssertTrue(parseUserAttachmentMessage("[附件已上传，请查看以下文件:\n/work/a.png").attachmentPaths.isEmpty)
    }

    func testToolImageLoadingAlwaysHasVisibleGeometry() {
        // 放大上限只有一处真源，两端同值：横图吃满宽、竖图吃满高，小图不拉伸。
        XCTAssertEqual(WandImageLayout.thumbnailMaxWidth, 320)
        XCTAssertEqual(WandImageLayout.thumbnailMaxHeight, 360)
        let host = UIHostingController(rootView: WandToolImageThumbnail(baseURL: parityURL, source: "/api/sessions/sample/tool-images/image.png"))
        let size = host.sizeThatFits(in: CGSize(width: 420, height: 900))
        XCTAssertGreaterThanOrEqual(size.width, 96)
        XCTAssertGreaterThanOrEqual(size.height, 64)
        XCTAssertLessThanOrEqual(size.width, WandImageLayout.thumbnailMaxWidth)
        XCTAssertLessThanOrEqual(size.height, WandImageLayout.thumbnailMaxHeight)
    }

    func testImageFiguresStayInsideReadingAreaWithoutCropping() {
        for viewport in [CGFloat(240), 600, 1000] {
            for width in [CGFloat(280), 390, 768] {
                let limit = WandImageLayout.figureBounds(availableWidth: width, viewportHeight: viewport)
                XCTAssertLessThanOrEqual(limit.width, width * 0.8)
                XCTAssertLessThanOrEqual(limit.height, viewport * 0.4)
                for dimensions in [CGSize(width: 900, height: 1950), CGSize(width: 1600, height: 900), CGSize(width: 800, height: 800)] {
                    let image = UIGraphicsImageRenderer(size: dimensions).image { context in
                        UIColor.systemTeal.setFill(); context.fill(CGRect(origin: .zero, size: dimensions))
                    }
                    let host = UIHostingController(rootView: WandImageFigureLayout(viewportHeight: viewport) {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    })
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 3000))
                    XCTAssertGreaterThan(size.width, 0)
                    XCTAssertLessThanOrEqual(size.width, limit.width + 1)
                    XCTAssertLessThanOrEqual(size.height, limit.height + 1)
                    XCTAssertEqual(size.width / size.height, dimensions.width / dimensions.height, accuracy: 0.02)
                }
            }
        }
    }

    func testLoadedImageFigureHasBoundedNativeGeometry() async throws {
        let dimensions = CGSize(width: 390, height: 844)
        let image = UIGraphicsImageRenderer(size: dimensions).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(origin: .zero, size: dimensions))
            ("图片预览 · 不是应用页面" as NSString).draw(at: CGPoint(x: 24, y: 80),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.white])
        }
        let data = try XCTUnwrap(image.pngData())
        let host = UIHostingController(rootView: WandToolImageFigure(baseURL: parityURL,
            source: "data:image/png;base64," + data.base64EncodedString(), name: "手机截图.png")
            .environment(\.chatViewportHeight, 600))
        // Measure the figure, not the phone's top/bottom safe-area padding.
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 3000))
        // The filename sits above the image; the screenshot itself is at most 240pt tall.
        XCTAssertGreaterThan(size.height, 200)
        XCTAssertLessThan(size.height, 280)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "bounded-phone-image-figure"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMarkdownImagesPreserveTextAndSupportBalancedDestinations() {
        XCTAssertEqual(splitMarkdownImages("前文 ![聊天详情](/Users/test/chat.png) 后文"),
                       [.text("前文 "), .image(alt: "聊天详情", source: "/Users/test/chat.png"), .text(" 后文")])
        XCTAssertEqual(splitMarkdownImages("![页[二]](</work/a (2).png> \"截图\")"),
                       [.image(alt: "页[二]", source: "/work/a (2).png")])
        XCTAssertEqual(splitMarkdownImages("![A\\]](/work/a(b).png '截图')"),
                       [.image(alt: "A]", source: "/work/a(b).png")])
        XCTAssertEqual(splitMarkdownImages("![](/work/a\\ b.png)"), [.image(alt: "", source: "/work/a b.png")])
    }

    func testMarkdownImageCodeEscapesAndIncompleteSyntaxStayText() {
        for raw in ["`![例](/a.png)`", "`` `![例](/a.png)` ``", "\\![例](/a.png)", "![未结束](/a.png", "[普通链接](/a.txt)"] {
            XCTAssertEqual(splitMarkdownImages(raw), [.text(raw)])
        }
        XCTAssertEqual(splitMarkdownImages("`未配对 ![图](/a.png)"), [.text("`未配对 "), .image(alt: "图", source: "/a.png")])
    }

    func testMarkdownImageSourcesUseTheConnectedServerAndRejectUnsafeURLs() {
        for source in ["//other.test/a.png", "file:///tmp/a.png", "javascript:alert(1)", "content://a", "data:text/html;base64,AA", "../a.png", "a.png", "https://u:p@host.test/a.png", "/a\nb.png"] {
            XCTAssertNil(markdownImagePage(source), source)
        }
        XCTAssertEqual(markdownImagePage("/Users/test/a%20+%20b.png"), WandImagePage(source: "/Users/test/a + b.png", directSource: false))
        for source in ["https://host.test/a?size=2#preview", "/api/file-raw?path=%2Ftmp%2Fa.png", "data:image/png;base64,AA"] {
            XCTAssertEqual(markdownImagePage(source), WandImagePage(source: source, directSource: true))
        }
    }

    func testMarkdownImageGalleryIncludesRenderedBlocksButNotCodeExamples() {
        let text = "# 截图\n\n![聊天](/work/chat.png)\n\n- ![任务](/work/tasks.png)\n\n> ![设置](https://host.test/settings.png)\n\n```md\n![代码](/not.png)\n```\n\n`![例](/inline.png)`"
        let expected = [WandImagePage(source: "/work/chat.png", directSource: false), WandImagePage(source: "/work/tasks.png", directSource: false), WandImagePage(source: "https://host.test/settings.png", directSource: true)]
        XCTAssertEqual(MarkdownText.imagePages(text), expected)
        let pages = wandConversationImagePages([ConversationTurn(role: "assistant", content: [.text(text: text, subagent: nil)])])
        XCTAssertEqual(pages, expected)
        XCTAssertEqual(wandImageGallerySelection(gallery: pages, local: [], current: "/work/tasks.png", direct: false).startIndex, 1)
        let five = ["chat", "tasks", "workspace", "contacts", "settings"].map { "![\($0)](/Users/test/wand/output/architecture-stage2/duo-adaptation-analysis/key-pages/\($0).png)" }.joined(separator: "\n\n")
        XCTAssertEqual(MarkdownText.imagePages(five).count, 5)
    }

    func testMarkdownImageActuallyLoadsThroughTheSharedAuthenticatedImageView() async throws {
        for (label, source) in [("查看优化效果", "/work/preview.png"), ("截图", "/work/preview%2Epng"),
                                ("下载", "https://host.test/preview.JPG?size=2#view"),
                                ("原图", "/api/file-raw?path=%2Fwork%2Fpreview.png")] {
            XCTAssertEqual(splitMarkdownImages("前文 [\(label)](\(source)) 后文"),
                [.text("前文 "), .image(alt: label, source: source), .text(" 后文")])
        }
        for raw in ["[图片](/work/notes.md)", "[图片](https://host.test/page)", "[图片](javascript:bad.png)",
                    "[图片](//host.test/a.png)", "`[预览](/work/a.png)`", "\\![例](/a.png)", "\\[例](/a.png)"] {
            XCTAssertEqual(splitMarkdownImages(raw), [.text(raw)])
        }
        // Classification accepts relative images; the source-aware resolver decides access.
        XCTAssertEqual(splitMarkdownImages("[图片](../a.png)"), [.image(alt: "图片", source: "../a.png")])
        let delivery = "[查看优化效果](</work/a (2).png>)\n\n[记录](/work/log.md)\n\n```md\n[示例](/work/code.png)\n```"
        XCTAssertEqual(MarkdownText.imagePages(delivery), [WandImagePage(source: "/work/a (2).png", directSource: false)])
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 280)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 280))
        }
        let data = try XCTUnwrap(image.pngData())
        let state = MessageImageReplayState(data: data)
        state.install(responses: [200], reset: true)
        let host = UIHostingController(rootView: MarkdownText(text: "**正文图片**\n\n[聊天详情](/work/markdown-chat.png)")
            .environment(\.chatAPI, WandAPI(baseURL: state.baseURL, token: nil))
            .environment(\.chatViewportHeight, 600))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; SelfSignedSession.resetEndpoint(state.baseURL) }
        for _ in 0..<40 where MessageImageReplayProtocol.requestCount == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(MessageImageReplayProtocol.requestCount, 1, "Markdown images must reach the existing endpoint image loader")
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 3000))
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThan(size.height, 400)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "markdown-image-native-render"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testMarkdownInstalledServiceReplyImages() async throws {
        // Opt-in pointer contains only a connection-file path and source session id, never credentials.
        let marker = URL(fileURLWithPath: "/tmp/wand-markdown-installed-acceptance-path")
        guard let pointer = try? Data(contentsOf: marker),
              let config = try JSONSerialization.jsonObject(with: pointer) as? [String: String],
              let connectionFile = config["connectionFile"], let sessionId = config["sessionId"] else {
            throw XCTSkip("Requires explicit installed-service acceptance pointer")
        }
        let connection = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: connectionFile))) as? [String: String])
        let code = try XCTUnwrap(connection["connectionCode"])
        let decoded = try XCTUnwrap(WandAuth.decodeConnectCode(code))
        let baseURL = try XCTUnwrap(URL(string: try XCTUnwrap(connection["serverURL"])))
        let session = SelfSignedSession.forEndpoint(baseURL)
        defer { SelfSignedSession.resetEndpoint(baseURL) }
        let loginSucceeded: Bool = await withCheckedContinuation { continuation in
            WandAuth.loginWithToken(serverURL: baseURL, appToken: decoded.token, endpointSession: session) { result in
                if case .success = result { continuation.resume(returning: true) }
                else { continuation.resume(returning: false) }
            }
        }
        XCTAssertTrue(loginSucceeded, "Installed-service scoped login must succeed")
        guard loginSucceeded else { return }
        let endpoint = try XCTUnwrap(WandEndpoint.url(baseURL: baseURL, route: "/api/sessions/\(sessionId)", queryItems: [URLQueryItem(name: "format", value: "chat"), URLQueryItem(name: "blockBudget", value: "2000"), URLQueryItem(name: "byteBudget", value: "4000000"), URLQueryItem(name: "output", value: "omit")]))
        let (body, response) = try await session.session.data(from: endpoint)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let detail = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let turns = try XCTUnwrap(detail["messages"] as? [[String: Any]])
        // The user may continue this live session while acceptance is running. Select the original reply, not the latest turn.
        let needle = try XCTUnwrap(config["messageContains"])
        let text = try XCTUnwrap(turns.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .last { $0.contains(needle) })
        let pages = MarkdownText.imagePages(text)
        XCTAssertEqual(pages.count, Int(config["expectedImages"] ?? "") ?? 5)
        for page in pages {
            let url = try XCTUnwrap(page.directSource ? URL(string: page.source, relativeTo: baseURL) : WandEndpoint.url(baseURL: baseURL, route: "/api/file-raw", queryItems: [URLQueryItem(name: "path", value: page.source)]))
            let (data, response) = try await session.session.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertNotNil(UIImage(data: data), "The actual installed-service image must decode on iOS")
        }
        let host = UIHostingController(rootView: ScrollView {
            MarkdownText(text: text).padding(16)
        }.environment(\.chatAPI, WandAPI(baseURL: baseURL, token: nil)).environment(\.chatViewportHeight, 600))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let keys = pages.map { "\(session.resourceCacheNamespace)|\(baseURL.absoluteString)|\($0.directSource)|\($0.source)" as NSString }
        for _ in 0..<100 {
            if keys.allSatisfy({ WandImageCache.shared.object(forKey: $0) != nil }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(keys.allSatisfy { WandImageCache.shared.object(forKey: $0) != nil },
            "Reply images must load automatically through the rendered view, without tapping a link")
        host.view.layoutIfNeeded()
        let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "markdown-installed-service-reply"; attachment.lifetime = .keepAlways; add(attachment)
        try rendered.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-markdown-installed-reply.png"))
        window.isHidden = true
        var logout = URLRequest(url: try XCTUnwrap(WandEndpoint.url(baseURL: baseURL, route: "/api/logout")))
        logout.httpMethod = "POST"
        _ = try await session.session.data(for: logout)
    }

    func testInlineImagesPageWithinTheirGroup() throws {
        // 起始页钳制：越界与空分组都退回第一张，不崩溃。
        XCTAssertEqual(wandImageViewerStart(index: 2, count: 3), 2)
        XCTAssertEqual(wandImageViewerStart(index: 7, count: 3), 2)
        XCTAssertEqual(wandImageViewerStart(index: -1, count: 3), 0)
        XCTAssertEqual(wandImageViewerStart(index: 0, count: 0), 0)
        // 缩略图必须把同组图片交给全屏查看器，才有左右滑动切换。
        let thumbnail = WandImageThumbnail(baseURL: parityURL, path: "/work/b.png",
                                           group: ["/work/a.png", "/work/b.png"], groupIndex: 1)
        XCTAssertEqual(thumbnail.viewerSources, ["/work/a.png", "/work/b.png"])
        XCTAssertEqual(thumbnail.viewerStart, 1)
        let single = WandToolImageThumbnail(baseURL: parityURL, source: "/api/sessions/s/tool-images/0")
        XCTAssertEqual(single.viewerSources, ["/api/sessions/s/tool-images/0"])
        XCTAssertEqual(single.viewerStart, 0)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Wand/ChatView.swift"), encoding: .utf8)
        XCTAssertTrue(chat.contains("group: images, groupIndex: images.firstIndex(of: path) ?? 0"),
                      "同一气泡的附件图片要作为一组传给查看器")
        XCTAssertTrue(chat.contains("group: images, groupIndex: index"))
        XCTAssertTrue(chat.contains("group: fullImages, groupIndex: index"))
    }

    func testImageViewerOpensWithFreshIdentityPerTap() throws {
        // @State(initialValue:) 只在视图身份新建时种一次；fullScreenCover 必须用 item 承载
        // 每次点击的打开快照，否则第二次起 startIndex 冻结、点第 N 张仍打开第一张。
        XCTAssertNotEqual(WandImageViewerOpen(selection: WandImageGallerySelection()).id,
                          WandImageViewerOpen(selection: WandImageGallerySelection()).id)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let image = try String(contentsOf: root.appendingPathComponent("Wand/WandRemoteImage.swift"), encoding: .utf8)
        XCTAssertFalse(image.contains("fullScreenCover(isPresented: $showFullScreen)"),
                       "图片查看器不能复用 isPresented 承载，打开索引会被冻结")
        XCTAssertEqual(image.components(separatedBy: ".fullScreenCover(item: $viewerOpen)").count - 1, 3,
                       "三个缩略图入口都要用 item 承载打开快照")
    }

    func testConversationImageGalleryCrossesToolResultsAndKeepsSourceModes() {
        let turns = [
            ConversationTurn(role: "user", content: [.text(text: "[附件已上传，请查看以下文件:\n/work/a.png\n/work/doc.pdf\n]", subagent: nil)]),
            ConversationTurn(role: "assistant", content: [
                .toolUse(id: "one", name: "Read", description: nil, input: ["path": .string("/work/b.png")], subagent: nil),
                .toolResult(toolUseId: "one", text: "", isError: false, truncated: false, images: [], subagent: nil),
                .toolResult(toolUseId: "two", text: "", isError: false, truncated: false, images: ["/api/image/c", "/api/image/c", "data:image/png;base64,AA"], subagent: nil),
                .toolResult(toolUseId: "bad", text: "", isError: true, truncated: false, images: ["/api/image/failed"], subagent: nil)
            ])
        ]
        let pages = wandConversationImagePages(turns)
        XCTAssertEqual(pages, [WandImagePage(source: "/work/a.png", directSource: false),
                              WandImagePage(source: "/work/b.png", directSource: false),
                              WandImagePage(source: "/api/image/c", directSource: true),
                              WandImagePage(source: "data:image/png;base64,AA", directSource: true)])
        let selection = wandImageGallerySelection(gallery: pages, local: ["/api/image/c"], current: "/api/image/c", direct: true)
        XCTAssertEqual(selection.pages, pages)
        XCTAssertEqual(selection.startIndex, 2)
        let fallback = wandImageGallerySelection(gallery: [], local: ["/a", "/b"], current: "/b", direct: true)
        XCTAssertEqual(fallback.startIndex, 1)
        XCTAssertEqual(fallback.pages.count, 2)
    }

    func testImageViewerDoesNotLoadOffscreenPagesBeforeSwipe() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let state = MessageImageReplayState(data: try XCTUnwrap(image.pngData()))
        state.install(responses: [200], reset: true)
        defer { SelfSignedSession.resetEndpoint(state.baseURL) }
        let host = UIHostingController(rootView: WandImageViewer(baseURL: state.baseURL,
            sources: ["/lazy-one.png", "/lazy-two.png", "/lazy-three.png"],
            isPresented: .constant(true), directSource: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<30 where MessageImageReplayProtocol.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(MessageImageReplayProtocol.requestCount, 1, "打开三张图的画廊时，只允许请求当前图")
    }

    func testFullscreenImageSwipeTargetsClampAndShortDragCancels() {
        XCTAssertEqual(wandImageVisiblePages(index: 1, count: 30, drag: 0), [1])
        XCTAssertEqual(wandImageVisiblePages(index: 1, count: 30, drag: -20), [1, 2])
        XCTAssertEqual(wandImageVisiblePages(index: 1, count: 30, drag: 20), [0, 1])
        XCTAssertEqual(wandImageVisiblePages(index: 0, count: 30, drag: 20), [0])
        XCTAssertEqual(wandImageVisiblePages(index: 0, count: 0, drag: 0), [])
        XCTAssertEqual(wandImagePageTarget(index: 0, count: 3, translation: -180, predicted: -180, width: 390), 1)
        XCTAssertEqual(wandImagePageTarget(index: 1, count: 3, translation: 180, predicted: 180, width: 390), 0)
        XCTAssertEqual(wandImagePageTarget(index: 0, count: 3, translation: 180, predicted: 180, width: 390), 0)
        XCTAssertEqual(wandImagePageTarget(index: 2, count: 3, translation: -180, predicted: -180, width: 390), 2)
        XCTAssertEqual(wandImagePageTarget(index: 1, count: 3, translation: -30, predicted: -30, width: 390), 1)
        XCTAssertEqual(wandImagePageTarget(index: 1, count: 3, translation: -30, predicted: -300, width: 390), 2)
    }

    func testImageHTTPFailuresExplainDeniedMissingAndTransientStates() {
        XCTAssertEqual(wandImageHTTPFailureMessage(statusCode: 401), wandImageHTTPFailureMessage(statusCode: 403))
        XCTAssertNotEqual(wandImageHTTPFailureMessage(statusCode: 403), wandImageHTTPFailureMessage(statusCode: 404))
        XCTAssertEqual(wandImageHTTPFailureMessage(statusCode: 503), "图片暂时无法加载（503）。")
    }

    func testToolImagePartsSurviveMessageDecoding() throws {
        let block = try parityDecode(ContentBlock.self, #"{"type":"tool_result","tool_use_id":"read-image","content":[{"type":"text","text":"image read"},{"type":"image","source":{"type":"url","url":"/api/sessions/sample/tool-images/0","media_type":"image/png"}}]}"#)
        guard case .toolResult(_, let text, _, _, let images, _, _) = block else { return XCTFail("Tool image result must remain structured") }
        XCTAssertEqual(text, "image read")
        XCTAssertEqual(images, ["/api/sessions/sample/tool-images/0"])
    }

    func testLongMarkdownTableUsesMultilineCellHeight() {
        let short = "| 标题一 | 标题二 | 标题三 |\n| --- | --- | --- |\n| 短文 | `代码` | [链接](https://example.com) |"
        let long = "| 标题一 | 标题二 | 标题三 |\n| --- | --- | --- |\n| " + String(repeating: "中文长句不应在单元格尾部永久省略。", count: 12) + " | `very_long_code_identifier_to_keep_readable` | [完整链接文字](https://example.com) |"
        func height(_ text: String) -> CGFloat {
            UIHostingController(rootView: MarkdownText(text: text)).sizeThatFits(in: CGSize(width: 390, height: 3000)).height
        }
        XCTAssertGreaterThan(height(long), height(short) + 100)
    }

    func testLongMarkdownTableNativeReadability() async throws {
        guard ProcessInfo.processInfo.environment["WAND_TABLE_TOUCH_TEST"] == "1" else {
            throw XCTSkip("Requires isolated native table touch driver")
        }
        let finished = expectation(description: "native light/dark horizontal table readability checked")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MarkdownTableReadabilityFixture(finished: { finished.fulfill() }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await fulfillment(of: [finished], timeout: 90)
    }

    func testIMKeyboardViewportAnchoring() async throws {
        guard ProcessInfo.processInfo.environment["WAND_IM_KEYBOARD_TEST"] == "1" else {
            throw XCTSkip("Requires isolated simulator keyboard/scroll driver")
        }
        let fake = ConversationFake()
        func fixture(long: Bool) throws -> ConversationInstance {
            var rows: [[String: Any]] = (0..<30).map { index in
                ["messageId": "old-\(index)", "role": "assistant", "content": [["type": "text", "text": "历史段落 \(index)：上翻阅读时应保留位置，不因为键盘改变而回到最新消息。"]]]
            }
            let text = (long ? String(repeating: "这是一段长回复，展开输入时仍能阅读最新结尾。\n\n", count: 22) : "短回复。\n\n") + "锚点末尾"
            rows.append(["messageId": "latest", "role": "assistant", "content": [["type": "text", "text": text]]])
            return try JSONDecoder().decode(ConversationInstance.self, from: JSONSerialization.data(withJSONObject:
                ["id": "dm_e", "kind": "dm", "title": "键盘锚点测试", "messages": rows]))
        }
        fake.detail = try fixture(long: true)
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:1")!, token: nil)
        let store = ConversationStore(api: api, service: fake, drafts: SessionDraftStore(), defaults: defaults())
        await store.load("dm_e")
        store.composer("dm_e", target: nil).text = ""
        let finished = expectation(description: "external keyboard and manual reading checks finished")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
            HStack {
                Button("短回复") { fake.detail = try! fixture(long: false); Task { await store.load("dm_e") } }
                Button("长回复") { fake.detail = try! fixture(long: true); Task { await store.load("dm_e") } }
                Spacer()
                Button("结束锚点验收") { finished.fulfill() }
            }.frame(height: 44).padding(.horizontal)
            ConversationDetailView(id: "dm_e", store: store, onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in })
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; store.shutdown() }
        await fulfillment(of: [finished], timeout: 120)
        XCTAssertTrue(store.composer("dm_e", target: nil).text.isEmpty)
    }

    func testNativePhoneAndPadSurfacesRenderInBothAppearancesAndLargeType() async throws {
        let fake = ConversationFake()
        fake.rows = try parityDecode([ConversationInstance].self, #"[{"id":"dm_e","kind":"dm","title":"默认任务伙伴","peerEmployeeId":"e","preview":"检查客户端功能与交互","pinnedAt":"2026-10-08"},{"id":"g","kind":"group","title":"客户端对齐协作群","preview":"成员与负责人已确认"}]"#)
        fake.detail = try parityDecode(ConversationInstance.self, ###"{"id":"dm_e","kind":"dm","title":"默认任务伙伴","messages":[{"messageId":"m1","role":"user","content":[{"type":"text","text":"检查客户端功能与交互，保留草稿与历史。"}],"createdAt":"2026-10-08T10:00:00Z"},{"messageId":"m2","role":"assistant","content":[],"sessionLink":{"sessionId":"s1","title":"客户端对齐"},"sessionPreview":{"status":"done","text":"## Markdown 回复\n\n**粗体**、*斜体*、`行内代码`与[网页链接](https://example.com)。\n\n- 列表内容\n- [x] 已完成\n\n> 引用内容\n\n```swift\nlet value = 1\n```\n\n| 项目 | 状态 |\n| --- | --- |\n| 渲染 | 支持 |"}}]}"###)
        let renderAPI = WandAPI(baseURL: URL(string: "http://127.0.0.1:9721")!, token: nil)
        let store = ConversationStore(api: renderAPI, service: fake, drafts: SessionDraftStore(), defaults: defaults()); await store.refresh(); await store.load("dm_e")
        store.composer("dm_e", target: nil).text = ""
        let frames: [(String, CGSize, ColorScheme, ContentSizeCategory)] = [
            ("phone-light", CGSize(width: 390, height: 844), .light, .large),
            ("phone-dark", CGSize(width: 390, height: 844), .dark, .large),
            ("pad-light-large", CGSize(width: 1024, height: 1366), .light, .accessibilityExtraExtraLarge),
            ("pad-dark", CGSize(width: 1024, height: 1366), .dark, .large),
        ]
        for (name, size, scheme, type) in frames {
            let list = ConversationListView(store: store, onSelect: { _ in }, onEmployee: { _ in }, onSettings: {}, onSwitchServer: {})
                .safeAreaInset(edge: .bottom) { HomeMenuPill(mode: .im, onMode: { _ in }) }
            let chat = ConversationDetailView(id: "dm_e", store: store, onOpenSession: { _ in }, onOpenConversation: { _ in }, onEmployee: { _ in })
            let content = Group {
                if size.width > 600 { NavigationSplitView { list } detail: { chat } }
                else {
                    NavigationStack(path: .constant(["chat"])) {
                        Text("对话列表").navigationDestination(for: String.self) { _ in chat }
                    }
                }
            }.environment(\.colorScheme, scheme).environment(\.sizeCategory, type).wandPreferredAppearance()
            let host = UIHostingController(rootView: content)
            host.traitOverrides.horizontalSizeClass = size.width > 600 ? .regular : .compact
            host.traitOverrides.userInterfaceStyle = scheme == .dark ? .dark : .light
            host.traitOverrides.preferredContentSizeCategory = type == .accessibilityExtraExtraLarge ? .accessibilityExtraExtraLarge : .large
            let window = UIWindow(frame: CGRect(origin: .zero, size: size)); window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 180_000_000)
            if size.width < 600 {
                func visibleBars(_ view: UIView) -> [UINavigationBar] {
                    guard !view.isHidden, view.alpha > 0 else { return [] }
                    return (view as? UINavigationBar).map { [$0] } ?? view.subviews.flatMap(visibleBars)
                }
                XCTAssertTrue(visibleBars(host.view).isEmpty, "Chat must not show a second system menu bar")
            }
            let image = UIGraphicsImageRenderer(size: size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            XCTAssertEqual(image.size, size); XCTAssertNotNil(image.pngData())
            let attachment = XCTAttachment(image: image); attachment.name = "ios-current-parity-" + name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
        store.shutdown()
    }
    func testDispatchLeaderMovesWhenRemovedAndSelectionCannotExceedEight() throws {
        let fake = DispatchFake(); var selection = TeamDispatchSelection(members: fake.plan.members, leaderID: "e1")
        selection.toggle(fake.plan.members[0]); XCTAssertEqual(selection.leaderID, "e2"); XCTAssertFalse(selection.valid)
        selection.toggle(fake.plan.members[0]); XCTAssertTrue(selection.valid)
        XCTAssertEqual(selection.picks.filter { $0["isLeader"] as? Bool == true }.count, 1)
    }
}

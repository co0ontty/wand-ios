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
    var detail = try! parityDecode(ConversationInstance.self, #"{"id":"dm_e","kind":"dm","title":"员工"}"#)
    var posts: [(String, [String: Any])] = []
    var pending: [String] = []
    var receipt = try! parityReceipt()
    var failure: Error?
    var postContinuation: CheckedContinuation<ConversationReceipt, Error>?
    var suspendPost = false
    var suspendLoads = false
    var loads: [CheckedContinuation<ConversationInstance, Error>] = []
    func listContactEmployees() async throws -> [SiliconEmployee] { [] }
    func listContactTeams() async throws -> [ContactTeam] { [] }
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
    func updateConversationListState(_ id: String, patch: [String: Bool]) async throws -> ConversationInstance { detail }
    func deleteConversation(_ id: String) async throws {}
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
    var response = try! parityDecode(PiResourcesResponse.self, #"{"settings":{"resources":{"skills":[],"mcpServers":[]}},"resourceCatalog":{"supported":true,"skills":[],"mcpServers":[]},"controls":{"codemodeOverride":true,"codemodeOnly":false},"skillLocksAvailable":true,"autoResourcesAvailable":true}"#)
    var failure: Error?
    var bodies: [[String: Any]] = []
    var ack: PiResourcesResponse.Settings?
    func piResources(_ id: String) async throws -> PiResourcesResponse { response }
    func savePiResources(_ id: String, body: [String: Any]) async throws -> PiResourcesResponse.Settings {
        bodies.append(body); if let failure { throw failure }; return ack ?? response.settings
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
        for mode in [HomeListMode.im, .contacts, .sessions, .board] { XCTAssertEqual(HomeListMode.fromStorage(mode.rawValue), mode) }
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
    func testGroupOperationRetainsAcceptedStartupFailureRatherThanRepeating() async throws {
        let operation = ConversationOperation(), receipt = try parityReceipt(extra: ",\"startup\":\"failed\",\"error\":\"engine unavailable\"")
        var calls = 0
        operation.submit({ calls += 1; return receipt }, accepted: { _ in })
        await settle { operation.receipt != nil }
        operation.submit({ calls += 1; return receipt }, accepted: { _ in })
        XCTAssertEqual(calls, 1); XCTAssertFalse(operation.canSubmit); XCTAssertEqual(operation.phase, .sent)
    }
    func testPrivateAndDissolvedListTiersUseActualInstanceState() throws {
        let dm = try parityDecode(ConversationInstance.self, #"{"id":"dm_e","kind":"dm"}"#)
        let group = try parityDecode(ConversationInstance.self, #"{"id":"g","kind":"group","dissolvedAt":"now"}"#)
        XCTAssertTrue(ConversationListTier.dm.contains(dm)); XCTAssertFalse(ConversationListTier.all.contains(group)); XCTAssertTrue(ConversationListTier.dissolved.contains(group))
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
        XCTAssertEqual(request.path, "/api/structured-sessions"); XCTAssertEqual(request.body["provider"], .string("pi")); XCTAssertEqual(request.body["engine"], .string("sdk"))
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
        XCTAssertFalse(try source("NativeRootView.swift").contains(".toolbar(.visible, for: .navigationBar)"), "The navigation parent must not override chat's floating chrome")
        XCTAssertTrue(try source("SessionDestinationView.swift").contains(".toolbar(showsNavigationChrome ? .visible : .automatic, for: .navigationBar)"))
        XCTAssertTrue(try source("WorkspaceTaskView.swift").contains(".toolbar(.visible, for: .navigationBar)"))
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

    func testIdleSpeechDisposalDoesNotAcquireMicrophone() async {
        var local: SpeechRecognizerService? = SpeechRecognizerService()
        local?.stop(cancelled: true)
        local = nil
        var server: ServerSpeechRecorder? = ServerSpeechRecorder()
        server?.cancel()
        server = nil
        let hardware = WandSpeechAudioHardware()
        let drained = expectation(description: "idle audio cleanup drained without initializing input hardware")
        WandSpeechAudio.queue.async {
            var finalized = false
            hardware.stop { finalized = true }
            XCTAssertTrue(finalized)
            XCTAssertFalse(hardware.hasInputNode)
            XCTAssertFalse(hardware.sessionActive)
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 3)
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
        let host = UIHostingController(rootView: WandToolImageThumbnail(baseURL: parityURL, source: "/api/sessions/sample/tool-images/image.png"))
        let size = host.sizeThatFits(in: CGSize(width: 240, height: 200))
        XCTAssertGreaterThanOrEqual(size.width, 96)
        XCTAssertGreaterThanOrEqual(size.height, 64)
        XCTAssertLessThanOrEqual(size.height, 200)
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
                .safeAreaInset(edge: .bottom) { HomeMenuPill(mode: .im, onMode: { _ in }, onContacts: {}) }
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

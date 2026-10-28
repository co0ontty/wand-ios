import Combine
import SwiftUI
import XCTest
@testable import Wand

private final class ChatLoadingURLProtocol: URLProtocol {
    static var respond: ((URLRequest) -> (String, TimeInterval))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (body, delay) = Self.respond?(request) ?? ("{}", 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor final class ChatLoadingTests: XCTestCase {

    func testSharedChatWireIsolatesSessionsAndRetainsOtherLeases() throws {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let a = WandSocket.sharedChat(api: api), b = WandSocket.sharedChat(api: api)
        XCTAssertTrue(a.sharedConnection === b.sharedConnection)
        var receivedA: [Int] = [], receivedB: [Int] = []
        a.onEvent = { receivedA.append($0.seq ?? 0) }; b.onEvent = { receivedB.append($0.seq ?? 0) }
        a.subscribe(sessionId: "a", ptyAck: false); b.subscribe(sessionId: "b", ptyAck: false)
        a.connect(); b.connect()
        defer { a.close(); b.close() }
        func frame(_ id: String, _ type: String, _ seq: Int) throws {
            a.sharedConnection.handle(try JSONSerialization.data(withJSONObject:
                ["type": type, "sessionId": id, "seq": seq, "data": ["id": id, "messages": []]]))
        }
        XCTAssertEqual(a.activeChatLeases, 2)
        try frame("a", "init", 1); try frame("b", "init", 1)
        try frame("a", "output", 2); try frame("b", "output", 2)
        XCTAssertEqual(receivedA, [1, 2]); XCTAssertEqual(receivedB, [1, 2])
        a.close()
        XCTAssertEqual(b.activeChatLeases, 1)
        try frame("a", "output", 3); try frame("b", "output", 3)
        XCTAssertEqual(receivedA, [1, 2]); XCTAssertEqual(receivedB, [1, 2, 3])
        b.close(); XCTAssertEqual(a.activeChatLeases, 0)
        // Re-entering the same store starts a fresh sequence boundary on the same pool.
        a.connect(); try frame("a", "init", 1); try frame("a", "output", 2)
        XCTAssertEqual(receivedA, [1, 2, 1, 2])
        let otherAPI = WandAPI(baseURL: api.baseURL, token: "different-test-identity")
        let other = WandSocket.sharedChat(api: otherAPI)
        XCTAssertFalse(other.sharedConnection === a.sharedConnection)
    }


    func testSyncBufferMergesOldEditsDeletionAndOlderPages() async throws {
        let buffer = ConversationSyncBuffer()
        let first = try await buffer.read("c") { suffix in
            XCTAssertEqual(suffix, "/sync")
            return Data(#"{"id":"c","reset":true,"detail":{"id":"c","kind":"dm"},"messageOrder":["b"],"messages":[{"messageId":"b","content":[]}],"history":{"revision":"one","from":"anchor","hasEarlier":true,"total":2}}"#.utf8)
        }
        XCTAssertFalse(first.isEmpty)
        let older = try await buffer.read("c", older: true) { suffix in
            XCTAssertTrue(suffix.contains("since=one")); XCTAssertTrue(suffix.contains("older=1"))
            return Data(#"{"id":"c","messageOrder":["a","b"],"messages":[{"messageId":"a","content":[]}],"history":{"revision":"two","from":"start","hasEarlier":false,"total":2}}"#.utf8)
        }
        let page = try XCTUnwrap(try JSONSerialization.jsonObject(with: older) as? [String: Any])
        XCTAssertEqual((page["messages"] as? [[String: Any]])?.count, 2)
        let changed = try await buffer.read("c") { _ in
            Data(#"{"id":"c","messageOrder":["a"],"messages":[{"messageId":"a","content":[{"type":"text","text":"edited"}]}],"history":{"revision":"three","from":"start","hasEarlier":false,"total":1}}"#.utf8)
        }
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: changed) as? [String: Any])
        XCTAssertEqual((result["messages"] as? [[String: Any]])?.count, 1)
        let same = try await buffer.read("c") { _ in
            Data(#"{"id":"c","unchanged":true,"history":{"revision":"three","from":"start","hasEarlier":false,"total":1}}"#.utf8)
        }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: same) as? NSDictionary, result as NSDictionary)
    }

    private func api() -> WandAPI {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9/loading-" + UUID().uuidString)!, token: nil)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatLoadingURLProtocol.self]
        api.endpointSession.session = URLSession(configuration: config, delegate: api.endpointSession, delegateQueue: nil)
        return api
    }

    func testCompactFirstPageAndFullPendingToolDetailUseDifferentProjection() async throws {
        let api = api()
        defer { ChatLoadingURLProtocol.respond = nil; SelfSignedSession.resetEndpoint(api.baseURL) }
        ChatLoadingURLProtocol.respond = { request in
            if request.url!.path.contains("/tool-content/") {
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Wand-Tool-Projection"))
                return (#"{"tool_use_id":"tool","input":{"command":"pwd"},"resultAvailable":false}"#, 0)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Wand-Tool-Projection"), "compact")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "blockBudget" }?.value, "12")
            XCTAssertEqual(query.first { $0.name == "byteBudget" }?.value, "98304")
            XCTAssertEqual(query.first { $0.name == "output" }?.value, "omit")
            return (#"{"id":"session","sessionKind":"structured","messages":[]}"#, 0)
        }
        _ = try await api.getSession(id: "session")
        let detail = try await api.fetchToolContent(id: "session", toolUseId: "tool")
        XCTAssertEqual(detail.input["command"]?.stringValue, "pwd")
        XCTAssertFalse(detail.resultAvailable, "Pending tool parameters must be available before its result")
        let socket = WandSocket(baseURL: api.baseURL)
        socket.blockBudget = WandAPI.chatBlockWindow; socket.byteBudget = WandAPI.chatByteWindow
        socket.subscribe(sessionId: "session")
        let payload = try XCTUnwrap(socket.subscriptionPayload())
        XCTAssertEqual(payload["compactTools"] as? Bool, true)
        XCTAssertEqual(payload["omitStructuredOutput"] as? Bool, true)
        XCTAssertEqual(payload["byteBudget"] as? Int, 98304)
    }

    func testNavigationSnapshotPaintsImmediatelyWithoutAnotherDetailRead() async throws {
        let api = api()
        let auxiliary = expectation(description: "auxiliary request started")
        let duplicate = expectation(description: "no duplicate session read"); duplicate.isInverted = true
        ChatLoadingURLProtocol.respond = { request in
            if request.url!.path.hasSuffix("/api/sessions/session") { duplicate.fulfill() }
            if request.url!.path.hasSuffix("/api/models") { auxiliary.fulfill() }
            return ("{}", 0)
        }
        let seed = try JSONDecoder().decode(SessionSnapshot.self,
            from: Data(#"{"id":"session","sessionKind":"structured","status":"idle","title":"seed","messages":[]}"#.utf8))
        let store = ChatStore(sessionId: "session", api: api, drafts: SessionDraftStore(), initialSnapshot: seed)
        defer { store.shutdown(); store.composerDraft.retire(); ChatLoadingURLProtocol.respond = nil; SelfSignedSession.resetEndpoint(api.baseURL) }
        store.start()
        XCTAssertFalse(store.loading)
        XCTAssertEqual(store.snapshot?.title, "seed")
        await fulfillment(of: [auxiliary, duplicate], timeout: 0.3)
    }

    func testLateRestCannotReplaceNewerRealtimeSnapshot() async throws {
        let api = api()
        let rest = expectation(description: "REST started")
        let auxiliary = expectation(description: "REST settled")
        ChatLoadingURLProtocol.respond = { request in
            if request.url!.path.hasSuffix("/api/sessions/session") {
                rest.fulfill()
                return (#"{"id":"session","sessionKind":"structured","status":"idle","title":"old","messages":[]}"#, 0.15)
            }
            if request.url!.path.hasSuffix("/api/models") { auxiliary.fulfill() }
            return ("{}", 0)
        }
        let store = ChatStore(sessionId: "session", api: api, drafts: SessionDraftStore())
        defer { store.shutdown(); store.composerDraft.retire(); ChatLoadingURLProtocol.respond = nil; SelfSignedSession.resetEndpoint(api.baseURL) }
        store.start()
        await fulfillment(of: [rest], timeout: 2)
        let event = try JSONDecoder().decode(WsIncoming.self,
            from: Data(#"{"type":"init","sessionId":"session","data":{"id":"session","sessionKind":"structured","status":"running","title":"new","messages":[]}}"#.utf8))
        store.handle(event)
        await fulfillment(of: [auxiliary], timeout: 2)
        XCTAssertEqual(store.snapshot?.title, "new")
        XCTAssertEqual(store.status, "running")
        XCTAssertFalse(store.loading)
    }
}

@MainActor final class ChatComposerCatTests: XCTestCase {
    func testSocketDecodeIsAsynchronousAndDeliversFramesInOrderOnMainThread() async throws {
        let socket = WandSocket(baseURL: URL(string: "http://127.0.0.1:9")!)
        let completed = expectation(description: "serial decoded frames")
        completed.expectedFulfillmentCount = 5
        var observed: [String] = []
        let types = ["init", "output", "status", "ended"]
        for (index, type) in types.enumerated() {
            let payload: [String: Any] = ["type": type, "seq": index,
                "data": ["lastMessage": ["role": "assistant", "content": [["type": "text", "text": String(repeating: "synthetic ", count: index == 1 ? 200_000 : 1)]]]]]
            let data = try JSONSerialization.data(withJSONObject: payload)
            socket.decodeReceived(.success(.data(data))) { frame in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(frame?.incoming.seq, index)
                observed.append(frame?.incoming.type ?? "invalid")
                completed.fulfill()
            }
        }
        socket.decodeReceived(.success(.string("invalid JSON"))) { frame in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(frame)
            observed.append("invalid")
            completed.fulfill()
        }
        XCTAssertTrue(observed.isEmpty, "Do not synchronously decode/deliver a frame in the UI transaction")
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(observed, types + ["invalid"])
    }

    func testMessageProjectionIgnoresComposerUpdatesButInvalidatesForStreamingAndCompletion() {
        let cache = ChatProjectionCache<Int>()
        var builds = 0
        func read(_ revision: Int, _ responding: Bool) -> Int {
            cache.value(revision: revision, responding: responding) { builds += 1; return builds }
        }
        XCTAssertEqual(read(1, true), 1)
        for _ in 0..<100 { XCTAssertEqual(read(1, true), 1) }
        XCTAssertEqual(read(2, true), 2)
        XCTAssertEqual(read(2, false), 3)
        XCTAssertEqual(read(2, false), 3)
        // A newly committed message must not reuse an earlier turn's projection.
        XCTAssertEqual(read(3, false), 4)
    }

    func testScrollBurstWaitsForPublishedMessagesToCommitAndCancelsOnExit() async throws {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let store = ChatStore(sessionId: UUID().uuidString, api: api)
        let scheduler = ChatScrollScheduler()
        var scrolls = 0
        var sawPreCommitState = false
        let subscription = store.$messages.dropFirst().sink { incoming in
            // @Published publishes in willSet. Synchronous scrollTo here observes
            // old rows and can re-enter LazyVStack while they are being replaced.
            sawPreCommitState = sawPreCommitState || store.messages.count != incoming.count
            scheduler.request {
                scrolls += 1
                XCTAssertEqual(store.messages.count, 100)
                XCTAssertEqual(store.messageRevision, 100)
            }
        }
        defer { subscription.cancel() }
        for index in 0..<100 {
            store.messages.append(ConversationTurn(role: "user", content: [.text(text: "test-\(index)", subagent: nil)]))
        }
        XCTAssertTrue(sawPreCommitState)
        XCTAssertEqual(scrolls, 0, "Never force layout synchronously during publication")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(scrolls, 1, "A burst requires only one post-commit scroll, not two per event")
        scheduler.request { XCTFail("Manual history browsing/page exit must cancel pending scrolling") }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(scrolls, 1)
    }

    func testFirstReplyOnlyScrollsAfterContentOutgrowsViewport() async throws {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let id = UUID().uuidString
        let initial = try JSONDecoder().decode(SessionSnapshot.self, from: Data("{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"running\",\"structuredState\":{\"inFlight\":true},\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"你好\"}]}]}".utf8))
        let store = ChatStore(sessionId: id, api: api, drafts: SessionDraftStore(), initialSnapshot: initial)
        let host = UIHostingController(rootView: ChatView(sessionId: id, api: api, sharedStore: store))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; store.shutdown() }
        for _ in 0..<100 {
            if composerAccessoryScrollViews(host.view).contains(where: { $0.bounds.height > 100 }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let scroll = try XCTUnwrap(composerAccessoryScrollViews(host.view).max { $0.bounds.height < $1.bounds.height })
        let frames = ChatScrollFrameProbe(scroll: scroll)
        frames.start()
        defer { frames.stop() }
        var shortSamples = 0
        var overflowingSamples = 0
        for chunk in 1...40 {
            let payload: [String: Any] = ["type": "output", "data": ["incremental": true, "messageCount": 2,
                "lastMessage": ["role": "assistant", "content": [["type": "text", "text": Array(repeating: "首条回复逐行增长，保持阅读位置稳定。", count: chunk).joined(separator: "\n")]]], "isResponding": true]]
            store.handle(try JSONDecoder().decode(WsIncoming.self, from: JSONSerialization.data(withJSONObject: payload)))
            try await Task.sleep(for: .milliseconds(60))
            host.view.layoutIfNeeded()
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            print("FIRST-REPLY chunk=\(chunk) content=\(scroll.contentSize.height) viewport=\(scroll.bounds.height) offset=\(scroll.contentOffset.y) bottom=\(bottom)")
            if bottom == top {
                shortSamples += 1
                XCTAssertEqual(scroll.contentOffset.y, top, accuracy: 1, "Short first replies stay top-aligned; do not scroll into negative blank space")
            } else {
                overflowingSamples += 1
                XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 8, "Overflowing streaming replies must still follow the bottom (including 6pt tail padding)")
            }
        }
        XCTAssertGreaterThan(shortSamples, 2)
        XCTAssertGreaterThan(overflowingSamples, 2)
        print("FIRST-REPLY frames=\(frames.samples.count) minOffset=\(frames.samples.map(\.offset).min() ?? 0)")
        for frame in frames.samples where frame.content < frame.viewport {
            XCTAssertEqual(frame.offset, 0, accuracy: 1, "Short content must not bounce between bottom and top on display frames")
        }
        let reversals = zip(frames.samples, frames.samples.dropFirst()).filter { before, after in
            after.content >= before.content && abs(after.viewport - before.viewport) < 1 && after.offset < before.offset - 2
        }
        print("FIRST-REPLY reversals=\(reversals)")
        XCTAssertTrue(reversals.isEmpty, "Growing reply must not repeatedly scroll backwards")
    }

    func testShortRunningConversationKeepsTopStableDuringActivityUpdates() async throws {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let id = UUID().uuidString
        let initial = try JSONDecoder().decode(SessionSnapshot.self, from: Data("{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"running\",\"structuredState\":{\"inFlight\":true},\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"请继续\"}]}]}".utf8))
        let store = ChatStore(sessionId: id, api: api, drafts: SessionDraftStore(), initialSnapshot: initial)
        let host = UIHostingController(rootView: ChatView(sessionId: id, api: api, sharedStore: store))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; store.shutdown() }
        try await Task.sleep(for: .milliseconds(500))
        let scroll = try XCTUnwrap(composerAccessoryScrollViews(host.view).filter { $0.bounds.height > 100 }.max { $0.bounds.height < $1.bounds.height })
        let frames = ChatScrollFrameProbe(scroll: scroll)
        frames.start()
        defer { frames.stop() }
        for chunk in 1...40 {
            let content: [[String: Any]] = [
                ["type": "text", "text": "我先检查现有实现。"],
                ["type": "tool_use", "id": "read-1", "name": "read", "input": ["path": "/tmp/example"]],
                ["type": "tool_result", "tool_use_id": "read-1", "content": "结果 \(chunk)"],
                ["type": "text", "text": "正在继续处理。"]
            ]
            let payload: [String: Any] = ["type": "output", "data": ["incremental": true, "messageCount": 2,
                "lastMessage": ["role": "assistant", "content": content], "isResponding": true]]
            store.handle(try JSONDecoder().decode(WsIncoming.self, from: JSONSerialization.data(withJSONObject: payload)))
            try await Task.sleep(for: .milliseconds(40))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.isResponding)
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertGreaterThan(frames.samples.count, 20)
        XCTAssertLessThan(scroll.contentSize.height, scroll.bounds.height)
        for frame in frames.samples where frame.content < frame.viewport {
            XCTAssertEqual(frame.offset, 0, accuracy: 1, "Short running conversation must not jump on any display frame")
        }
    }

    func testRunningConversationStreamingKeepsTailStable() async throws {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let id = UUID().uuidString
        let initial = try JSONDecoder().decode(SessionSnapshot.self, from: Data("{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"running\",\"structuredState\":{\"inFlight\":true}}".utf8))
        let store = ChatStore(sessionId: id, api: api, drafts: SessionDraftStore(), initialSnapshot: initial)
        store.messages = (0..<15).flatMap { index in
            [ConversationTurn(role: "user", content: [.text(text: "问题 \(index)", subagent: nil)]),
             ConversationTurn(role: "assistant", content: [.text(text: String(repeating: "历史回复内容。", count: 30), subagent: nil)])]
        }
        store.messages.append(ConversationTurn(role: "user", content: [.text(text: "继续处理", subagent: nil)]))
        let host = UIHostingController(rootView: ChatView(sessionId: id, api: api, sharedStore: store))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; store.shutdown() }
        try await Task.sleep(for: .milliseconds(500))
        let scroll = try XCTUnwrap(composerAccessoryScrollViews(host.view).filter { $0.bounds.height > 100 }.max { $0.bounds.height < $1.bounds.height }, "Expected the conversation list, not a small nested scroll view")
        let initialContentHeight = scroll.contentSize.height
        let frames = ChatScrollFrameProbe(scroll: scroll)
        frames.start()
        defer { frames.stop() }
        let count = store.messages.count + 1
        for chunk in 1...40 {
            var content: [[String: Any]] = [["type": "thinking", "thinking": "分析任务"]]
            for tool in 0..<(chunk / 5) {
                content.append(["type": "tool_use", "id": "tool-\(tool)", "name": "read", "input": ["path": "/tmp/file-\(tool)"]])
                content.append(["type": "tool_result", "tool_use_id": "tool-\(tool)", "content": "读取完成"])
            }
            content.append(["type": "text", "text": Array(repeating: "正在运行的回复逐行增长。", count: chunk).joined(separator: "\n")])
            let payload: [String: Any] = ["type": "output", "data": ["incremental": true, "messageCount": count,
                "lastMessage": ["role": "assistant", "content": content], "isResponding": true]]
            store.handle(try JSONDecoder().decode(WsIncoming.self, from: JSONSerialization.data(withJSONObject: payload)))
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(store.isResponding)
        XCTAssertEqual(store.messages.count, count)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertGreaterThan(scroll.contentSize.height, initialContentHeight + 100, "The selected list must grow with the streamed reply")
        let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 14, "Running conversation should keep following the tail")
        let reversals = zip(frames.samples, frames.samples.dropFirst()).filter { before, after in
            after.content >= before.content && abs(after.viewport - before.viewport) < 1 && after.offset < before.offset - 2
        }
        print("RUNNING-REPLY frames=\(frames.samples.count) reversals=\(reversals)")
        XCTAssertTrue(reversals.isEmpty, "Growing reply must not jump backwards while following the tail")
    }

    func testLongChatSendAndStreamingUpdatesKeepMainActorResponsive() async throws {
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let transport = FreezeReceiptTransport()
        let id = UUID().uuidString
        let store = ChatStore(sessionId: id, api: api, inputTransport: transport, drafts: SessionDraftStore())
        let initial = try JSONDecoder().decode(WsIncoming.self, from: Data("{\"type\":\"init\",\"data\":{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"running\",\"structuredState\":{\"inFlight\":false}}}".utf8))
        store.handle(initial)
        store.messages = (0..<40).flatMap { index in
            [ConversationTurn(role: "user", content: [.text(text: "request-\(index)", subagent: nil)]),
             ConversationTurn(role: "assistant", content: (0..<12).map { block in
                 .text(text: "reply-\(index)-\(block)\n\n" + String(repeating: "synthetic history ", count: 30), subagent: nil)
             })]
        }
        let host = UIHostingController(rootView: ChatView(sessionId: id, api: api, sharedStore: store))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; store.composerDraft.retire(); store.shutdown() }
        try await Task.sleep(for: .milliseconds(200))
        for round in 0..<3 {
            let start = ContinuousClock.now
            store.isResponding = false
            store.composerDraft.text = "send-\(round)"
            let submission = store.composerDraft.submission()
            XCTAssertTrue(store.send(text: submission.prompt, onAccepted: { store.composerDraft.accepted(submission) }))
            store.composerDraft.submitted(submission)
            // Let the ack and the same view refreshes used by a real send settle.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(store.inputSending)
            for chunk in 0..<25 {
                let data: [String: Any] = ["type": "output", "data": ["incremental": true, "messageCount": store.messages.count + 1,
                    "lastMessage": ["role": "assistant", "content": [["type": "text", "text": String(repeating: "stream ", count: chunk + 1)]]], "isResponding": true]]
                store.handle(try JSONDecoder().decode(WsIncoming.self, from: JSONSerialization.data(withJSONObject: data)))
                store.composerDraft.text = "next draft \(chunk)"
            }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertLessThan(start.duration(to: .now), .seconds(5), "Send/stream burst must yield the main actor without reopening the app")
            XCTAssertEqual(store.composerDraft.text, "next draft 24")
        }
        XCTAssertEqual(transport.inputs.count, 3)
    }

    func testNamedTopCompanionReservesScaledIdentityWithoutStateOrNameHeightJumps() {
        for compact in [false, true] {
            for width: CGFloat in [320, 440, 768] {
                for type: DynamicTypeSize in [.large, .accessibility3] {
                    var heights: [CGFloat] = []
                    for title in ["小试", "相同头像但身份不同的很长员工名字 · 项目交付负责人"] {
                        let root = TopChatCompanion(title: title, status: "等待你的确认") { size in Color.clear.frame(width: size, height: size) }
                            .environment(\.verticalSizeClass, compact ? .compact : .regular).environment(\.dynamicTypeSize, type)
                        heights.append(UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width, height: 800)).height)
                    }
                    XCTAssertEqual(heights[0], heights[1], accuracy: 1)
                    XCTAssertGreaterThanOrEqual(heights[0], ChatTopLayout.controlsClearance)
                    XCTAssertLessThan(heights[0], 260)
                    if type == .large { XCTAssertEqual(heights[0], compact ? 56 : 114, accuracy: 1) }
                }
            }
        }
    }

    func testNativeTopCatReservationKeepsViewportStableAcrossSidesAndTextSizes() {
        for width: CGFloat in [320, 402, 768] {
            for type: DynamicTypeSize in [.large, .accessibility3] {
                for side: CatComposerSide in [.left, .right] {
                    let root = TopChatCompanion(side: side) { size in Color.clear.frame(width: size, height: size) }
                        .environment(\.dynamicTypeSize, type).environment(\.verticalSizeClass, .regular)
                    let height = UIHostingController(rootView: root).sizeThatFits(in: CGSize(width: width, height: 800)).height
                    XCTAssertEqual(height, 100, accuracy: 1, "顶部无文字的伙伴保留区不因字号或侧别移动")
                }
            }
        }
    }
    func testReadingBoundaryClearsRealControlsAndCompanionInBothSizeClasses() {
        for compact in [false, true] {
            let sizeClass: UserInterfaceSizeClass = compact ? .compact : .regular
            let clearance = ChatTopLayout.clearance(compact: compact)
            XCTAssertEqual(clearance, compact ? 56 : 100)
            XCTAssertGreaterThanOrEqual(clearance, ChatTopLayout.controlsClearance)
            for width: CGFloat in [320, 402, 768] {
                for type: DynamicTypeSize in [.large, .accessibility3] {
                    let controls = FloatingChatControls(onBack: {}) {
                        FloatingChatIcon(symbol: "ellipsis")
                    }.padding(.top, compact ? 0 : 18).environment(\.dynamicTypeSize, type)
                    let controlHeight = UIHostingController(rootView: controls).sizeThatFits(in: CGSize(width: width, height: 800)).height
                    XCTAssertLessThanOrEqual(controlHeight, clearance)
                    let companion = TopChatCompanion { size in Color.clear.frame(width: size, height: size) }
                        .environment(\.verticalSizeClass, sizeClass).environment(\.dynamicTypeSize, type)
                    XCTAssertEqual(UIHostingController(rootView: companion).sizeThatFits(in: CGSize(width: width, height: 800)).height, clearance, accuracy: 1)
                }
            }
        }
    }
    func testFailedDraftStaysExpandedAfterTransientSendFeedbackExpires() async throws {
        let draft = ComposerDraftState(sessionId: UUID().uuidString, api: WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil))
        draft.beginSending(); draft.finishSending(accepted: false, message: "明确未接受")
        // The feedback task starts asynchronously. A fixed dwell + 150ms from the
        // caller races its scheduling under load; wait for the actual phase receipt.
        for _ in 0..<100 {
            if draft.sendPhase == .idle { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("INPUT-FEEDBACK settled phase=\(draft.sendPhase)")
        XCTAssertEqual(draft.sendPhase, .idle)
        XCTAssertTrue(draft.submissionFailed)
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false,
            failed: draft.submissionFailed, unconfirmed: false))
        draft.beginSending(); XCTAssertFalse(draft.submissionFailed)
        draft.finishSending(accepted: true, message: nil); XCTAssertFalse(draft.submissionFailed)
    }
    func testAcknowledgedComposerOnlyRestsWithNoEditingOrUncertainInput() {
        func rests(_ focused: Bool = false, _ draft: Bool = false, _ attachments: Bool = false,
                   _ composing: Bool = false, _ phase: ComposerSendPhase = .idle, _ uncertain: Bool = false) -> Bool {
            composerUsesRestingSurface(acknowledged: true, focused: focused, hasDraft: draft,
                hasAttachments: attachments, composing: composing, phase: phase, unconfirmed: uncertain)
        }
        XCTAssertTrue(rests())
        XCTAssertTrue(rests(false, false, false, false, .sent))
        XCTAssertFalse(rests(true)); XCTAssertFalse(rests(false, true))
        XCTAssertFalse(rests(false, false, true)); XCTAssertFalse(rests(false, false, false, true))
        XCTAssertFalse(rests(false, false, false, false, .failed))
        XCTAssertFalse(rests(false, false, false, false, .sending))
        XCTAssertFalse(rests(false, false, false, false, .idle, true))
        XCTAssertFalse(composerUsesRestingSurface(acknowledged: false, focused: false, hasDraft: false,
            hasAttachments: false, composing: false, phase: .idle, unconfirmed: false))
    }
    func testLongDraftExpansionAffordance() {
        XCTAssertEqual(composerMaximumInputHeight(compact: true, keyboardVisible: true), 44)
        XCTAssertEqual(composerMaximumInputHeight(compact: true, keyboardVisible: false), 88)
        XCTAssertEqual(composerMaximumInputHeight(compact: false, keyboardVisible: true), 96)
        XCTAssertEqual(composerMaximumInputHeight(compact: false, keyboardVisible: false), 112)
    }
    func testCatPressDistinguishesTapFromDrag() {
        var press = CatInputPressState()
        XCTAssertEqual(press.end(), .tap)
        press.move(x: 0, y: 20)
        XCTAssertEqual(press.end(), .none)
        press.move(x: 75, y: 3)
        XCTAssertTrue(press.dragging)
        XCTAssertEqual(press.end(), .drag(75))
        XCTAssertEqual(press.end(), .tap)
    }
    func testCatVisibilityNeverHidesFailureOrUnknownDelivery() {
        XCTAssertFalse(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: false, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: true, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: false, failed: false, unconfirmed: true))
        XCTAssertTrue(catComposerExpanded(editing: true, focused: false, keyboard: false, failed: false, unconfirmed: false))
        XCTAssertTrue(catComposerExpanded(editing: false, focused: false, keyboard: true, failed: false, unconfirmed: false))
    }
    func testCatSideIsSharedLocallyAcrossChatsAndReloads() throws {
        let name = "wand.cat-side.test.\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { first.removePersistentDomain(forName: name) }
        XCTAssertEqual(CatComposerSide.load(first), .left)
        CatComposerSide.left.dropped(translation: 80).save(first)
        XCTAssertEqual(CatComposerSide.load(try XCTUnwrap(UserDefaults(suiteName: name))), .right)
        XCTAssertEqual(CatComposerSide.right.dropped(translation: -30), .right)
        XCTAssertEqual(CatComposerSide.right.dropped(translation: -80), .left)
        first.set("invalid", forKey: CatComposerSide.preferenceKey)
        XCTAssertEqual(CatComposerSide.load(first), .left)
    }
    func testCapsuleThirdActionOnlyUsesTextAndThinkingEndsAtStreaming() {
        XCTAssertFalse(catCapsuleShowsThirdAction(text: " \n "))
        XCTAssertTrue(catCapsuleShowsThirdAction(text: "待发送"))
        var messages = [ConversationTurn(role: "user", content: [.text(text: "test", subagent: nil)]),
                        ConversationTurn(role: "assistant", content: [.thinking(thinking: "thinking", subagent: nil)])]
        XCTAssertTrue(avatarIsThinking(messages: messages, executing: true))
        messages[1] = ConversationTurn(role: "assistant", content: messages[1].content + [.text(text: "reply", subagent: nil)])
        XCTAssertFalse(avatarIsThinking(messages: messages, executing: true))
        messages.append(ConversationTurn(role: "user", content: [.text(text: "next", subagent: nil)]))
        XCTAssertFalse(avatarIsThinking(messages: messages, executing: true))
        XCTAssertFalse(avatarIsThinking(messages: messages, executing: false))
    }
    /// 无头像的会话身份栏：高度只由两行文字决定，与标题长度无关；随 Dynamic Type 增长但不得超过
    /// 原头像版占掉的高度；读屏拿到「标题，小字，状态」的完整组合。
    func testSessionIdentityBarKeepsStableHeightAndFullReadback() {
        for compact in [false, true] {
            for width: CGFloat in [320, 402, 768] {
                for type: DynamicTypeSize in [.large, .accessibility3] {
                    var heights: [CGFloat] = []
                    for title in ["修复图片显示", String(repeating: "长", count: 40)] {
                        let bar = ChatTopIdentityBar(title: title, subtitle: "赛博虎妞 · wand", attention: .running, statusText: "正在读文件")
                            .environment(\.verticalSizeClass, compact ? .compact : .regular).environment(\.dynamicTypeSize, type)
                        heights.append(UIHostingController(rootView: bar).sizeThatFits(in: CGSize(width: width, height: 800)).height)
                    }
                    XCTAssertEqual(heights[0], heights[1], accuracy: 1, "标题长度不能改变顶栏高度")
                    XCTAssertGreaterThanOrEqual(heights[0], ChatTopLayout.controlsClearance)
                    let avatarCompanion = TopChatCompanion(title: "修复图片显示", status: "正在读文件") { size in
                        Color.clear.frame(width: size, height: size)
                    }.environment(\.verticalSizeClass, compact ? .compact : .regular).environment(\.dynamicTypeSize, type)
                    let avatarBar = UIHostingController(rootView: avatarCompanion).sizeThatFits(in: CGSize(width: width, height: 800)).height
                    XCTAssertLessThanOrEqual(heights[0], avatarBar, "两行文字不能比头像版占更多空间")
                    if type == .large { XCTAssertEqual(heights[0], 56, accuracy: 1) }
                }
            }
        }
        XCTAssertEqual(chatTopReadback(title: "修复图片显示", subtitle: "赛博虎妞 · wand", status: "等待你的确认"),
            "修复图片显示，赛博虎妞 · wand，等待你的确认")
        XCTAssertEqual(chatTopReadback(title: "修复图片显示", subtitle: "", status: ""), "修复图片显示")
    }

    /// 身份区只在顶栏控件之间的带子里排布：左边界让开返回键，右边界让开合并后的更多按钮，
    /// 长标题的省略号不会压到可点控件上。
    func testIdentityBandStaysBetweenTopControls() {
        for width: CGFloat in [320, 402, 768] {
            let band = ChatTopLayout.identityBand(width: width)
            XCTAssertGreaterThanOrEqual(band.width, 48)
            XCTAssertEqual(band.center - band.width / 2, ChatTopLayout.backInset, accuracy: 0.5)
            XCTAssertEqual(band.center + band.width / 2, width - ChatTopLayout.actionsInset, accuracy: 0.5)
        }
    }

    func testFileActivityRetiresErrorsAndUsesLatestCurrentTurn() throws {
        let data = Data(#"[{"role":"user","content":[{"type":"text","text":"test"}]},{"role":"assistant","content":[{"type":"tool_use","id":"r","name":"read","activity":{"kind":"read_file"}},{"type":"tool_use","id":"w","name":"write","activity":{"kind":"edit_file"}},{"type":"tool_result","tool_use_id":"w","content":"failed","is_error":true}]}]"#.utf8)
        let messages = try JSONDecoder().decode([ConversationTurn].self, from: data)
        XCTAssertEqual(avatarFileActivity(messages: messages, executing: true), .reading)
        XCTAssertEqual(avatarFileActivity(messages: messages, executing: false), .idle)
        let next = messages + [ConversationTurn(role: "user", content: [.text(text: "next", subagent: nil)])]
        XCTAssertEqual(avatarFileActivity(messages: next, executing: true), .idle)
    }
}

@MainActor private final class FreezeReceiptTransport: SessionInputTransport {
    var inputs: [String] = []
    func sendStructuredInput(id: String, input: String) async throws -> SessionSnapshot {
        inputs.append(input)
        return try JSONDecoder().decode(SessionSnapshot.self, from: Data("{\"id\":\"\(id)\",\"sessionKind\":\"structured\",\"status\":\"running\",\"structuredState\":{\"inFlight\":true}}".utf8))
    }
    func sendPtyInputChunk(id: String, input: String, view: String, shortcutKey: String?) async throws { XCTFail("No PTY or real model input in this test") }
}

@MainActor final class FocusComposerTests: XCTestCase {
    func testTemporaryPickerAndModalKeepEditorAndRestoreFocus() {
        let focus = ComposerFocusController()
        focus.focus()
        focus.borrow("picker")
        focus.keyboardHidden()
        XCTAssertTrue(focus.editing)
        XCTAssertFalse(focus.focused)
        focus.borrow("modal")
        focus.resume("picker")
        XCTAssertFalse(focus.focused)
        focus.resume("modal")
        XCTAssertTrue(focus.focused)
    }
    func testExplicitExitWinsOverLateDismissAndKeyboardCallbacks() {
        let focus = ComposerFocusController()
        focus.focus(); focus.borrow("settings")
        focus.collapse(); focus.resume("settings")
        XCTAssertFalse(focus.editing); XCTAssertFalse(focus.focused)
        focus.focus(); focus.keyboardHidden()
        XCTAssertFalse(focus.editing); XCTAssertFalse(focus.focused)
        focus.resume("old-picker")
        XCTAssertFalse(focus.focused)
    }
    func testAttachmentFromCollapsedCapsuleReturnsToEditor() {
        let focus = ComposerFocusController()
        focus.borrow("attachments", open: true); focus.keyboardHidden()
        XCTAssertTrue(focus.editing)
        focus.resume("attachments")
        XCTAssertTrue(focus.focused)
    }
    func testTopCatRemainsBetweenNativeTargetsForNarrowAndWideScreens() {
        for width: CGFloat in [320, 375, 402, 768, 1024] {
            let center = topCompanionCenter(width: width, size: 88, side: .left, drag: 0)
            XCTAssertEqual(center, width / 2, accuracy: 0.5)
            for side in [CatComposerSide.left, .right] {
                for drag: CGFloat in [-999, 0, 999] {
                    let x = topCompanionCenter(width: width, size: 88, side: side, drag: drag)
                    XCTAssertGreaterThanOrEqual(x - 44, 64)
                    XCTAssertLessThanOrEqual(x + 44, width - ChatTopLayout.actionsInset - ChatTopLayout.controlRowInset)
                }
            }
        }
    }
}

/// Exercise the real multiline measurement, keyboard and non-empty settings path.
/// The older morph tests use a fixed 44pt editor and empty settings, so cannot catch
/// feedback between UIKit scrolling and SwiftUI's measured height.
@MainActor private final class InputOpeningProbe: ObservableObject {
    @Published var text = ""
    @Published var height: CGFloat = 34
    var heights: [CGFloat] = []
    let focus = ComposerFocusController()
}
private struct InputOpeningTestView: View {
    @ObservedObject var probe: InputOpeningProbe
    @ObservedObject var focus: ComposerFocusController
    @StateObject private var keyboard = KeyboardObserver()
    var body: some View {
        VStack {
            Spacer()
            FocusComposerSurface(expanded: focus.editing || keyboard.isVisible, hasDraft: !probe.text.isEmpty,
                onFocus: { focus.focus() }, editor: {
                    IMEAwareComposerTextView(text: $probe.text, placeholder: "消息", isFocused: focus.focused,
                        maximumHeight: keyboard.isVisible ? 96 : 112, submitOnReturn: false,
                        onFocusChange: { focus.focused = $0 }, onCompositionChange: { _ in }, onSubmit: {},
                        onHeightChange: { probe.heights.append($0); probe.height = $0 })
                        .frame(height: max(34, probe.height))
                }, add: { ComposerAddButton(expanded: false, uploading: false, action: {}) },
                send: { Color.clear.frame(width: 48, height: 48) },
                settings: { ComposerSettingsStrip(model: "provider/very-long-model-name", mode: "全权限", thinking: "超高",
                    onModel: {}, onMode: {}, onThinking: {}) }, actionCount: 1)
        }.padding(.bottom, keyboard.lift).ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

@MainActor private final class ComposerAccessoriesProbe: ObservableObject {
    @Published var todoExpanded = false
    @Published var queueExpanded = false
    @Published var editorHeight: CGFloat = 34
    @Published var fieldHeight: CGFloat = 120
    @Published var text = "保留这份尚未发送的草稿。\n检查 TODO 与待发消息展开后，仍然可以继续输入。"
    var frames: [String: CGRect] = [:]
}

private struct ComposerAccessoryFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private extension View {
    func measureComposerAccessory(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ComposerAccessoryFrames.self,
                value: [name: geometry.frame(in: .named("composer-accessories"))])
        })
    }
}

/// Real shared components in a fixed viewport. State is injected through their
/// public bindings; these fixtures do not claim physical hinge or touch coverage.
private struct ComposerAccessoriesTestView: View {
    @ObservedObject var probe: ComposerAccessoriesProbe
    let todos: [TodoItem]
    let queue: [String]
    var recovery: AnyView? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { viewport in
            let maximumHeight = composerAccessoryMaximumHeight(viewportHeight: viewport.size.height,
                inputHeight: probe.fieldHeight, accessibility: typeSize.isAccessibilitySize)
            ChatDetailLayout {
                ScrollView {
                    Text("离线布局样例 · 正在核对输入区\n\n消息阅读区域需要保留，展开辅助内容后仍然可以继续输入。")
                        .font(.body).foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .background(Theme.workspaceReading)
                .measureComposerAccessory("reading")
            } composer: {
                VStack(spacing: 4) {
                    TodoProgressBar(todos: todos, maximumExpandedHeight: maximumHeight,
                        expanded: $probe.todoExpanded)
                        .measureComposerAccessory("todo")
                    QueueBar(items: queue, expanded: $probe.queueExpanded,
                        inFlight: true, steering: false, mutationPending: false,
                        onPromote: { _ in }, onDelete: { _ in }, onEdit: { _ in }, onClearAll: {},
                        maximumExpandedHeight: maximumHeight, recovery: recovery)
                        .measureComposerAccessory("queue")
                    FocusComposerSurface(expanded: true, hasDraft: true, onFocus: {}, editor: {
                        IMEAwareComposerTextView(text: $probe.text, placeholder: "发消息…", isFocused: false,
                            maximumHeight: composerMaximumInputHeight(compact: verticalSizeClass == .compact,
                                keyboardVisible: false), submitOnReturn: false,
                            onFocusChange: { _ in }, onCompositionChange: { _ in }, onSubmit: {},
                            onHeightChange: { probe.editorHeight = $0 })
                            .frame(height: max(34, probe.editorHeight))
                    }, add: { ComposerAddButton(expanded: false, uploading: false, action: {}) }, send: {
                        NativeComposerActions(phase: .idle, turnRunning: false, hasDraft: true, canSubmit: true,
                            message: nil, onSend: {}, onStop: {})
                    }, settings: {
                        ComposerSettingsStrip(model: "GPT-6.1", mode: "全权限", thinking: "超高",
                            onModel: {}, onMode: {}, onThinking: {})
                    }, isEmbeddedInDock: true, actionCount: 1)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.fieldHeight = $0 }
                    .measureComposerAccessory("input")
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Theme.workspaceReading)
                .measureComposerAccessory("dock")
            }
            .coordinateSpace(name: "composer-accessories")
            .onPreferenceChange(ComposerAccessoryFrames.self) { probe.frames = $0 }
        }
    }
}

@MainActor private final class ChatScrollFrameProbe: NSObject {
    struct Sample: CustomStringConvertible {
        let content: CGFloat
        let viewport: CGFloat
        let offset: CGFloat
        var description: String { "(content=\(content), viewport=\(viewport), offset=\(offset))" }
    }
    private weak var scroll: UIScrollView?
    private var displayLink: CADisplayLink?
    private(set) var samples: [Sample] = []
    init(scroll: UIScrollView) { self.scroll = scroll }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(record))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    func stop() { displayLink?.invalidate(); displayLink = nil }
    @objc private func record() {
        guard let scroll else { return }
        samples.append(Sample(content: scroll.contentSize.height, viewport: scroll.bounds.height,
                              offset: scroll.contentOffset.y + scroll.adjustedContentInset.top))
    }
}

@MainActor private func composerAccessoryScrollViews(_ root: UIView) -> [UIScrollView] {
    (root is UITextView ? [] : (root as? UIScrollView).map { [$0] } ?? []) +
        root.subviews.flatMap(composerAccessoryScrollViews)
}

private func composerSampleRGB(_ image: UIImage, at point: CGPoint) -> [Int]? {
    guard let source = image.cgImage,
          let pixel = source.cropping(to: CGRect(x: floor(point.x * image.scale),
            y: floor(point.y * image.scale), width: 1, height: 1)) else { return nil }
    var bytes = [UInt8](repeating: 0, count: 4)
    let succeeded = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    return succeeded ? bytes.prefix(3).map(Int.init) : nil
}

private func composerMaximumChannelDelta(_ first: [Int], _ second: [Int]) -> Int {
    guard first.count == second.count else { return 255 }
    var maximum = 0
    for index in first.indices { maximum = max(maximum, abs(first[index] - second[index])) }
    return maximum
}

@MainActor final class InputOpeningTests: XCTestCase {
    func testQueueRecoverySlotStaysBoundedWithAndWithoutPendingMessages() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let original = String(repeating: "取回的原文必须完整保留。即使包含许多段落，也不能把输入框挤出屏幕。\n", count: 40)
        let variants: [(String, CGFloat, CGFloat, DynamicTypeSize)] = [
            ("narrow-landscape", 678, 466, .large), ("narrow-ax3", 320, 678, .accessibility3)
        ]
        for (variant, width, height, type) in variants {
          for hasPendingMessages in [false, true] {
            let probe = ComposerAccessoriesProbe()
            probe.queueExpanded = true
            let draft = probe.text
            let recovery = AnyView(VStack(alignment: .leading, spacing: 4) {
                Text("已取回；当前输入保留，确认后加入继续编辑。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Button("加入当前输入继续编辑") {}.frame(minHeight: 44)
                    .measureComposerAccessory("recovery-restore")
                HStack {
                    Button("复制原文") {}
                    Spacer()
                    Button("关闭") {}
                }.font(.caption).frame(minHeight: 44)
                    .measureComposerAccessory("recovery-actions")
                Text(original).font(.footnote).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .measureComposerAccessory("recovery-original")
            }.padding(.horizontal, 4).padding(.vertical, 8))
            let root = ComposerAccessoriesTestView(probe: probe,
                todos: [TodoItem(content: "继续核对输入区", status: "in_progress", activeForm: nil)],
                queue: hasPendingMessages ? ["队列中仍保留第一条消息", "队列中仍保留第二条消息"] : [],
                recovery: recovery)
                .environment(\.colorScheme, .light).environment(\.dynamicTypeSize, type)
                .environment(\.verticalSizeClass, width > height ? .compact : .regular)
            let host = UIHostingController(rootView: root)
            host.safeAreaRegions = []
            host.overrideUserInterfaceStyle = .light
            host.traitOverrides.preferredContentSizeCategory = type.isAccessibilitySize ? .accessibilityExtraLarge : .large
            container.addChild(host); container.view.addSubview(host.view); host.didMove(toParent: container)
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            defer { host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent() }
            var previous: [String: CGRect] = [:]
            var stable = 0
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(50))
                host.view.layoutIfNeeded()
                stable = probe.frames.count == 8 && probe.frames == previous ? stable + 1 : 0
                if stable >= 3 { break }
                previous = probe.frames
            }
            let name = "composer-accessories-recovery-\(variant)-\(hasPendingMessages ? "queued" : "empty-queue")"
            XCTAssertGreaterThanOrEqual(stable, 3, name)
            let input = try XCTUnwrap(probe.frames["input"])
            let queue = try XCTUnwrap(probe.frames["queue"])
            let reading = try XCTUnwrap(probe.frames["reading"])
            let restore = try XCTUnwrap(probe.frames["recovery-restore"])
            let actions = try XCTUnwrap(probe.frames["recovery-actions"])
            let originalFrame = try XCTUnwrap(probe.frames["recovery-original"])
            let list = try XCTUnwrap(composerAccessoryScrollViews(host.view).first {
                let bounds = $0.convert($0.bounds, to: host.view)
                return queue.contains(CGPoint(x: bounds.midX, y: bounds.midY))
            })
            let budget = composerAccessoryMaximumHeight(viewportHeight: height, inputHeight: input.height,
                accessibility: type.isAccessibilitySize)
            XCTAssertLessThanOrEqual(list.bounds.height, budget + 1, name + ": recovery uses the same list budget")
            XCTAssertGreaterThan(list.contentSize.height, list.bounds.height * 4, "Full recovery text remains scrollable")
            XCTAssertLessThanOrEqual(restore.maxY, originalFrame.minY)
            XCTAssertLessThanOrEqual(actions.maxY, originalFrame.minY, "Recovery actions precede the long original")
            XCTAssertGreaterThanOrEqual(reading.height, 44)
            XCTAssertLessThanOrEqual(queue.maxY, input.minY + 1)
            XCTAssertLessThanOrEqual(input.maxY, height)
            XCTAssertEqual(probe.text, draft)

            // Public UIKit scrolling verifies reachability without pretending this
            // fixture performed a physical tap or a server queue mutation.
            list.scrollRectToVisible(list.convert(restore, from: host.view), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let visibleRestore = try XCTUnwrap(probe.frames["recovery-restore"])
            let viewport = list.convert(list.bounds, to: host.view)
            XCTAssertGreaterThanOrEqual(visibleRestore.intersection(viewport).height,
                min(44, visibleRestore.height) - 1, "The restore action remains reachable in the bounded list")
            XCTAssertEqual(try XCTUnwrap(probe.frames["input"]), input,
                "Scrolling recovered content must not move the input field")
            // Geometry can settle before the native disclosure cross-fade finishes.
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-\(name).png"))
            let observation: [String: Any] = ["name": name, "queueHasMessages": hasPendingMessages,
                "expandedListBudget": budget, "listHeight": list.bounds.height,
                "scrollableContentHeight": list.contentSize.height, "recoveredCharacterCount": original.count,
                "draftPreserved": probe.text == draft,
                "frames": probe.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }]
            let data = try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
            let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            receipt.name = name + "-geometry"; receipt.lifetime = .keepAlways; add(receipt)
            try data.write(to: URL(fileURLWithPath: "/tmp/wand-\(name).json"))
          }
        }
    }

    func testComposerAccessoriesRemainBoundedAcrossFourViewports() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let longText = String(repeating: "这是需要完整保留的超长中文内容，也包含 long-path/to/source.swift 与换行。\n", count: 3)
        let todos = (0..<24).map { index in
            TodoItem(content: "第 \(index + 1) 项：" + longText,
                status: index == 0 ? "completed" : index == 1 ? "in_progress" : "pending",
                activeForm: index == 1 ? "正在检查：" + longText : nil)
        }
        let queue = (0..<20).map { "第 \($0 + 1) 条待发消息：" + longText }
        let sizes: [(String, CGFloat, CGFloat)] = [
            ("open-portrait", 669, 951), ("open-landscape", 951, 669),
            ("closed-portrait", 466, 678), ("closed-landscape", 678, 466),
            ("narrow-content", 320, 678)
        ]
        for (sizeName, width, height) in sizes {
          for dark in [false, true] {
            for type: DynamicTypeSize in [.large, .accessibility3] {
                // The system's shared bar can leave a narrower content lane than
                // the display width. One AX variant covers that separate constraint.
                if sizeName == "narrow-content" && (dark || !type.isAccessibilitySize) { continue }
                let probe = ComposerAccessoriesProbe()
                let originalDraft = probe.text
                let root = ComposerAccessoriesTestView(probe: probe, todos: todos, queue: queue)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.dynamicTypeSize, type)
                    .environment(\.verticalSizeClass, width > height ? .compact : .regular)
                let host = UIHostingController(rootView: root)
                host.safeAreaRegions = []
                host.traitOverrides.preferredContentSizeCategory = type.isAccessibilitySize ? .accessibilityExtraLarge : .large
                host.overrideUserInterfaceStyle = dark ? .dark : .light
                container.addChild(host); container.view.addSubview(host.view); host.didMove(toParent: container)
                host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                defer {
                    host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                }
                var collapsedHeights: [String: CGFloat] = [:]
                for (phase, todoExpanded, queueExpanded) in [
                    ("collapsed", false, false), ("todo-expanded", true, false),
                    ("todo-collapsed", false, false), ("queue-expanded", false, true),
                    ("queue-collapsed", false, false)
                ] {
                    probe.todoExpanded = todoExpanded; probe.queueExpanded = queueExpanded
                    var previousFrames: [String: CGRect] = [:]
                    var stable = 0
                    for _ in 0..<40 {
                        try await Task.sleep(for: .milliseconds(50))
                        host.view.layoutIfNeeded()
                        let frames = probe.frames
                        stable = frames.count == 5 && frames == previousFrames ? stable + 1 : 0
                        if stable >= 3 { break }
                        previousFrames = frames
                    }
                    let name = "composer-accessories-\(sizeName)-\(dark ? "dark" : "light")-\(type.isAccessibilitySize ? "ax3" : "standard")-\(phase)"
                    XCTAssertGreaterThanOrEqual(stable, 3, name + ": layout must settle")
                    XCTAssertEqual(host.view.bounds.size, CGSize(width: width, height: height))
                    let reading = try XCTUnwrap(probe.frames["reading"])
                    let todo = try XCTUnwrap(probe.frames["todo"])
                    let pending = try XCTUnwrap(probe.frames["queue"])
                    let input = try XCTUnwrap(probe.frames["input"])
                    let dock = try XCTUnwrap(probe.frames["dock"])
                    XCTAssertGreaterThanOrEqual(reading.height, 44, name + ": preserve a usable reading area")
                    XCTAssertLessThanOrEqual(todo.maxY, pending.minY + 1, name + ": TODO precedes the queue")
                    XCTAssertLessThanOrEqual(pending.maxY, input.minY + 1, name + ": queue stays outside the input field")
                    XCTAssertGreaterThanOrEqual(input.minY, 0)
                    XCTAssertLessThanOrEqual(input.maxY, height, name + ": the whole input remains visible")
                    XCTAssertGreaterThanOrEqual(input.height, 48)
                    XCTAssertEqual(probe.text, originalDraft, "Expanding auxiliary content must preserve the draft")
                    let budget = composerAccessoryMaximumHeight(viewportHeight: height, inputHeight: input.height,
                        accessibility: type.isAccessibilitySize)
                    if phase == "collapsed" {
                        collapsedHeights = ["todo": todo.height, "queue": pending.height]
                    }
                    for (key, frame, expanded) in [("todo", todo, todoExpanded), ("queue", pending, queueExpanded)] {
                        let collapsedHeight = try XCTUnwrap(collapsedHeights[key])
                        XCTAssertGreaterThanOrEqual(collapsedHeight, 44, "Summary remains a native touch target")
                        if expanded {
                            XCTAssertGreaterThan(frame.height, collapsedHeight, name)
                            XCTAssertLessThanOrEqual(frame.height - collapsedHeight, budget + 12, name + ": list is bounded")
                            let list = try XCTUnwrap(composerAccessoryScrollViews(host.view).first {
                                let bounds = $0.convert($0.bounds, to: host.view)
                                return frame.contains(CGPoint(x: bounds.midX, y: bounds.midY))
                            }, name + ": expanded content must remain scrollable")
                            XCTAssertLessThanOrEqual(list.bounds.height, budget + 1, name)
                            XCTAssertGreaterThan(list.contentSize.height, list.bounds.height, name + ": all long content remains reachable")
                        } else {
                            XCTAssertEqual(frame.height, collapsedHeight, accuracy: 1, name + ": collapse restores the compact summary")
                        }
                    }
                    guard !phase.hasSuffix("-collapsed") else { continue }
                    // Stable layout samples alone can precede the 0.18s disclosure animation.
                    try await Task.sleep(for: .milliseconds(250))
                    host.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                    }
                    let readingRGB: [Int] = try XCTUnwrap(composerSampleRGB(image, at: CGPoint(x: 4, y: reading.midY)))
                    let dockRGB: [Int] = try XCTUnwrap(composerSampleRGB(image, at: CGPoint(x: 4, y: dock.midY)))
                    XCTAssertLessThanOrEqual(composerMaximumChannelDelta(readingRGB, dockRGB), 2,
                        name + ": outside the field, the dock must match the reading background")
                    let edgeSamples: [[Int]] = stride(from: CGFloat(0), through: 1.5, by: 0.5).compactMap {
                        composerSampleRGB(image, at: CGPoint(x: input.minX + $0, y: input.midY))
                    }
                    let boundaryContrast = edgeSamples.map { composerMaximumChannelDelta($0, dockRGB) }.max() ?? 0
                    XCTAssertGreaterThan(boundaryContrast, 8, name + ": a visible boundary must distinguish the input field")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                    try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-\(name).png"))
                    let geometry = probe.frames.mapValues { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
                    let observation: [String: Any] = ["name": name, "fixtureWidth": width, "fixtureHeight": height,
                        "frames": geometry, "expandedListBudget": budget, "readingRGB": readingRGB,
                        "dockRGB": dockRGB, "inputBoundaryContrast": boundaryContrast,
                        "todoCount": todos.count, "queuedCount": queue.count, "draftPreserved": probe.text == originalDraft]
                    let data = try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
                    let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                    receipt.name = name + "-geometry"; receipt.lifetime = .keepAlways; add(receipt)
                    try data.write(to: URL(fileURLWithPath: "/tmp/wand-\(name).json"))
                }
            }
          }
        }
    }

    func testComposerPresentationSnapshots() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }
        let appearances = [(dark: false, increasedContrast: false),
                           (dark: true, increasedContrast: false),
                           (dark: true, increasedContrast: true)]
        for expanded in [false, true] {
          for appearance in appearances {
            // Match the real Chat/NewConversation parent: the dock owns spacing,
            // while the shared input must retain its own visible field surface.
            let host = UIHostingController(rootView: ChatDetailLayout {
                VStack(alignment: .leading, spacing: 16) {
                    Text("离线界面样例").font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 16)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.workspaceReading)
            } composer: {
                VStack(spacing: 4) {
                    TodoProgressBar(todos: [
                        TodoItem(content: "检查键盘与输入栏布局", status: "completed", activeForm: nil),
                        TodoItem(content: "优化 TODO、待发消息和输入选项", status: "in_progress", activeForm: nil),
                        TodoItem(content: "验证窄屏和深色外观", status: "pending", activeForm: nil)])
                    QueueBar(items: ["再检查横屏时输入框是否遮挡消息，保留已有草稿。", "完成后给我测试结果。"], expanded: .constant(true),
                        inFlight: false, steering: false, mutationPending: false,
                        onPromote: { _ in }, onDelete: { _ in }, onEdit: { _ in }, onClearAll: {})
                FocusComposerSurface(expanded: expanded, hasDraft: expanded, onFocus: {}, editor: {
                    Text(expanded ? "请继续检查输入体验" : "")
                        .font(.body).foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                }, add: { ComposerAddButton(expanded: false, uploading: false, action: {}) },
                send: { NativeComposerActions(phase: .idle, turnRunning: false, hasDraft: expanded, canSubmit: expanded,
                    message: nil, onSend: {}, onStop: {}) }, settings: {
                    ComposerSettingsStrip(model: "GPT-6.1", mode: "全权限", thinking: "超高", onModel: {}, onMode: {}, onThinking: {})
                }, isEmbeddedInDock: true, isFocused: expanded, actionCount: expanded ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Theme.workspaceReading)
            }
            .environment(\.colorScheme, appearance.dark ? .dark : .light))
            host.traitOverrides.accessibilityContrast = appearance.increasedContrast ? .high : .normal
            window.rootViewController = host
            window.overrideUserInterfaceStyle = appearance.dark ? .dark : .light
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = "composer-dock-\(Int(window.bounds.width))-\(expanded ? "editing" : "empty")-\(appearance.dark ? "dark" : "light")-\(appearance.increasedContrast ? "high-contrast" : "standard")"
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-\(name).png"))
          }
        }
    }

    func testInstalledChatKeyboardStaysAboveKeyboard() async throws {
        guard let path = try? String(contentsOfFile: "/tmp/wand-ios-keyboard-acceptance-path", encoding: .utf8) else {
            throw XCTSkip("Requires an explicit private installed-service keyboard acceptance profile")
        }
        let file = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        struct Profile: Decodable { let baseUrl: String; let token: String; let sessionId: String }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: file))
        let api = WandAPI(baseURL: try XCTUnwrap(URL(string: profile.baseUrl)), token: profile.token)
        let chat = ChatStore(sessionId: profile.sessionId, api: api)
        let focus = ComposerFocusController()
        let keyboard = KeyboardObserver()
        let host = UIHostingController(rootView:
            SystemHomeNavigation(mode: .im, enabled: true, onSelect: { _ in }) {
                NavigationStack {
                    ChatView(sessionId: profile.sessionId, api: api, sharedStore: chat, focusController: focus)
                }
            })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.endEditing(true); chat.shutdown(); window.isHidden = true }
        for _ in 0..<300 {
            if chat.snapshot != nil && !chat.loading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(chat.snapshot, "Installed session must load before keyboard acceptance")
        XCTAssertNil(chat.loadError)
        func findEditor(_ view: UIView) -> ComposerUITextView? {
            if let result = view as? ComposerUITextView { return result }
            return view.subviews.lazy.compactMap { findEditor($0) }.first
        }
        let editor = try XCTUnwrap(findEditor(host.view))
        let initialText = editor.text
        for round in 0..<3 {
            // Use the same state owner/action as tapping the real capsule.
            focus.focus()
            var settled = 0
            for _ in 0..<100 {
                host.view.layoutIfNeeded()
                let frame = editor.convert(editor.bounds, to: window)
                let top = window.bounds.maxY - window.safeAreaInsets.bottom - keyboard.lift
                let gap = top - frame.maxY
                settled = keyboard.lift > 0 && frame.height > 0 && gap > 0 && gap < 160 ? settled + 1 : 0
                if settled >= 3 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let frame = editor.convert(editor.bounds, to: window)
            print("INSTALLED-KEYBOARD round=\(round) editor=\(frame) lift=\(keyboard.lift) settled=\(settled)")
            XCTAssertGreaterThanOrEqual(settled, 3, "Real chat input must settle immediately above the software keyboard")
            XCTAssertTrue(editor.isFirstResponder)
            XCTAssertEqual(editor.text, initialText, "Focus testing must preserve the existing draft")
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = "installed-chat-keyboard-round-\(round)"
            attachment.lifetime = .keepAlways
            add(attachment)
            focus.collapse()
            window.endEditing(true)
            for _ in 0..<80 {
                if !keyboard.isVisible { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(keyboard.isVisible)
        }
    }

    func testNavigationContainerDoesNotApplyASecondKeyboardLift() async throws {
        let probe = InputOpeningProbe()
        let keyboard = KeyboardObserver()
        let host = UIHostingController(rootView:
            SystemHomeNavigation(mode: .im, enabled: true, onSelect: { _ in }) {
                InputOpeningTestView(probe: probe, focus: probe.focus)
            })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { probe.focus.collapse(); window.isHidden = true }
        func container(_ controller: UIViewController) -> SystemHomeTabController? {
            if let result = controller as? SystemHomeTabController { return result }
            return controller.children.lazy.compactMap { container($0) }.first
        }
        func editor(_ view: UIView) -> ComposerUITextView? {
            if let result = view as? ComposerUITextView { return result }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let navigation = try XCTUnwrap(container(host))
        let initialFrame = navigation.view.convert(navigation.view.bounds, to: window)
        for round in 0..<2 {
            probe.focus.focus()
            for _ in 0..<40 {
                if keyboard.lift > 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            // A hardware-only keyboard cannot exercise viewport avoidance.
            try XCTSkipIf(keyboard.lift == 0, "Software keyboard required to verify double avoidance")
            // First keyboard creation can outlast its nominal animation duration
            // on a freshly booted simulator. Wait for the actual layout contract,
            // rather than sampling the still-moving surface after a fixed delay.
            var settledSamples = 0
            for _ in 0..<80 {
                host.view.layoutIfNeeded()
                if let textView = editor(host.view) {
                    let frame = textView.convert(textView.bounds, to: window)
                    let top = window.bounds.maxY - window.safeAreaInsets.bottom - keyboard.lift
                    let gap = top - frame.maxY
                    settledSamples = gap > 0 && gap < 160 ? settledSamples + 1 : 0
                    if settledSamples >= 3 { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let focusedFrame = navigation.view.convert(navigation.view.bounds, to: window)
            XCTAssertEqual(focusedFrame.minY, initialFrame.minY, accuracy: 1)
            XCTAssertEqual(focusedFrame.height, initialFrame.height, accuracy: 1,
                "The outer host must not shrink the inner navigation for the keyboard")
            let textView = try XCTUnwrap(editor(host.view))
            XCTAssertTrue(textView.isFirstResponder)
            let textFrame = textView.convert(textView.bounds, to: window)
            let keyboardTop = window.bounds.maxY - window.safeAreaInsets.bottom - keyboard.lift
            print("KEYBOARD-LAYOUT round=\(round) container=\(focusedFrame) editor=\(textFrame) keyboardTop=\(keyboardTop) settled=\(settledSamples)")
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = "keyboard-layout-round-\(round)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertLessThan(textFrame.maxY, keyboardTop)
            XCTAssertLessThan(keyboardTop - textFrame.maxY, 160,
                "The editor must remain directly above its toolbar and keyboard")
            probe.focus.collapse()
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    func testResponderChangesWaitUntilAfterRepresentableUpdateAndCancelOnNewIntent() async throws {
        var desired = IMEAwareComposerTextView(text: .constant(""), placeholder: "消息", isFocused: true,
            onFocusChange: { _ in }, onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in })
        let focused = desired
        let coordinator = desired.makeCoordinator()
        let editor = ComposerUITextView()
        editor.delegate = coordinator
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController!.view.addSubview(editor)
        editor.frame = CGRect(x: 0, y: 100, width: 300, height: 44)
        defer { coordinator.cancelFocusRetry(); editor.resignFirstResponder(); window.isHidden = true }
        coordinator.reconcileFocus(editor)
        XCTAssertFalse(editor.isFirstResponder, "Becoming first responder must not publish keyboard state during updateUIView")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(editor.isFirstResponder)
        desired = IMEAwareComposerTextView(text: .constant(""), placeholder: "消息", isFocused: false,
            onFocusChange: { _ in }, onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in })
        coordinator.parent = desired
        coordinator.reconcileFocus(editor)
        print("INPUT-OPEN blur remains deferred: \(editor.isFirstResponder)")
        XCTAssertTrue(editor.isFirstResponder, "Resigning inside updateUIView synchronously publishes keyboard/focus state")
        // Reopening before the queued blur runs must invalidate that old intent.
        coordinator.parent = focused
        coordinator.reconcileFocus(editor)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(editor.isFirstResponder, "A stale blur must not dismiss a newly reopened input")
        coordinator.parent = desired
        coordinator.reconcileFocus(editor)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(editor.isFirstResponder)
        // A focus request followed by collapse in the same transaction must never reopen.
        coordinator.parent = IMEAwareComposerTextView(text: .constant(""), placeholder: "消息", isFocused: true,
            onFocusChange: { _ in }, onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in })
        coordinator.reconcileFocus(editor)
        coordinator.parent = desired
        coordinator.reconcileFocus(editor)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertFalse(editor.isFirstResponder)
        // Navigation teardown must also revoke every queued/retried focus.
        coordinator.parent = focused
        coordinator.reconcileFocus(editor)
        IMEAwareComposerTextView.dismantleUIView(editor, coordinator: coordinator)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertFalse(editor.isFirstResponder)
    }

    func testOpeningTypingAndReopeningWithRealSettingsSettles() async throws {
        let probe = InputOpeningProbe()
        let host = UIHostingController(rootView: InputOpeningTestView(probe: probe, focus: probe.focus))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { probe.focus.collapse(); window.isHidden = true }
        func find(_ view: UIView) -> ComposerUITextView? {
            if let text = view as? ComposerUITextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        try await Task.sleep(for: .milliseconds(200))
        let editor = try XCTUnwrap(find(host.view))
        let coordinator = try XCTUnwrap(editor.delegate as? IMEAwareComposerTextView.Coordinator)
        for round in 0..<3 {
            print("INPUT-OPEN round=\(round) begin")
            probe.focus.focus()
            try await Task.sleep(for: .milliseconds(700))
            for text in ["", "单行输入", String(repeating: "中文多行输入\n", count: 20), "短输入"] {
                probe.text = text
                // Wait for the real UIKit text/measurement acknowledgement, not a
                // guessed 150ms (competing native builds can delay the main queue).
                var converged = false
                for _ in 0..<60 {
                    host.view.layoutIfNeeded()
                    let fitted = editor.sizeThatFits(CGSize(width: editor.bounds.width, height: .greatestFiniteMagnitude)).height
                    let maximum = coordinator.parent.maximumHeight
                    let expected = min(maximum, max(24, ceil(fitted)))
                    if editor.text == text, abs(probe.height - expected) <= 0.5 {
                        converged = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                print("INPUT-OPEN text=\(text.count) height=\(probe.height) scroll=\(editor.isScrollEnabled) reports=\(probe.heights.count) converged=\(converged)")
                XCTAssertTrue(converged, "Current text and measured height must converge within the bounded window")
            }
            let before = probe.heights.count
            try await Task.sleep(for: .milliseconds(250))
            print("INPUT-OPEN settled delta=\(probe.heights.count - before) focus=\(editor.isFirstResponder)")
            XCTAssertTrue(editor.isFirstResponder)
            XCTAssertEqual(probe.heights.count, before, "Height reporting must settle rather than oscillate")
            XCTAssertTrue(find(host.view) === editor)
            XCTAssertLessThan(probe.heights.count, 60)
            probe.focus.collapse()
            try await Task.sleep(for: .milliseconds(400))
        }
    }
}

@MainActor private final class MorphEditorProbe: ObservableObject {
    @Published var text = "前后"
    let focus = ComposerFocusController()
}
private struct MorphEditorTestView: View {
    @ObservedObject var probe: MorphEditorProbe
    @ObservedObject var focus: ComposerFocusController
    var body: some View {
        FocusComposerSurface(expanded: focus.editing, hasDraft: !probe.text.isEmpty, onFocus: { focus.focus() }, editor: {
            IMEAwareComposerTextView(text: $probe.text, placeholder: "消息", isFocused: focus.focused,
                maximumHeight: 96, submitOnReturn: false, onFocusChange: { focus.focused = $0 },
                onCompositionChange: { _ in }, onSubmit: {}, onHeightChange: { _ in }).frame(height: 44)
        }, add: { Text("+").frame(width: 48, height: 48) }, send: { EmptyView() }, settings: { EmptyView() })
    }
}

/// The settings slot is a builder branch: an empty branch yields two subviews instead of three.
/// Fixed `subviews[2]` indexing trapped in `LayoutSubviews.subscript` for exactly this shape.
@MainActor private final class EmptySettingsProbe: ObservableObject {
    @Published var text = ""
    let focus = ComposerFocusController()
}
private struct EmptySettingsTestView: View {
    @ObservedObject var probe: EmptySettingsProbe
    var body: some View {
        FocusComposerSurface(expanded: probe.focus.editing, hasDraft: !probe.text.isEmpty, onFocus: { probe.focus.focus() }, editor: {
            TextEditor(text: $probe.text).frame(height: 44)
        }, add: { Text("+").frame(width: 48, height: 48) }, send: { EmptyView() }, settings: { EmptyView() })
    }
}
extension FocusComposerTests {
    func testCapsuleSlotsFollowRealChildCount() {
        // Two children: the empty settings branch collapsed, so the prompt takes index 1.
        let collapsed = ComposerCapsuleSlots(childCount: 2)
        XCTAssertEqual(collapsed?.add, 0)
        XCTAssertNil(collapsed?.settings)
        XCTAssertEqual(collapsed?.prompt, 1)
        // Three children: add / settings / prompt keeps the historical indices.
        let full = ComposerCapsuleSlots(childCount: 3)
        XCTAssertEqual(full?.add, 0)
        XCTAssertEqual(full?.settings, 1)
        XCTAssertEqual(full?.prompt, 2)
        // Degenerate counts never produce an out-of-range slot.
        XCTAssertNil(ComposerCapsuleSlots(childCount: 0))
        XCTAssertNil(ComposerCapsuleSlots(childCount: 1))
        for count in 2...5 {
            let slots = ComposerCapsuleSlots(childCount: count)
            XCTAssertNotNil(slots)
            for index in [slots?.add, slots?.settings, slots?.prompt].compactMap({ $0 }) {
                XCTAssertLessThan(index, count, "slot \(index) out of range for \(count) children")
            }
        }
    }
    func testEmptySettingsBranchLaysOutCapsuleWithoutIndexingMissingChild() async throws {
        let probe = EmptySettingsProbe()
        let host = UIHostingController(rootView: EmptySettingsTestView(probe: probe))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for width: CGFloat in [320, 390, 768] {
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            probe.focus.collapse()
            try await Task.sleep(for: .milliseconds(120))
            host.view.layoutIfNeeded()
            // Collapsed capsule keeps a single 48pt row: the missing settings lane must not
            // add height, and layout must not trap on the absent third child.
            XCTAssertGreaterThanOrEqual(host.view.bounds.height, 48)
            probe.focus.focus()
            try await Task.sleep(for: .milliseconds(160))
            host.view.layoutIfNeeded()
        }
    }
}
extension FocusComposerTests {
    func testExpandedEditorUsesFullWidthForEmptySingleAndMultilineDrafts() async throws {
        let probe = MorphEditorProbe()
        let host = UIHostingController(rootView: MorphEditorTestView(probe: probe, focus: probe.focus))
        // A window owns its root controller's frame and can overwrite the proposed
        // test width on the next keyboard/layout pass. A child gives this fixture
        // an explicit viewport; system safe-area behavior has separate coverage.
        host.safeAreaRegions = []
        let container = UIViewController()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { probe.focus.collapse(); window.isHidden = true; window.rootViewController = nil }
        func find(_ view: UIView) -> ComposerUITextView? {
            if let text = view as? ComposerUITextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        probe.focus.focus()
        try await Task.sleep(for: .milliseconds(180))
        let editor = try XCTUnwrap(find(host.view))
        for width: CGFloat in [320, 390, 768] {
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            for text in ["", "单行文字", "第一行中文\n第二行保留光标", ""] {
                probe.text = text
                try await Task.sleep(for: .milliseconds(120))
                host.view.layoutIfNeeded()
                XCTAssertEqual(host.view.bounds.width, width, accuracy: 1)
                XCTAssertTrue(find(host.view) === editor)
                let bounds = editor.convert(editor.bounds, to: host.view)
                XCTAssertEqual(bounds.minX, 24, accuracy: 1)
                XCTAssertEqual(bounds.maxX, width - 24, accuracy: 1,
                    "Only horizontal surface padding remains, with no send-button lane")
            }
        }
    }

    func testSameNativeEditorPreservesChineseCommitAndCaretAcrossMorphAndBorrow() async throws {
        let probe = MorphEditorProbe()
        let host = UIHostingController(rootView: MorphEditorTestView(probe: probe, focus: probe.focus))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        func find(_ view: UIView) -> ComposerUITextView? {
            if let text = view as? ComposerUITextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        try await Task.sleep(for: .milliseconds(120))
        let editor = try XCTUnwrap(find(host.view))
        probe.focus.focus()
        try await Task.sleep(for: .milliseconds(180))
        editor.selectedRange = NSRange(location: 1, length: 0)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(probe.text, "前后")
        editor.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0)); editor.unmarkText()
        XCTAssertEqual(probe.text, "前你后")
        probe.focus.borrow("model"); probe.focus.keyboardHidden(); probe.focus.resume("model")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(find(host.view) === editor)
        XCTAssertEqual(editor.selectedRange.location, 2)
        probe.focus.collapse()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(find(host.view) === editor)
        probe.focus.focus()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(find(host.view) === editor)
        XCTAssertEqual(editor.text, "前你后")
        XCTAssertEqual(editor.selectedRange.location, 2)
        editor.deleteBackward()
        XCTAssertEqual(probe.text, "前后")
    }
}

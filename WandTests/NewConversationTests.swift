import Foundation
import SwiftUI
import XCTest
@testable import Wand

final class NewConversationTests: XCTestCase {
    func testEmptyInitialDirectoryFallsBackWithoutOverridingExplicitContext() {
        let paths = [RecentPath(path: "", name: nil, lastUsedAt: nil),
                     RecentPath(path: "/recent", name: nil, lastUsedAt: nil)]
        XCTAssertEqual(NewConversationView.preferredCwd(initialCwd: "", recentPaths: paths, defaultCwd: "/default"), "/recent")
        XCTAssertEqual(NewConversationView.preferredCwd(initialCwd: "  \n", defaultCwd: "/default"), "/default")
        XCTAssertEqual(NewConversationView.preferredCwd(initialCwd: "/explicit", recentPaths: paths, defaultCwd: "/default"), "/explicit")
        XCTAssertEqual(NewConversationView.preferredCwd(initialCwd: nil), "")
    }

    func testGlobalPresentationHasOneOwnerAndNewTasksKeepWorktreeBinding() throws {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Wand")
        let root = try String(contentsOf: sourceDirectory.appendingPathComponent("NativeRootView.swift"), encoding: .utf8)
        XCTAssertFalse(root.contains(".sheet(isPresented: $presentNewConversation"))
        XCTAssertTrue(root.contains("marker == \"wand:pending-conversation\""))
        XCTAssertTrue(root.contains("onCancel: { presentNewConversation = false }"))
        XCTAssertTrue(root.contains("initialCreateTask: pendingCreatesTask"))
        XCTAssertTrue(root.contains("guard presentNewConversation, pendingCreationID == creationID"))
        XCTAssertTrue(root.contains(".id(creationID)"))
        XCTAssertFalse(root.contains("requestNewTask: Binding(get: { presentNewConversation }"))
        let pending = try String(contentsOf: sourceDirectory.appendingPathComponent("NewConversationView.swift"), encoding: .utf8)
        XCTAssertTrue(pending.contains("Toggle(\"隔离 worktree\", isOn: $worktreeEnabled)"))
        XCTAssertTrue(pending.contains("let frozenWorktree = worktreeEnabled"))
        XCTAssertTrue(pending.contains("worktree: frozenWorktree, creationRequestId:"))
        XCTAssertFalse(pending.contains("worktree: false,"))
        XCTAssertTrue(pending.contains("let detail = try await api.getWorkspaceTask(taskId: taskID)"))
        XCTAssertTrue(pending.contains("resolvedCwd = detail.cwd"))
        XCTAssertTrue(pending.contains("cwd: resolvedCwd,"))
        XCTAssertTrue(pending.contains("workspaceId: resolvedWorkspaceID,"))
    }

    func testPendingAndRunningConversationUseTheSameDetailAndComposer() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Wand")
        let pending = try String(contentsOf: directory.appendingPathComponent("NewConversationView.swift"), encoding: .utf8)
        let running = try String(contentsOf: directory.appendingPathComponent("ChatView.swift"), encoding: .utf8)
        for source in [pending, running] {
            XCTAssertTrue(source.contains("ChatDetailLayout("))
            XCTAssertTrue(source.contains("FocusComposerSurface("))
            XCTAssertTrue(source.contains("ChatTopIdentityBar("))
            XCTAssertTrue(source.contains("isEmbeddedInDock: true"))
        }
        XCTAssertFalse(pending.contains("NavigationStack {"))
        XCTAssertFalse(pending.contains(".sheet(isPresented: $showSettings)"))
        XCTAssertFalse(pending.contains("任务名称不能为空"))
        XCTAssertTrue(pending.contains("selection = nil\n        showAttachments = false"))
        XCTAssertTrue(pending.contains("ComposerSettingsStrip("))
        XCTAssertTrue(pending.contains("SearchableChoiceSheet("))
        XCTAssertFalse(pending.contains("textFieldStyle(.roundedBorder)"))
        XCTAssertFalse(pending.contains("DisclosureGroup("))
        XCTAssertTrue(pending.contains("maximumHeight: composerMaximumHeight"))
        XCTAssertTrue(pending.contains("confirmationDialog(\"设置本次对话权限\""))
    }

    func testExplicitTaskOwnerSurvivesMissingListSnapshot() {
        let bound = NewConversationBoundTask(id: "task-1", workspaceId: "workspace-1", name: "已有任务", cwd: "/project")
        XCTAssertEqual(pendingConversationTaskContext(boundTask: bound, selectedTaskID: "task-1", tasks: []), bound)
        XCTAssertNil(pendingConversationTaskContext(boundTask: bound, selectedTaskID: "task-2", tasks: []))
        XCTAssertNil(pendingConversationTaskContext(boundTask: nil, selectedTaskID: "task-1", tasks: []))
    }

    @MainActor
    func testInstalledServerPendingDetailLoadsWithoutCreatingWork() async throws {
        let pointer = URL(fileURLWithPath: "/tmp/wand-ios-pending-acceptance-connection-path")
        guard let path = try? String(contentsOf: pointer, encoding: .utf8) else {
            throw XCTSkip("Requires an explicit private installed-service connection path")
        }
        struct Connection: Decodable { let connectionCode: String }
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let target = try XCTUnwrap(WandAuth.decodeConnectCode(connection.connectionCode))
        let api = WandAPI(baseURL: target.url, token: target.token)
        let config = try await api.serverConfig()
        _ = try await api.listTaskGroups()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let identity = "pending-acceptance-" + UUID().uuidString
        let cwd = config.defaultCwd ?? ""
        let draft = SessionDraftStore.shared.draft(sessionId: "pending-new-conversation:\(identity):\(cwd)", api: api)
        defer { draft.text = ""; draft.attachments.discardUnsentAttachments() }
        let host = UIHostingController(rootView: NewConversationView(
            api: api, serverID: identity, initialCwd: cwd, initialCreateTask: true,
            onCreated: { _ in XCTFail("Opening or editing the pending detail must not create work") }
        ))
        // A fixed child hosting controller keeps test geometry independent of the simulator window.
        // This verifies content reflow at the Duo viewport sizes, not physical folding events.
        let window = UIWindow(windowScene: scene)
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.addChild(host)
        host.safeAreaRegions = []
        container.view.addSubview(host.view)
        host.view.frame = CGRect(x: 0, y: 0, width: 466, height: 678)
        host.didMove(toParent: container)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .seconds(2))
        func editors(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        func menuControls(_ view: UIView) -> [UIControl] {
            (view as? UIControl).map { [$0] } ?? view.subviews.flatMap(menuControls)
        }
        func menuTree(_ element: UIMenuElement) -> [UIMenuElement] {
            [element] + ((element as? UIMenu)?.children.flatMap(menuTree) ?? [])
        }
        let evidence = URL(fileURLWithPath: "/tmp/wand-ios-new-work-acceptance")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "pending-task-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: evidence.appendingPathComponent(name + ".png"))
        }
        let originalEditor = try XCTUnwrap(editors(host.view).first)
        let configurationDeadline = Date().addingTimeInterval(20)
        while Date() < configurationDeadline {
            let invitationControls = menuControls(host.view).filter {
                $0.showsMenuAsPrimaryAction && $0.convert($0.bounds, to: host.view).minY > 100
            }
            if invitationControls.count == 3 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Empty and edited states use the same production view and editor. The
        // invitation must not depend on an already populated draft.
        for (name, width, height, category, dark) in [
            ("empty-390", 390.0, 800.0, UIContentSizeCategory.large, false),
            ("empty-320", 320.0, 700.0, .large, false),
            ("empty-large-type-dark", 390.0, 800.0, .accessibilityExtraExtraExtraLarge, true)
        ] {
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.traitOverrides.preferredContentSizeCategory = category
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            try await Task.sleep(for: .milliseconds(250))
            host.view.layoutIfNeeded()
            let controls = menuControls(host.view).filter {
                $0.showsMenuAsPrimaryAction && $0.convert($0.bounds, to: host.view).minY > 100
            }
            XCTAssertEqual(controls.count, 3, "One invitation with employee, directory and task controls")
            for control in controls {
                let frame = control.convert(control.bounds, to: host.view)
                XCTAssertGreaterThanOrEqual(frame.width + 0.5, 44)
                XCTAssertGreaterThanOrEqual(frame.height + 0.5, 44)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width + 1)
            }
            XCTAssertTrue(editors(host.view).first === originalEditor)
            try capture(name)
        }
        host.traitOverrides.preferredContentSizeCategory = .large
        host.overrideUserInterfaceStyle = .light
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        draft.text = "等待发送的验收草稿（不执行）"
        draft.attachments.stageFileSelection(.success((1...5).map {
            URL(fileURLWithPath: "/tmp/只读布局验收附件-\($0).txt")
        }), cleanupAfterUpload: false)
        try await Task.sleep(for: .milliseconds(300))
        let controls = menuControls(host.view).filter {
            $0.showsMenuAsPrimaryAction && $0.convert($0.bounds, to: host.view).minY > 100
        }.sorted {
            let first = $0.convert($0.bounds, to: host.view)
            let second = $1.convert($1.bounds, to: host.view)
            return abs(first.minY - second.minY) > 10 ? first.minY < second.minY : first.minX < second.minX
        }
        XCTAssertEqual(controls.count, 3)
        for (index, expectedAction) in ["选择员工…", "输入其他目录…", "新建任务"].enumerated() {
            let control = try XCTUnwrap(controls.indices.contains(index) ? controls[index] : nil)
            control.performPrimaryAction()
            var presentedMenu: UIMenu?
            for _ in 0..<30 {
                control.contextMenuInteraction?.updateVisibleMenu { presentedMenu = $0; return $0 }
                if presentedMenu != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let menu = try XCTUnwrap(presentedMenu, "Invitation control must present its native menu")
            XCTAssertTrue(menuTree(menu).contains { $0.title == expectedAction })
            if index == 0 {
                XCTAssertTrue(menuTree(menu).contains { $0.title == "恢复员工默认设置" }, "The default companion must resolve to an employee")
                XCTAssertTrue(menuTree(menu).contains { $0.title == "直接使用执行工具" }, "Choosing a bare tool remains an explicit action")
            }
            try await Task.sleep(for: .milliseconds(1000))
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: evidence.appendingPathComponent("menu-\(index).png"))
            if FileManager.default.fileExists(atPath: "/tmp/wand-new-work-menu-capture-enabled") {
                let checkpoint = "/tmp/wand-new-work-menu-capture-ready"
                try String(index).write(toFile: checkpoint, atomically: true, encoding: .utf8)
                let deadline = Date().addingTimeInterval(10)
                while FileManager.default.fileExists(atPath: checkpoint) && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint), "Capture the native menu before dismissal")
                try? FileManager.default.removeItem(atPath: checkpoint)
            }
            control.contextMenuInteraction?.dismissMenu()
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(draft.text, "等待发送的验收草稿（不执行）")
            XCTAssertEqual(draft.attachments.stagedAttachmentCount, 5)
            XCTAssertTrue(editors(host.view).first === originalEditor)
        }
        let sizes: [(String, CGFloat, CGFloat)] = [
            ("outer-portrait", 466, 678), ("outer-landscape", 678, 466),
            ("inner-portrait", 669, 951), ("inner-landscape", 951, 669), ("narrow-phone", 390, 800)
        ]
        for (index, entry) in sizes.enumerated() {
            let (name, width, height) = entry
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.overrideUserInterfaceStyle = index.isMultiple(of: 2) ? .light : .dark
            host.traitOverrides.verticalSizeClass = width > height ? .compact : .regular
            host.view.setNeedsLayout()
            try await Task.sleep(for: .milliseconds(180))
            host.view.layoutIfNeeded()
            XCTAssertEqual(host.view.bounds.width, width, accuracy: 0.5)
            XCTAssertEqual(host.view.bounds.height, height, accuracy: 0.5)
            let fields = editors(host.view)
            XCTAssertEqual(fields.count, 1)
            XCTAssertTrue(fields.first === originalEditor, "Size changes must preserve the native editing node")
            XCTAssertEqual(fields.first?.text, draft.text)
            XCTAssertEqual(draft.attachments.stagedAttachmentCount, 5)
            XCTAssertNil(host.presentedViewController, "Opening a pending detail must not present a settings form")
            let frame = originalEditor.convert(originalEditor.bounds, to: host.view)
            XCTAssertGreaterThan(frame.width, 180)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, host.view.bounds.width + 1)
            XCTAssertLessThanOrEqual(frame.maxY, host.view.bounds.height + 1)
            try capture("edited-" + name)
        }
    }

    @MainActor
    func testMultipleStagedAttachmentsUseBoundedChatLaneAtAllDuoSizes() {
        let attachments = (1...5).map { StagedComposerAttachment(name: "需要保留完整名称的验收附件-\($0).txt") }
        for size in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466),
                     CGSize(width: 669, height: 951), CGSize(width: 951, height: 669)] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                let host = UIHostingController(rootView: StagedAttachmentsPreview(attachments: attachments) { _ in }
                    .environment(\.dynamicTypeSize, typeSize))
                let measured = host.sizeThatFits(in: size)
                XCTAssertGreaterThanOrEqual(measured.height, 44)
                XCTAssertLessThanOrEqual(measured.height, 76)
                XCTAssertLessThanOrEqual(measured.width, size.width)
            }
        }
    }

    @MainActor
    func testSharedDetailKeepsDockAnchoredWhenOptionsExpandAndKeyboardLifts() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width in [CGFloat(320), 390, 768] {
            for reduced in [false, true] {
                let state = PendingDetailLayoutProbe()
                let host = UIHostingController(rootView: PendingDetailLayoutFixture(state: state)
                    .transaction { $0.disablesAnimations = reduced })
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                window.rootViewController = host; window.makeKeyAndVisible()
                defer { window.isHidden = true; window.rootViewController = nil }
                try await Task.sleep(for: .milliseconds(100))
                func dock(_ view: UIView) -> UIView? {
                    if view.accessibilityIdentifier == "pending-detail-dock" { return view }
                    return view.subviews.lazy.compactMap(dock).first
                }
                let marker = try XCTUnwrap(dock(host.view))
                let before = marker.convert(marker.bounds, to: host.view)
                state.expanded = true
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
                let expanded = marker.convert(marker.bounds, to: host.view)
                XCTAssertEqual(before.minY, expanded.minY, accuracy: 1)
                XCTAssertEqual(before.width, expanded.width, accuracy: 1)
                state.lift = 180
                try await Task.sleep(for: .milliseconds(100))
                host.view.layoutIfNeeded()
                let lifted = marker.convert(marker.bounds, to: host.view)
                XCTAssertEqual(before.minY - lifted.minY, 180, accuracy: 1)
                XCTAssertGreaterThan(lifted.minY, host.view.safeAreaInsets.top)
            }
        }
    }

    func testAcceptedTaskContinuationWaitsForConfigurationButSessionHandoffDoesNot() {
        XCTAssertFalse(NewConversationView.canResumeCreation(creating: false, hasAcceptedSession: false,
                                                             hasAcceptedTask: true, configurationReady: false))
        XCTAssertTrue(NewConversationView.canResumeCreation(creating: false, hasAcceptedSession: false,
                                                            hasAcceptedTask: true, configurationReady: true))
        XCTAssertTrue(NewConversationView.canResumeCreation(creating: false, hasAcceptedSession: true,
                                                            hasAcceptedTask: true, configurationReady: false))
        XCTAssertFalse(NewConversationView.canResumeCreation(creating: true, hasAcceptedSession: true,
                                                             hasAcceptedTask: true, configurationReady: true))
        XCTAssertFalse(NewConversationView.canResumeCreation(creating: false, hasAcceptedSession: false,
                                                             hasAcceptedTask: false, configurationReady: true))
    }

    @MainActor
    func testUnknownCreateCannotBeRetried() async {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        var attempts = 0

        let first = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            throw WandAPI.APIError.network("timeout")
        }
        let second = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            throw WandAPI.APIError.network("retry")
        }

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(coordinator.canSubmit)
        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("Expected unknown delivery") }
    }

    @MainActor
    func testUnknownCreateRemainsLockedAcrossCoordinatorRecreationAndManualCheck() async {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let key = "wand.new-conversation.unknown.test"
        let coordinator = NewConversationCoordinator(storageKey: key, defaults: defaults)
        var attempts = 0

        _ = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            throw WandAPI.APIError.network("timeout")
        }
        let reopened = NewConversationCoordinator(storageKey: key, defaults: defaults)
        XCTAssertFalse(reopened.canSubmit)
        reopened.acknowledgeDeliveryUnknown(confirmedChecked: false)
        reopened.acknowledgeDeliveryUnknown(confirmedChecked: true)
        let retry = await reopened.create {
            attempts += 1
            return try self.decodeSnapshot(id: "confirmed-retry-\(UUID().uuidString)")
        }

        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 1)
        if case .deliveryUnknown = reopened.phase { } else { XCTFail("Unknown delivery must stay locked") }
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testDefiniteRejectionClearsPersistedInflightMarker() async throws {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for task in [false, true] {
            let key = "rejected-\(task)"
            let coordinator = NewConversationCoordinator(storageKey: key, defaults: defaults)
            if task {
                _ = await coordinator.createTask {
                    throw WandAPI.APIError.server(status: 400, message: "rejected")
                }
            } else {
                _ = await coordinator.create {
                    throw WandAPI.APIError.server(status: 400, message: "rejected")
                }
            }
            let restored = NewConversationCoordinator(storageKey: key, defaults: defaults)
            XCTAssertTrue(restored.canSubmit)
            let snapshot = try decodeSnapshot(id: UUID().uuidString)
            let accepted = await restored.create { snapshot }
            XCTAssertEqual(accepted?.id, snapshot.id)
        }
    }

    @MainActor
    func testAcceptedCreateCanAdoptOnlyIntoEmptyDraftForAcceptedSession() async throws {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = try decodeSnapshot(id: "new-conversation-\(UUID().uuidString)")
        let accepted = await coordinator.create { snapshot }
        XCTAssertEqual(accepted?.id, snapshot.id)

        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:8477")!, token: nil)
        let draft = SessionDraftStore.shared.draft(sessionId: snapshot.id, api: api)
        XCTAssertEqual(coordinator.adopt("first message", targetSessionID: snapshot.id, into: draft), .adopted)
        XCTAssertEqual(draft.text, "first message")
        XCTAssertEqual(coordinator.adopt("other", targetSessionID: "another-session", into: draft), .targetAlreadyHasContent)

        draft.requestInitialSend()
        XCTAssertTrue(draft.claimInitialSend())
        XCTAssertFalse(draft.claimInitialSend())
        draft.finishInitialSend()
        XCTAssertFalse(draft.claimInitialSend())
        SessionDraftStore.shared.remove(sessionId: snapshot.id, api: api)
    }

    @MainActor
    func testPtyInitialDraftIsClaimedOnceAndUsesExistingTwoPacketSubmission() async throws {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let draft = ComposerDraftState(sessionId: "pty-initial", api: api, defaults: defaults)
        XCTAssertTrue(draft.adoptInitialDraft(text: "first message", expectedSourceRevision: 0, expectedText: "first message"))
        draft.requestInitialSend()
        XCTAssertFalse(draft.claimInitialSend(when: false))
        XCTAssertFalse(draft.claimInitialSend(when: false))
        XCTAssertTrue(draft.claimInitialSend(when: true))
        XCTAssertFalse(draft.claimInitialSend(when: true))
        let submission = draft.submission()
        draft.submitted(submission)
        var chunks: [PtyInputChunk] = []
        try await sendPtySubmission(ptyInputSubmission(text: submission.prompt, view: "terminal")) { chunks.append($0) }
        draft.accepted(submission)
        draft.finishInitialSend()
        XCTAssertEqual(chunks.map(\.input), ["first message", "\r"])
        XCTAssertEqual(chunks.last?.shortcutKey, "enter_text")
        XCTAssertTrue(draft.text.isEmpty)
        XCTAssertFalse(draft.claimInitialSend())

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Wand/SessionDestinationView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("composerDraft.claimInitialSend(when: canSend)"))
        XCTAssertTrue(source.contains("if ready { sendPendingInitialMessage() }"))
        XCTAssertTrue(source.contains("if !loading { sendPendingInitialMessage() }"))
        XCTAssertTrue(source.contains("store.sendPtyTerminalInput(submission.prompt)"))
    }

    @MainActor
    func testAdoptionPreservesExistingTargetDraft() async throws {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = try decodeSnapshot(id: "existing-target-\(UUID().uuidString)")
        _ = await coordinator.create { snapshot }
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:8478")!, token: nil)
        let draft = SessionDraftStore.shared.draft(sessionId: snapshot.id, api: api)
        draft.text = "existing"

        XCTAssertEqual(coordinator.adopt("new", targetSessionID: snapshot.id, into: draft), .targetAlreadyHasContent)
        XCTAssertEqual(draft.text, "existing")
        SessionDraftStore.shared.remove(sessionId: snapshot.id, api: api)
    }

    @MainActor
    func testUnknownSessionWithTaskIDCannotBeRetried() async {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        coordinator.markTaskAccepted("accepted-task")
        var attempts = 0

        let first = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            throw UnknownSessionDeliveryError(sessionID: "uncertain-session", cause: WandAPI.APIError.network("timeout"))
        }
        let retry = await coordinator.create { () async throws -> SessionSnapshot in
            attempts += 1
            return try self.decodeSnapshot(id: "duplicate")
        }

        XCTAssertNil(first)
        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(coordinator.unknownSessionID, "uncertain-session")
        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("Expected unknown delivery") }
    }

    @MainActor
    func testUnknownSessionWithTaskIDCannotBeAcknowledgedIntoRetry() async {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        coordinator.markTaskAccepted("accepted-task")
        _ = await coordinator.create { () async throws -> SessionSnapshot in
            throw UnknownSessionDeliveryError(sessionID: "uncertain-session", cause: WandAPI.APIError.network("timeout"))
        }

        coordinator.acknowledgeDeliveryUnknown(confirmedChecked: true)
        var attempts = 0
        let retry = await coordinator.create {
            attempts += 1
            return try self.decodeSnapshot(id: "duplicate")
        }

        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(coordinator.unknownOperation, .session)
        XCTAssertEqual(coordinator.unknownSessionID, "uncertain-session")
        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("Unknown session delivery must stay locked") }
    }

    @MainActor
    func testAbandonAcceptedSessionKeepsSessionAccepted() async throws {
        let (coordinator, defaults, suite) = makeCoordinator()
        defer { defaults.removePersistentDomain(forName: suite) }
        coordinator.markTaskAccepted("accepted-task")
        let accepted = try decodeSnapshot(id: "accepted-once")
        _ = await coordinator.create { accepted }

        coordinator.abandonAcceptedSession(sessionID: accepted.id)

        XCTAssertEqual(coordinator.phase, .accepted(sessionID: accepted.id, taskID: "accepted-task"))
        let reopened = NewConversationCoordinator(storageKey: "wand.new-conversation.unknown.test", defaults: defaults)
        XCTAssertEqual(reopened.phase, .accepted(sessionID: accepted.id, taskID: "accepted-task"))
        var attempts = 0
        let duplicate = await reopened.create {
            attempts += 1
            return try self.decodeSnapshot(id: "duplicate")
        }

        XCTAssertNil(duplicate)
        XCTAssertEqual(attempts, 0)
    }

    @MainActor
    func testTaskCreationPersistsUnknownBeforeOperationAndBlocksAfterRecreation() async {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "wand.new-conversation.in-flight.task"
        let coordinator = NewConversationCoordinator(storageKey: key, defaults: defaults)
        let started = expectation(description: "task operation started")
        var attempts = 0
        var resumeOperation: CheckedContinuation<String, Error>?

        let creation = Task { @MainActor in
            await coordinator.createTask(requestID: "task-request") {
                attempts += 1
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation in
                    resumeOperation = continuation
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)

        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("In-flight task must be represented as unknown") }
        let saved = defaults.dictionary(forKey: key)
        XCTAssertEqual(saved?["phase"] as? String, "deliveryUnknown")
        XCTAssertEqual(saved?["operation"] as? String, "task")
        XCTAssertEqual(saved?["requestID"] as? String, "task-request")
        let reopened = NewConversationCoordinator(storageKey: key, defaults: defaults)
        let retry = await reopened.createTask {
            attempts += 1
            return "duplicate-task"
        }
        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 1)

        resumeOperation?.resume(throwing: WandAPI.APIError.network("closed"))
        _ = await creation.value
    }

    @MainActor
    func testSessionCreationPersistsUnknownBeforeOperationAndBlocksAfterRecreation() async throws {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "wand.new-conversation.in-flight.session"
        let coordinator = NewConversationCoordinator(storageKey: key, defaults: defaults)
        let started = expectation(description: "session operation started")
        var attempts = 0
        var resumeOperation: CheckedContinuation<SessionSnapshot, Error>?

        let creation = Task { @MainActor in
            await coordinator.create(requestID: "session-request") {
                attempts += 1
                started.fulfill()
                return try await withCheckedThrowingContinuation { continuation in
                    resumeOperation = continuation
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)

        if case .deliveryUnknown = coordinator.phase { } else { XCTFail("In-flight session must be represented as unknown") }
        let saved = defaults.dictionary(forKey: key)
        XCTAssertEqual(saved?["phase"] as? String, "deliveryUnknown")
        XCTAssertEqual(saved?["operation"] as? String, "session")
        XCTAssertEqual(saved?["requestID"] as? String, "session-request")
        let reopened = NewConversationCoordinator(storageKey: key, defaults: defaults)
        let retry = await reopened.create {
            attempts += 1
            return try self.decodeSnapshot(id: "duplicate")
        }
        XCTAssertNil(retry)
        XCTAssertEqual(attempts, 1)

        resumeOperation?.resume(returning: try decodeSnapshot(id: "accepted-after-resume"))
        _ = await creation.value
    }

    @MainActor
    private func makeCoordinator() -> (NewConversationCoordinator, UserDefaults, String) {
        let suite = "NewConversationTests.\(UUID().uuidString)"
        return (NewConversationCoordinator(storageKey: "wand.new-conversation.unknown.test", defaults: UserDefaults(suiteName: suite)!), UserDefaults(suiteName: suite)!, suite)
    }

    private func decodeSnapshot(id: String) throws -> SessionSnapshot {
        let data = Data(#"{"id":"\#(id)","sessionKind":"structured","provider":"claude","selectedModel":null,"thinkingEffort":null,"claudeSessionId":null}"#.utf8)
        return try JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}

@MainActor private final class PendingDetailLayoutProbe: ObservableObject {
    @Published var expanded = false
    @Published var lift: CGFloat = 0
}

private struct PendingDetailDockMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = "pending-detail-dock"
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct PendingDetailLayoutFixture: View {
    @ObservedObject var state: PendingDetailLayoutProbe
    var body: some View {
        ChatDetailLayout(keyboardLift: state.lift) {
            ScrollView {
                if state.expanded {
                    ForEach(0..<30) { index in Text("创建选项 \(index)").frame(minHeight: 44) }
                }
            }
        } composer: {
            PendingDetailDockMarker().frame(height: 64)
        }
    }
}

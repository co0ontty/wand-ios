import XCTest

/// Real touch injection, not a fake recognizer or a screenshot comparison.
@MainActor
final class LiveBackUITests: XCTestCase {
    private func launch(_ mode: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["WAND_DEBUG_LIVE_BACK"] = mode
        app.launchEnvironment["WAND_DEBUG_LIVE_BACK_RUN"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["open-parent"].waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["open-parent"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        return app
    }

    private func drag(_ app: XCUIApplication, commit: Bool, from: String, to: String) {
        app.buttons["reset-proof"].tap()
        let surface = app.windows.firstMatch
        XCTAssertTrue(surface.exists)
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.52))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: commit ? 0.88 : 0.2, dy: 0.52))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 3)
        let proof = app.staticTexts["live-transition-proof"].label
        XCTAssertTrue(proof.contains("from=\(from) to=\(to)"), proof + " " + app.staticTexts["native-diagnostic"].label)
        XCTAssertTrue(proof.contains("updated=1"), "Previous page content must update during the held native transition: " + proof)
        XCTAssertTrue(proof.contains("identity=1"), "UIKit must reuse the original previous controller: " + proof)
        // SwiftUI renders content separately from the coordinator's metadata
        // controller views. The external primary-display capture verifies actual
        // exposure and the changed label; window/container flags are diagnostic.
        XCTAssertTrue(proof.contains("stable=1"), "Business route must not be cleared before an interactive pop commits: " + proof)
        let route = app.staticTexts["native-route-state"]
        let expected = commit ? to : from
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: route)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed, route.label)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "native-\(from)-to-\(to)-\(commit ? "commit" : "cancel")"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func exercise(_ mode: String) {
        let app = launch(mode)
        defer { app.terminate() }
        let scroll = app.scrollViews["live-list-scroll"]
        let firstRow = app.staticTexts["list row 0"]
        for _ in 0..<2 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.75))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !firstRow.exists || !firstRow.isHittable }, object: nil)
            if XCTWaiter.wait(for: [moved], timeout: 3) == .completed { break }
        }
        XCTAssertTrue(!firstRow.exists || !firstRow.isHittable, "The actual list viewport must scroll before opening its child")
        XCTAssertTrue(app.staticTexts["list row 8"].isHittable)
        app.buttons["open-parent"].tap()
        XCTAssertTrue(app.buttons["open-detail"].waitForExistence(timeout: 10))
        app.buttons["open-detail"].tap()
        XCTAssertTrue(app.staticTexts["live-detail-value"].waitForExistence(timeout: 10))
        drag(app, commit: false, from: "detail", to: "parent")
        drag(app, commit: true, from: "detail", to: "parent")
        XCTAssertEqual(app.staticTexts["live-parent-value"].label, "parent revision 2")
        drag(app, commit: false, from: "parent", to: "list")
        drag(app, commit: true, from: "parent", to: "list")
        XCTAssertEqual(app.staticTexts["live-list-value"].label, "list revision 2")
        XCTAssertTrue(!firstRow.exists || !firstRow.isHittable, "Returning must not reset the visible list to row zero")
        XCTAssertTrue(app.staticTexts["list row 8"].isHittable, "The retained viewport must still show the previously visible rows")
    }

    func testInstalledOwnConversationNativeCancelAndReturn() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let profile = environment["WAND_UI_ACCEPTANCE_PROFILE"] ?? environment["TEST_RUNNER_WAND_UI_ACCEPTANCE_PROFILE"],
              let session = environment["WAND_UI_ACCEPTANCE_SESSION"] ?? environment["TEST_RUNNER_WAND_UI_ACCEPTANCE_SESSION"] else {
            throw XCTSkip("Explicit own-session installed-service UI acceptance only")
        }
        continueAfterFailure = false
        let request = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("actual-back-proof").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mode": "profile-stage-request"])
            .write(to: request.appendingPathComponent("profile-request.json"), options: .atomic)
        let ready = request.appendingPathComponent("profile-staged.json")
        let staged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: ready.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 30), .completed, "Private profile must be staged inside the target app's own sandbox")
        _ = profile // Path only; credentials are never put in environment values.
        let app = XCUIApplication()
        app.launchEnvironment["WAND_DEBUG_ACCEPTANCE_PROFILE"] = "1"
        app.launch()
        defer { app.terminate() }
        app.open(URL(string: "wand://session/" + session)!)
        let composer = app.textViews["消息输入"]
        XCTAssertTrue(composer.waitForExistence(timeout: 40), "The real current conversation must finish loading")
        let draft = composer.value as? String
        let evidence = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("actual-back-proof").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        func actualDrag(commit: Bool) throws {
            let name = commit ? "complete" : "cancel"
            let record: [String: Any] = ["mode": "installed", "stage": name, "actualInstalledService": true]
            try JSONSerialization.data(withJSONObject: record).write(to: evidence.appendingPathComponent(name + ".json"), options: .atomic)
            let surface = app.windows.firstMatch
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: commit ? 0.88 : 0.2, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 3)
            try Data("{}".utf8).write(to: evidence.appendingPathComponent(name + ".ended.json"), options: .atomic)
        }
        try actualDrag(commit: false)
        XCTAssertTrue(composer.exists)
        XCTAssertEqual(composer.value as? String, draft, "Cancelling must preserve the real current composer")
        try actualDrag(commit: true)
        let home = app.descendants(matching: .any).matching(identifier: "home-tab-工作区").firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20))
        XCTAssertTrue(home.isHittable, "A completed real-session back must restore home navigation")
    }

    func testMarkdownDownloadTapAndExternalFailureAreVisible() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["WAND_DEBUG_MARKDOWN_LINKS"] = "1"
        app.launch()
        defer { app.terminate() }
        let download = app.links["下载 IPA"]
        XCTAssertTrue(download.waitForExistence(timeout: 20))
        download.tap()
        let failure = app.staticTexts["markdown-download-failure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "Tap must reach the authenticated downloader, not silently disappear")
        XCTAssertEqual(failure.label, "服务器连接已关闭")
        XCTAssertEqual(app.staticTexts["markdown-external-count"].label, "external=0")
        app.links["外部页面"].tap()
        XCTAssertEqual(app.staticTexts["markdown-external-count"].label, "external=1")
        app.links["不可打开"].tap()
        XCTAssertTrue(app.staticTexts["markdown-link-error"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "markdown-link-tap-feedback"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let evidence = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("markdown-link-tap-feedback.png")
        try? app.screenshot().pngRepresentation.write(to: evidence)
    }

    func testInstalledWorkspaceAliasFocusAndCancel() throws {
        guard ProcessInfo.processInfo.environment["WAND_UI_ACCEPTANCE_PROFILE"] != nil
            || ProcessInfo.processInfo.environment["TEST_RUNNER_WAND_UI_ACCEPTANCE_PROFILE"] != nil else {
            throw XCTSkip("Explicit installed-service workspace UI acceptance only")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let picker = app.buttons["工作区筛选"]
        XCTAssertTrue(picker.waitForExistence(timeout: 30), "The actual conversation list must load")
        picker.tap()
        let add = app.buttons["添加工作区"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let alias = app.textFields["路径别名"]
        XCTAssertTrue(alias.waitForExistence(timeout: 10))
        alias.tap()
        alias.typeText("Workspace alias")
        XCTAssertEqual(alias.value as? String, "Workspace alias")
        let directory = app.textFields["工作目录"]
        directory.tap()
        alias.tap()
        XCTAssertEqual(alias.value as? String, "Workspace alias", "Switching focus must preserve the alias")
        app.buttons["取消"].tap()
        XCTAssertFalse(alias.exists)
        picker.tap()
        app.buttons["添加工作区"].tap()
        XCTAssertTrue(alias.waitForExistence(timeout: 10))
        alias.tap()
        alias.typeText("Second alias")
        XCTAssertEqual(alias.value as? String, "Second alias")
        app.buttons["取消"].tap()
    }

    func testInstalledWorkspaceCreationAndFilter() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["TEST_RUNNER_WAND_UI_WORKSPACE_DIRECTORY"]
            ?? environment["WAND_UI_WORKSPACE_DIRECTORY"] else {
            throw XCTSkip("Explicit task-owned workspace directory required")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let picker = app.buttons["工作区筛选"]
        XCTAssertTrue(picker.waitForExistence(timeout: 30))
        picker.tap()
        let wand = app.buttons["wand"]
        XCTAssertTrue(wand.waitForExistence(timeout: 10), "Registered Wand must be a real workspace option")
        wand.tap()
        XCTAssertEqual(wand.value as? String, "已选中")
        picker.tap()
        let assignedRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", " · wand")).firstMatch
        XCTAssertTrue(assignedRow.waitForExistence(timeout: 10), "The actual filtered list must name Wand, not mark bound sessions unassigned")
        picker.tap()
        app.buttons["添加工作区"].tap()
        let alias = app.textFields["路径别名"]
        XCTAssertTrue(alias.waitForExistence(timeout: 10))
        alias.tap()
        let name = "键盘验收-2946-" + UUID().uuidString.prefix(8)
        alias.typeText(name)
        XCTAssertEqual(alias.value as? String, name)
        let directory = app.textFields["工作目录"]
        directory.tap()
        directory.press(forDuration: 1)
        let selectAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["全选", "Select All"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "Use the native selection menu rather than deleting from an arbitrary caret position")
        selectAll.tap()
        directory.typeText(directoryPath)
        XCTAssertEqual(directory.value as? String, directoryPath)
        app.buttons["浏览目录"].tap()
        let browserNavigation = app.navigationBars["选择目录"]
        let cancelBrowser = browserNavigation.buttons["取消"]
        XCTAssertTrue(cancelBrowser.waitForExistence(timeout: 10))
        cancelBrowser.tap()
        let browserClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: browserNavigation)
        XCTAssertEqual(XCTWaiter.wait(for: [browserClosed], timeout: 10), .completed)
        XCTAssertTrue(alias.waitForExistence(timeout: 10))
        XCTAssertEqual(alias.value as? String, name, "Browsing must not discard the alias")
        alias.tap()
        app.buttons["创建工作区"].tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alias)
        let savedResult = XCTWaiter.wait(for: [saved], timeout: 20)
        if savedResult != .completed {
            let failure = XCTAttachment(screenshot: app.screenshot())
            failure.name = "workspace-create-ack-failure"
            failure.lifetime = .keepAlways
            add(failure)
        }
        XCTAssertEqual(savedResult, .completed, "Creation must receive its acknowledgement before the form closes")
        XCTAssertTrue(picker.exists)
        picker.tap()
        XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 20), "Saved workspace must remain selected and selectable")
        XCTAssertEqual(app.buttons[name].value as? String, "已选中")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "workspace-created-and-selected"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDuoRegularLivePagesCancelAndCommit() { exercise("system-regular") }
    func testDuoCompactLivePagesCancelAndCommit() { exercise("system-compact") }
    func testHiddenBarChatUsesNativeLivePages() { exercise("hidden") }
}

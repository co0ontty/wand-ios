import XCTest
import SwiftUI
@testable import Wand

@MainActor
final class AppUpdateTests: XCTestCase {
    private let version = "4.96.0-debug.10162050"
    private let bundleID = "com.example.wand"
    private let manifest = "https://updates.example.test/ios/manifest.plist"

    private func candidate(_ changes: [String: Any] = [:]) throws -> IosIpaUpdateInfo {
        var json: [String: Any] = [
            "updateAvailable": true, "currentVersion": version, "latestVersion": "4.96.0-debug.10162130",
            "bundleId": bundleID, "signed": true, "otaReady": true, "manifestUrl": manifest,
            "installPageUrl": "https://updates.example.test/ios/install",
            "installUrl": "itms-services://?action=download-manifest&url=" + manifest.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
        ]
        json.merge(changes) { _, new in new }
        return try JSONDecoder().decode(IosIpaUpdateInfo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Update owner did not settle", file: file, line: line)
    }

    func testHandoffFeedbackSurvivesSystemPromptAndSafariUsesValidatedOrigin() async throws {
        let info = try candidate()
        var opened: [URL] = []
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in info }, open: { url, complete in
            opened.append(url); complete(true)
        })
        owner.setActive(true)
        await settle { owner.info != nil }
        owner.install()
        XCTAssertNotNil(owner.handoffMessage)
        owner.setActive(false)
        XCTAssertNotNil(owner.handoffMessage)
        owner.setActive(true)
        await settle { !owner.checking }
        owner.openInstallPage()
        XCTAssertEqual(opened.map(\.scheme), ["https", "https"])
        XCTAssertEqual(opened.last?.path, "/ios/install")
        owner.setActive(false)
        // Without a validated install page the flow must still reach the system installer directly.
        let pageless = try candidate(["installPageUrl": "http://updates.example.test/ios/install"])
        var fallbackOpened: [URL] = []
        let fallback = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in pageless }, open: { url, complete in
            fallbackOpened.append(url); complete(true)
        })
        fallback.setActive(true)
        await settle { fallback.info != nil }
        fallback.install()
        XCTAssertEqual(fallbackOpened.map(\.scheme), ["itms-services"])
        fallback.setActive(false)
        for page in ["http://updates.example.test/ios/install", "https://foreign.test/ios/install", "https://user@updates.example.test/ios/install", "https://updates.example.test/ios/install?token=bad"] {
            let invalid = try candidate(["installPageUrl": page])
            let rejected = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in invalid })
            rejected.setActive(true)
            await settle { rejected.info != nil }
            XCTAssertNil(rejected.installPageURL)
            rejected.setActive(false)
        }
    }

    func testMissingSystemCompletionUnlocksRetryAndLateCompletionIsIgnored() async throws {
        let info = try candidate()
        var callback: ((Bool) -> Void)?
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, handoffTimeout: 1_000_000,
            fetch: { _ in info }, open: { _, complete in callback = complete })
        owner.setActive(true)
        await settle { owner.info != nil }
        owner.install()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(owner.opening)
        XCTAssertNotNil(owner.error)
        callback?(true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNotNil(owner.error)
        owner.setActive(false)
    }

    func testUpdateButtonsInNativeBanner() async throws {
        guard ProcessInfo.processInfo.environment["WAND_UPDATE_TOUCH_TEST"] == "1" else {
            throw XCTSkip("Requires isolated simulator touch driver")
        }
        let info = try candidate()
        var urls: [URL] = []
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in info }, open: { url, complete in
            urls.append(url); complete(url.scheme == "https")
        })
        owner.setActive(true)
        await settle { owner.info != nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: VStack {
            AppUpdateBanner(updater: owner)
            Spacer()
        }.background(Theme.background))
        window.makeKeyAndVisible()
        defer { owner.setActive(false); window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<90 {
            try await Task.sleep(for: .seconds(1))
            if urls.count == 2 {
                XCTAssertEqual(urls.map(\.scheme), ["https", "https"])
                XCTAssertNotNil(owner.handoffMessage)
                XCTAssertNil(owner.error)
                return
            }
        }
        XCTFail("Native install and Safari recovery buttons did not invoke their actions")
    }

    func testAuthenticationAndForegroundTriggerAutomaticChecks() async throws {
        let info = try candidate()
        var calls = 0
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { current in
            XCTAssertEqual(current, self.version); calls += 1; return info
        })
        owner.setActive(true)
        await settle { owner.promptVersion != nil }
        XCTAssertEqual(calls, 1)
        owner.setActive(true)
        await Task.yield()
        XCTAssertEqual(calls, 1)
        owner.setActive(false)
        owner.setActive(true)
        await settle { calls == 2 && !owner.checking }
        owner.setActive(false)
    }

    func testPollingRunsOnlyWhileActive() async throws {
        let info = try candidate()
        let checked = expectation(description: "foreground polling")
        checked.expectedFulfillmentCount = 2
        var calls = 0
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, interval: 1_000_000, fetch: { _ in
            calls += 1; if calls <= 2 { checked.fulfill() }; return info
        })
        owner.setActive(true)
        await fulfillment(of: [checked], timeout: 2)
        owner.setActive(false)
        let stopped = calls
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(calls, stopped)
    }

    func testUnsignedForeignIdentitySameVersionAndUnsafeInstallerNeverPrompt() async throws {
        let variants: [[String: Any]] = [
            ["signed": false], ["otaReady": false], ["bundleId": "com.someone.else"],
            ["latestVersion": version], ["updateAvailable": false],
            ["installUrl": "https://updates.example.test/ios/install"],
            ["installUrl": "itms-services://?action=download-manifest&url=http%3A%2F%2Fupdates.example.test%2Fios%2Fmanifest.plist"],
            ["manifestUrl": "https://another.example.test/manifest.plist"],
        ]
        for change in variants {
            let info = try candidate(change)
            var opened = false
            let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in info }, open: { _, _ in opened = true })
            owner.setActive(true)
            await settle { owner.info != nil }
            XCTAssertNil(owner.promptVersion, "\(change)")
            owner.install()
            XCTAssertFalse(opened)
            owner.setActive(false)
        }
    }

    func testLateCheckCannotResurrectAfterDisconnect() async throws {
        let info = try candidate()
        var continuation: CheckedContinuation<IosIpaUpdateInfo, Never>?
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in
            await withCheckedContinuation { continuation = $0 }
        })
        owner.setActive(true)
        await settle { continuation != nil }
        owner.setActive(false)
        continuation?.resume(returning: info)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(owner.info)
        XCTAssertFalse(owner.checking)
    }

    func testDismissDoesNotSuppressNewVersionsAndManualCheckCanRestorePrompt() async throws {
        var info = try candidate()
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in info })
        owner.setActive(true)
        await settle { owner.promptVersion != nil }
        owner.dismissPrompt()
        XCTAssertNil(owner.promptVersion)
        await owner.check()
        XCTAssertNil(owner.promptVersion)
        await owner.check(manual: true)
        XCTAssertNotNil(owner.promptVersion)
        owner.dismissPrompt()
        info = try candidate(["latestVersion": "4.96.0-debug.10162131"])
        await owner.check()
        XCTAssertEqual(owner.promptVersion, "4.96.0-debug.10162131")
        owner.setActive(false)
    }

    func testHandoffFailureIsRetryableAndDoubleTapDoesNotOpenTwice() async throws {
        let info = try candidate()
        var callback: ((Bool) -> Void)?
        var calls = 0
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in info }, open: { url, completion in
            XCTAssertEqual(url.scheme, "https"); XCTAssertEqual(url.path, "/ios/install"); calls += 1; callback = completion
        })
        owner.setActive(true)
        await settle { owner.promptVersion != nil }
        owner.install(); owner.install()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(owner.opening)
        callback?(false)
        await settle { !owner.opening }
        XCTAssertNotNil(owner.error)
        owner.install()
        XCTAssertEqual(calls, 2)
        callback?(true)
        await settle { !owner.opening }
        XCTAssertNil(owner.error)
        XCTAssertNotNil(owner.info) // Handoff is not proof of installation; a cancelled install can be retried.
        owner.setActive(false)
    }

    func testLateInstallerCallbackCannotMutateNewForeground() async throws {
        let info = try candidate()
        var callback: ((Bool) -> Void)?
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in info }, open: { _, completion in callback = completion })
        owner.setActive(true)
        await settle { owner.promptVersion != nil }
        owner.install()
        owner.setActive(false); owner.setActive(true)
        callback?(false)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(owner.error)
        owner.setActive(false)
    }

    func testInstalledServerUpdateUsesProductionAPIAndOnlyOffersInstallPageHandoff() async throws {
        let pointer = URL(fileURLWithPath: "/tmp/wand-ios-update-acceptance-profile-path")
        guard let path = ProcessInfo.processInfo.environment["WAND_IOS_UPDATE_ACCEPTANCE_PROFILE"]
            ?? (try? String(contentsOf: pointer, encoding: .utf8)) else {
            throw XCTSkip("Requires an explicit private installed-service acceptance profile")
        }
        struct Acceptance: Decodable { let serverURL: String; let bundleID: String; let previousVersion: String; let expectedVersion: String? }
        let acceptance = try JSONDecoder().decode(Acceptance.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let api = WandAPI(baseURL: URL(string: acceptance.serverURL)!, token: nil)
        var installerURL: URL?
        let owner = AppUpdateController(currentVersion: acceptance.previousVersion, bundleID: acceptance.bundleID,
            fetch: { try await api.iosIpaUpdate(currentVersion: $0) }, open: { url, complete in installerURL = url; complete(true) })
        owner.setActive(true)
        // The live network is asynchronous; wait for a bounded real response without polling the server.
        for _ in 0..<100 {
            if owner.info != nil || owner.error != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(owner.error)
        XCTAssertNotNil(owner.promptVersion)
        if let expected = acceptance.expectedVersion { XCTAssertEqual(owner.promptVersion, expected) }
        owner.install()
        XCTAssertEqual(installerURL?.scheme, "https")
        XCTAssertEqual(installerURL?.path, "/ios/install")
        owner.setActive(false)
    }

    func testNativeBannerRendersPhoneDarkAndLargeTypeWithoutInstallerSideEffects() async throws {
        let info = try candidate()
        var calls = 0
        let owner = AppUpdateController(currentVersion: version, bundleID: bundleID, fetch: { _ in info }, open: { _, _ in calls += 1 })
        owner.setActive(true)
        await settle { owner.promptVersion != nil }
        for (name, width, scheme, size) in [("phone", 390.0, ColorScheme.light, ContentSizeCategory.large),
                                          ("narrow-dark-large", 320.0, .dark, .accessibilityExtraExtraLarge)] {
            let view = AppUpdateBanner(updater: owner).environment(\.colorScheme, scheme).environment(\.sizeCategory, size)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 600))
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.backgroundColor = UIColor(Theme.background)
            host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
            XCTAssertGreaterThan(Set(pixels).count, 20, "A blank hosting view is not UI evidence")
            let attachment = XCTAttachment(image: image)
            attachment.name = "app-update-" + name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
            window.rootViewController = nil
        }
        XCTAssertEqual(calls, 0)
        owner.setActive(false)
    }
}

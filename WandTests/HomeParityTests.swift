import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import Wand

final class HomeParityTests: XCTestCase {
    @MainActor
    func testSystemNavigationKeepsTheSameRealListAndParentControllers() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = AdaptiveNavigationFixtureState()
        let host = UIHostingController(rootView: AdaptiveNavigationFixture(state: state, systemNavigation: true))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        func settled(_ depth: Int) async throws -> UINavigationController {
            for _ in 0..<80 {
                host.view.layoutIfNeeded()
                if let nav = homeNavigationControllers(host).compactMap({ $0 as? UINavigationController }).first,
                   nav.viewControllers.count == depth, nav.transitionCoordinator == nil { return nav }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "NativeNavigationAcceptance", code: 1)
        }
        let nav = try await settled(1)
        let root = try XCTUnwrap(nav.topViewController)
        state.parents = ["parent"]
        _ = try await settled(2)
        let parent = try XCTUnwrap(nav.topViewController)
        state.selection = "session"
        _ = try await settled(3)
        XCTAssertTrue(nav.viewControllers[0] === root)
        XCTAssertTrue(nav.viewControllers[1] === parent)
        let draft = state.draft
        nav.popViewController(animated: false)
        _ = try await settled(2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.selection); XCTAssertEqual(state.parents, ["parent"])
        XCTAssertTrue(nav.topViewController === parent)
        nav.popViewController(animated: false)
        _ = try await settled(1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(state.selection); XCTAssertTrue(state.parents.isEmpty)
        XCTAssertTrue(nav.topViewController === root)
        XCTAssertEqual(state.draft, draft)
        XCTAssertFalse(homeNavigationControllers(host).contains { $0 is UISplitViewController },
            "A one-page-at-a-time Duo flow must not unmount its list in another split column")
    }

    @MainActor
    func testHiddenBarBridgeUsesAndRestoresTheExistingUIKitGesture() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.setNavigationBarHidden(true, animated: false)
        let gesture = try XCTUnwrap(nav.interactivePopGestureRecognizer)
        let originalDelegate = gesture.delegate
        let originalNavigationDelegate = nav.delegate
        let page = UIViewController()
        let bridge = SessionBackSwipeController()
        page.addChild(bridge); page.view.addSubview(bridge.view); bridge.didMove(toParent: page)
        nav.pushViewController(page, animated: false)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = nav; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(300))
        bridge.installNativeGesture()
        XCTAssertTrue(nav.interactivePopGestureRecognizer === gesture)
        XCTAssertTrue(gesture.delegate === bridge)
        XCTAssertTrue(gesture.isEnabled)
        XCTAssertTrue(nav.delegate === originalNavigationDelegate, "SwiftUI/UIKit still own native routing callbacks")
        XCTAssertTrue(bridge.gestureRecognizerShouldBegin(gesture))
        bridge.releaseAfterTransition()
        XCTAssertTrue(gesture.delegate === originalDelegate)
        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.view.subviews.compactMap { $0 as? UIImageView }.isEmpty)
    }

    @MainActor
    func testSystemNavigationRetainsLiveStackAcrossFourSizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = AdaptiveNavigationFixtureState()
        let host = UIHostingController(rootView: AdaptiveNavigationFixture(state: state, systemNavigation: true))
        host.safeAreaRegions = []
        let container = UIViewController()
        container.addChild(host); container.view.addSubview(host.view); host.didMove(toParent: container)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let draft = state.draft
        var originalNav: UINavigationController?
        var originalRoot: UIViewController?
        let sizes: [(CGFloat, CGFloat, UIUserInterfaceSizeClass, UIUserInterfaceSizeClass)] = [
            (669, 951, .regular, .regular), (951, 669, .regular, .regular),
            (466, 678, .compact, .regular), (678, 466, .compact, .compact)
        ]
        for phase in 0..<5 {
            switch phase {
            case 1: state.parents = ["parent"]
            case 2: state.selection = "session"
            case 3: try XCTUnwrap(state.back)()
            case 4: try XCTUnwrap(state.back)()
            default: break
            }
            let expected = state.selection ?? state.parents.last
            for (width, height, horizontal, vertical) in sizes {
                host.traitOverrides.horizontalSizeClass = horizontal
                host.traitOverrides.verticalSizeClass = vertical
                host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                var stable = 0
                for _ in 0..<80 {
                    host.view.layoutIfNeeded()
                    let nav = homeNavigationControllers(host).compactMap { $0 as? UINavigationController }.first
                    let depth = contactNavigationPath(parents: state.parents, selection: state.selection).count + 1
                    let id = expected.map { "adaptive-detail-" + $0 } ?? "adaptive-sidebar"
                    let visible = nav?.topViewController?.viewIfLoaded.flatMap { homeNavigationMarker(id, in: $0) } != nil
                    stable = visible && nav?.viewControllers.count == depth && nav?.transitionCoordinator == nil ? stable + 1 : 0
                    if stable >= 3 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertGreaterThanOrEqual(stable, 3, "Native stack must settle for phase \(phase), \(width)x\(height)")
                let nav = try XCTUnwrap(homeNavigationControllers(host).compactMap { $0 as? UINavigationController }.first)
                if let originalNav { XCTAssertTrue(nav === originalNav) } else { originalNav = nav }
                if let originalRoot { XCTAssertTrue(nav.viewControllers.first === originalRoot) }
                else { originalRoot = nav.viewControllers.first }
                XCTAssertEqual(host.view.bounds.size, CGSize(width: width, height: height))
                XCTAssertEqual(state.draft, draft)
            }
        }
        XCTAssertNil(state.selection); XCTAssertTrue(state.parents.isEmpty)
    }

    @MainActor
    func testWideAdaptiveNavigationColdStartShowsTheSidebarWithoutASelection() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Run the ordinary wide-layout control on an iPad; forcing the non-system path on Duo retains its native reserved toolbar regions")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = AdaptiveNavigationFixtureState()
        let host = UIHostingController(rootView: AdaptiveNavigationFixture(state: state, systemNavigation: false))
        host.safeAreaRegions = []
        host.traitOverrides.horizontalSizeClass = .regular
        host.traitOverrides.verticalSizeClass = .regular
        let container = UIViewController()
        container.addChild(host); container.view.addSubview(host.view); host.didMove(toParent: container)
        host.view.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(700))
        var settled = 0
        for _ in 0..<60 {
            host.view.layoutIfNeeded()
            let visible = homeNavigationMarker("adaptive-sidebar", in: host.view).map {
                let frame = homeEffectiveVisibleFrame($0, in: host.view)
                return !frame.isNull && frame.width >= 160 && frame.height >= 44
            } ?? false
            let transitioning = homeNavigationControllers(host).contains { $0.transitionCoordinator != nil }
            settled = visible && !transitioning ? settled + 1 : 0
            if settled >= 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(settled, 3, "The actual wide sidebar must be visible after native presentation settles")
        XCTAssertEqual(host.view.bounds.size, CGSize(width: 669, height: 951))
        let split = try XCTUnwrap(homeNavigationControllers(host).compactMap { $0 as? UISplitViewController }.first)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let capture = XCTAttachment(image: image)
        capture.name = "adaptive-native-wide-cold-home"; capture.lifetime = .keepAlways; add(capture)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-adaptive-native-wide-cold-home.png"))
        let observation: [String: Any] = ["width": host.view.bounds.width, "height": host.view.bounds.height,
            "collapsed": split.isCollapsed, "displayMode": split.displayMode.rawValue,
            "preferredDisplayMode": split.preferredDisplayMode.rawValue, "settled": settled]
        try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "/tmp/wand-adaptive-native-wide-cold-home.json"))
        XCTAssertFalse(split.isCollapsed)
        XCTAssertNotEqual(split.displayMode, .secondaryOnly)
        let marker = try XCTUnwrap(homeNavigationMarker("adaptive-sidebar", in: host.view))
        let visible = homeEffectiveVisibleFrame(marker, in: host.view)
        XCTAssertGreaterThanOrEqual(visible.width, 160)
        XCTAssertGreaterThanOrEqual(visible.height, 44)
        let primary = try XCTUnwrap(split.viewController(for: .primary))
        let hit = host.view.hitTest(CGPoint(x: visible.midX, y: visible.midY), with: nil)
        XCTAssertTrue(hit.map { $0 === primary.view || $0.isDescendant(of: primary.view) } ?? false)
        XCTAssertNil(state.selection); XCTAssertTrue(state.parents.isEmpty)
    }

    @MainActor
    func testInstalledRootNavigationHidesOnlyWhileDetailsAreOpen() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WAND_TEST_ROOT_ACCEPTANCE_PATH"] ?? environment["TEST_RUNNER_WAND_TEST_ROOT_ACCEPTANCE_PATH"],
              let sessionID = environment["WAND_TEST_ROOT_ACCEPTANCE_SESSION"] ?? environment["TEST_RUNNER_WAND_TEST_ROOT_ACCEPTANCE_SESSION"],
              !sessionID.isEmpty else {
            throw XCTSkip("Installed root acceptance requires per-run private connection path and explicit own-session ID")
        }
        let quickActions = QuickActionCoordinator.shared
        guard quickActions.pending == nil else {
            throw XCTSkip("Do not replace a pre-existing quick action")
        }
        struct Connection: Decodable { let connectionCode: String }
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let target = try XCTUnwrap(WandAuth.decodeConnectCode(connection.connectionCode))
        XCTAssertFalse(sessionID.isEmpty)
        let profile = ServerProfile(id: ServerProfiles.stableID(for: target.url), baseURL: target.url,
            token: target.token, customName: "本机验收服务")
        let api = WandAPI(baseURL: target.url, token: target.token)
        // Await actual server reads before driving the real root; opening any of
        // these screens must not submit a message or create a task.
        _ = try await api.serverConfig()
        let session = try await api.getSession(id: sessionID)
        guard session.isStructured else { throw XCTSkip("Root chat acceptance requires an existing structured session") }

        let suite = "RootNavigationAcceptance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HomeListMode.sessions.rawValue, forKey: HomeListMode.storageKey)
        let store = ServerStore(defaults: defaults)
        _ = try XCTUnwrap(store.saveProfile(serverURL: profile.baseURL, token: profile.token))
        XCTAssertTrue(store.activeServerID == profile.id &&
            store.activeProfile?.connectionIdentity == profile.connectionIdentity,
            "The isolated store must own the root's active endpoint")
        store.liveActivityEnabled = false; store.notificationsEnabled = false
        let previousShortcuts = UIApplication.shared.shortcutItems
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: NativeRootView(profile: profile)
            .environmentObject(store).defaultAppStorage(defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        var ownedQuickAction: QuickAction?
        defer {
            if let ownedQuickAction { _ = quickActions.consume(where: { $0 == ownedQuickAction }) }
            window.isHidden = true; window.rootViewController = nil
            UIApplication.shared.shortcutItems = previousShortcuts
        }

        func tabs() -> SystemHomeTabController? {
            homeNavigationControllers(host).compactMap { $0 as? SystemHomeTabController }.first
        }
        func waitFor(_ description: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() {
                guard Date() < deadline else {
                    try? screenshot("live-root-timeout")
                    if let controller = tabs() {
                        let flags = Mirror(reflecting: controller).children.filter {
                            ["enabled", "navigationVisible"].contains($0.label ?? "")
                        }.map { ($0.label ?? "") + "=" + String(describing: $0.value) }
                        print("Root navigation timeout: " + flags.joined(separator: ", ") + ", hidden=" + String(controller.isTabBarHidden))
                        print("Visible navigation titles: " + homeNavigationControllers(host).compactMap {
                            ($0 as? UINavigationController)?.topViewController?.navigationItem.title
                        }.joined(separator: ", "))
                    }
                    XCTFail(description)
                    throw NSError(domain: "RootNavigationAcceptance", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: description])
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            host.view.layoutIfNeeded()
        }
        func screenshot(_ name: String) throws {
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let homeCaptures = ["live-root-chats", "live-root-contacts", "live-root-board", "live-root-workspaces"]
            if homeCaptures.contains(name.replacingOccurrences(of: "-dark", with: "")), let controller = tabs() {
                let mode = SystemHomeTabController.modes[controller.selectedIndex]
                let traits = window.traitCollection
                let canvas = UIColor(mode.canvas).resolvedColor(with: traits)
                XCTAssertEqual(controller.view.backgroundColor?.resolvedColor(with: traits), canvas)
                XCTAssertEqual(controller.selectedViewController?.view.backgroundColor?.resolvedColor(with: traits), canvas)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                canvas.getRed(&r, green: &g, blue: &b, alpha: &a)
                let cg = try XCTUnwrap(image.cgImage)
                // Sample bare page edges, not the native glass controls. The
                // canvas must continue above/below content and beside Duo bars.
                for point in [CGPoint(x: 2, y: 100), CGPoint(x: 2, y: window.bounds.height - 2),
                              CGPoint(x: window.bounds.width - 2, y: 100),
                              CGPoint(x: window.bounds.width - 2, y: window.bounds.height - 2)] {
                    let crop = try XCTUnwrap(cg.cropping(to: CGRect(x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1)))
                    var bytes = [UInt8](repeating: 0, count: 4)
                    bytes.withUnsafeMutableBytes { data in
                        let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    }
                    for (actual, expected) in zip(bytes.prefix(3), [r, g, b]) {
                        XCTAssertEqual(CGFloat(actual) / 255, expected, accuracy: 0.025, name + " at " + String(describing: point))
                    }
                }
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/" + name + ".png"))
        }
        func settledScreenshot(_ name: String) async throws {
            // Navigation state and editor mounting can complete before UIKit's
            // push/pop presentation. Keep the actual transition enabled, then
            // capture the settled screen rather than an intermediate frame.
            try await Task.sleep(for: .milliseconds(700))
            try await waitFor("Navigation presentation did not settle before " + name) {
                homeNavigationControllers(host).allSatisfy { $0.transitionCoordinator == nil }
            }
            window.layoutIfNeeded()
            try screenshot(name)
            // drawHierarchy only captures this app window. An explicit external
            // simctl capture can also include Duo's system-composited shared bar.
            if FileManager.default.fileExists(atPath: "/tmp/wand-root-system-capture-enabled") {
                let checkpoint = "/tmp/wand-root-system-capture-ready"
                try name.write(toFile: checkpoint, atomically: true, encoding: .utf8)
                defer { try? FileManager.default.removeItem(atPath: checkpoint) }
                let deadline = Date().addingTimeInterval(10)
                while FileManager.default.fileExists(atPath: checkpoint) && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint),
                    "System screenshot must finish before navigating away from " + name)
            }
        }
        func navigate(_ action: QuickAction) {
            ownedQuickAction = action
            quickActions.enqueue(action)
        }

        try await waitFor("The authenticated root did not become navigable") {
            guard let controller = tabs(), let slots = controller.viewControllers else { return false }
            return slots.count == 4 && slots.allSatisfy { $0.tabBarItem.isEnabled }
        }
        let controller = try XCTUnwrap(tabs())
        let slots = try XCTUnwrap(controller.viewControllers)
        let originalHost = try XCTUnwrap(slots[controller.selectedIndex].children.first)
        XCTAssertEqual(controller.isTabBarHidden, !controller.usesSystemNavigation)
        try await settledScreenshot("live-root-home")

        // Exercise the real root's native list destinations before details.
        // The delegate requests the change; root still owns accepting it.
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            for (mode, title, capture) in [(HomeListMode.im, "聊天", "live-root-chats"),
                                           (.contacts, "通讯录", "live-root-contacts"),
                                           (.board, "任务", "live-root-board"),
                                           (.sessions, "工作区", "live-root-workspaces")] {
                let index = try XCTUnwrap(SystemHomeTabController.modes.firstIndex(of: mode))
                XCTAssertFalse(controller.tabBarController(controller, shouldSelect: slots[index]))
                try await waitFor("The real root did not accept the requested landing destination") {
                    controller.selectedIndex == index
                }
                try await settledScreenshot(capture + (dark ? "-dark" : ""))
                if controller.usesSystemNavigation {
                    let navigations = homeNavigationControllers(host).compactMap { $0 as? UINavigationController }
                    XCTAssertTrue(navigations.contains {
                        !$0.isNavigationBarHidden && $0.visibleViewController?.navigationItem.title == title
                    }, "The landing identity must be published by a visible native navigation bar: " + title)
                }
                XCTAssertEqual(controller.isTabBarHidden, !controller.usesSystemNavigation)
                XCTAssertTrue(slots[index].children.first === originalHost)
                XCTAssertEqual(slots.flatMap(\.children).count, 1)
            }

        }
        window.overrideUserInterfaceStyle = .unspecified

        navigate(.newSession)
        try await waitFor("New-task detail did not hide root navigation") {
            quickActions.pending == nil && controller.isTabBarHidden &&
                slots.allSatisfy { !$0.tabBarItem.isEnabled } &&
                homeNavigationEditors(host.view).contains { $0.accessibilityIdentifier == "pending-conversation-input" }
        }
        XCTAssertTrue(slots[controller.selectedIndex].children.first === originalHost)
        try await settledScreenshot("live-root-new-task")

        navigate(.showSessions)
        try await waitFor("Returning from the draft did not restore root navigation") {
            quickActions.pending == nil && slots.allSatisfy { $0.tabBarItem.isEnabled } &&
                !homeNavigationEditors(host.view).contains { $0.accessibilityIdentifier == "pending-conversation-input" }
        }
        XCTAssertEqual(controller.isTabBarHidden, !controller.usesSystemNavigation)
        XCTAssertTrue(slots[controller.selectedIndex].children.first === originalHost)
        try await settledScreenshot("live-root-returned-home")

        navigate(.openSession(id: sessionID, serverID: profile.id))
        try await waitFor("The existing conversation did not finish opening under hidden root navigation") {
            quickActions.pending == nil && controller.isTabBarHidden &&
                slots.allSatisfy { !$0.tabBarItem.isEnabled } &&
                homeNavigationEditors(host.view).contains { $0.accessibilityIdentifier != "pending-conversation-input" }
        }
        XCTAssertTrue(slots[controller.selectedIndex].children.first === originalHost)
        XCTAssertEqual(slots.flatMap(\.children).count, 1)
        try await settledScreenshot("live-root-session")
        if controller.usesSystemNavigation {
            let navigations = homeNavigationControllers(host).compactMap { $0 as? UINavigationController }
            let items = navigations.compactMap { $0.visibleViewController?.navigationItem }
            XCTAssertFalse(items.isEmpty)
            XCTAssertTrue(items.flatMap(homeStandaloneFileBarItems).isEmpty,
                "Files belong inside the session menu, not in an independent navigation button")
        }

        if controller.usesSystemNavigation {
            let nav = try XCTUnwrap(homeNavigationControllers(host).compactMap { $0 as? UINavigationController }.first {
                $0.viewIfLoaded?.window != nil && $0.viewControllers.count > 1 && $0.transitionCoordinator == nil
            })
            // The touch-driven cancellation/live-view assertions are in XCUITest.
            // This installed-service check invokes the same native stack pop.
            nav.popViewController(animated: true)
        } else {
            navigate(.showSessions)
        }
        try await waitFor("Final return did not release the detail navigation state") {
            quickActions.pending == nil && slots.allSatisfy { $0.tabBarItem.isEnabled }
        }
    }

    @MainActor
    func testFreshNativeBarContextUsesSystemNavigationThroughSizeAndDetailChanges() async throws {
        guard #available(iOS 27.1, *) else { throw XCTSkip("Native vertical-bar and hinge APIs require iOS 27.1") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = SystemHomeTabController()
        var activations = 0
        controller.onSystemNavigation = { activations += 1 }
        let content = AnyView(Text("冷创建系统栏验收：保留同一个导航宿主"))
        var selections: [HomeListMode] = []
        controller.update(content: content, mode: .sessions, enabled: true, navigationVisible: false) { selections.append($0) }
        let registeredHingeObservers = controller.view.interactions.compactMap { $0 as? UIHingeInteraction }.count
        XCTAssertGreaterThanOrEqual(registeredHingeObservers, 1, "Register for UIKit's initial hinge state")
        var observedHinge: UIHinge?
        var hingeCallbacks = 0
        let hingeObserver = UIHingeInteraction { _, update in
            observedHinge = update.hinge
            hingeCallbacks += 1
        }
        controller.view.addInteraction(hingeObserver)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        var samples: [[String: Any]] = []
        func sample(_ phase: String) {
            samples.append([
                "phase": phase,
                "windowEdge": String(describing: window.traitCollection.verticalBarEdge),
                "controllerEdge": String(describing: controller.traitCollection.verticalBarEdge),
                "viewEdge": String(describing: controller.view.traitCollection.verticalBarEdge),
                "windowDivisionCount": window.reservedRegions(kind: .division, options: .includeInactive).count,
                "controllerDivisionCount": controller.view.reservedRegions(kind: .division, options: .includeInactive).count,
                "hingeCallbacks": hingeCallbacks,
                "hingeAvailable": observedHinge != nil,
                "hingeStatus": observedHinge.map { String(describing: $0.status) } ?? "unavailable",
                "systemNavigationActivations": activations,
                "systemNavigation": controller.usesSystemNavigation,
                "homeNavigationHidden": controller.isTabBarHidden,
                "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
                "screenNativeWidth": scene.screen.nativeBounds.width,
                "screenNativeHeight": scene.screen.nativeBounds.height,
            ])
        }
        defer {
            sample("finished")
            if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "duo-system-capability-observations"; attachment.lifetime = .keepAlways; add(attachment)
                try? data.write(to: URL(fileURLWithPath: "/tmp/wand-duo-system-capabilities.json"))
            }
            controller.view.removeInteraction(hingeObserver)
            window.isHidden = true; window.rootViewController = nil
        }
        for _ in 0..<40 {
            if controller.usesSystemNavigation { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        sample("fresh-current-window")
        let currentWindowSupportsSystemBars = window.traitCollection.verticalBarEdge != .unspecified ||
            controller.traitCollection.verticalBarEdge != .unspecified || observedHinge != nil
        guard currentWindowSupportsSystemBars else {
            throw XCTSkip("This actual window does not currently expose vertical bars or a hinge; dimensions alone are not Duo capability")
        }
        XCTAssertTrue(controller.usesSystemNavigation, "A fresh outer-display context must not need an earlier inner-display visit")
        XCTAssertEqual(activations, 1, "Window, appearance and hinge discovery must converge on one activation")
        XCTAssertTrue(controller.isTabBarHidden, "Initial capability delivery must respect an already-open detail")
        let slots = try XCTUnwrap(controller.viewControllers)
        let originalHost = try XCTUnwrap(slots[controller.selectedIndex].children.first)
        // These are layout fixtures in the current actual window, not physical
        // hinge changes or rotations; only UIKit observations establish capability.
        let sizes: [(String, CGFloat, CGFloat, UIUserInterfaceSizeClass, UIUserInterfaceSizeClass)] = [
            ("inner-portrait-fixture", 669, 951, .regular, .regular),
            ("wide-fixture", 951, 669, .regular, .regular),
            ("outer-portrait-fixture", 466, 678, .compact, .regular),
            ("outer-landscape-fixture", 678, 466, .compact, .compact),
            ("returned-inner-fixture", 669, 951, .regular, .regular),
        ]
        for (name, width, height, horizontal, vertical) in sizes {
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
            controller.traitOverrides.horizontalSizeClass = horizontal
            controller.traitOverrides.verticalSizeClass = vertical
            controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            sample(name)
            XCTAssertTrue(controller.usesSystemNavigation, "A contextual edge becoming unspecified must not recreate inline navigation")
            XCTAssertTrue(controller.isTabBarHidden)
            XCTAssertTrue(slots.allSatisfy { !$0.tabBarItem.isEnabled })
            XCTAssertTrue(slots[controller.selectedIndex].children.first === originalHost)
            XCTAssertEqual(slots.flatMap(\.children).count, 1)
            XCTAssertEqual(activations, 1)
            XCTAssertFalse(controller.tabBarController(controller, shouldSelect: slots[0]))
        }
        XCTAssertTrue(selections.isEmpty)
        controller.update(content: content, mode: .sessions, enabled: true, navigationVisible: true) { selections.append($0) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.isTabBarHidden, "Returning home must restore the system-owned bar")
        XCTAssertTrue(slots[controller.selectedIndex].children.first === originalHost)
        XCTAssertEqual(activations, 1)
        sample("returned-home")
    }

    @MainActor
    func testIMDetailUsesNativeTitleAndReleasesInlineHeaderClearance() async throws {
        guard #available(iOS 27.1, *) else { throw XCTSkip("Duo toolbar integration requires iOS 27.1") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let service = HomeScrollConversationService()
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let suite = "IMSystemNavigationAcceptance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = ConversationStore(api: api, service: service, drafts: SessionDraftStore(), defaults: defaults)
        let detail = try XCTUnwrap(service.rows.first)
        await store.load(detail.id)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true; window.rootViewController = nil
            store.shutdown(); defaults.removePersistentDomain(forName: suite)
        }
        let host = UIHostingController(rootView: NavigationStack {
            ConversationDetailView(id: detail.id, store: store,
                onOpenSession: { _ in XCTFail("Read-only fixture") },
                onOpenConversation: { _ in XCTFail("Read-only fixture") },
                onEmployee: { _ in XCTFail("Read-only fixture") })
        }.environment(\.usesSystemHomeNavigation, true))
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(700))
        host.view.layoutIfNeeded()
        let navigation = try XCTUnwrap(homeNavigationControllers(host).compactMap { $0 as? UINavigationController }.first)
        let visible = try XCTUnwrap(navigation.visibleViewController)
        XCTAssertEqual(visible.navigationItem.title, detail.title, "IM must publish its identity through the native navigation item")
        XCTAssertFalse(navigation.isNavigationBarHidden)
        XCTAssertTrue(homeStandaloneFileBarItems(visible.navigationItem).isEmpty,
            "IM must expose its files through the action menu only")
        XCTAssertTrue(visible.navigationItem.additionalOverflowItems != nil ||
            homeNavigationBarItems(visible.navigationItem).contains { $0.menu != nil },
            "A file-only conversation must still have an accessible native menu")
        func scrollViews(_ root: UIView) -> [UIScrollView] {
            let own: [UIScrollView] = (root as? UIScrollView).flatMap { $0 is UITextView ? nil : $0 }.map { [$0] } ?? []
            return own + root.subviews.flatMap(scrollViews)
        }
        let messageScroll = try XCTUnwrap(scrollViews(visible.view).filter { $0.bounds.height > 100 }.max { $0.bounds.height < $1.bounds.height })
        let frame = messageScroll.convert(messageScroll.bounds, to: visible.view)
        let safeFrame = visible.view.safeAreaLayoutGuide.layoutFrame
        XCTAssertLessThanOrEqual(frame.minY - safeFrame.minY, 20,
            "The native title must not leave the old companion header's extra clearance in the reading viewport")
        XCTAssertEqual(service.mutations, 0)
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "im-native-system-title"; attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-im-native-system-title.png"))
    }

    /// Opens the production palette through UIKit's public control API and reads
    /// the actual native menu tree; no private selectors or synthetic UI events.
    @MainActor
    func testSessionActionPaletteProducesNativeIconsAndRetainsActionSemantics() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (variant, width, dark) in [("light", CGFloat(466), false), ("narrow-dark", 320, true)] {
            var fileOpens = 0
            var disabledExecutions = 0
            var otherExecutions = 0
            let actions = [
                SessionMenuAction(id: "files", title: "会话文件", symbol: "folder") { fileOpens += 1 },
                SessionMenuAction(id: "context", title: "对象与目录", symbol: "slider.horizontal.3") { otherExecutions += 1 },
                SessionMenuAction(id: "git", title: "变更与提交", symbol: "arrow.triangle.branch", isEnabled: false) { disabledExecutions += 1 },
                SessionMenuAction(id: "new", title: "新建工作窗口", symbol: "plus.circle") { otherExecutions += 1 },
                SessionMenuAction(id: "refresh", title: "刷新任务", symbol: "arrow.clockwise") { otherExecutions += 1 },
                SessionMenuAction(id: "copy", title: "复制工作目录", symbol: "doc.on.doc") { otherExecutions += 1 },
                SessionMenuAction(id: "stop", title: "停止当前任务", symbol: "stop", role: .destructive) { otherExecutions += 1 }
            ]
            let host = UIHostingController(rootView: VStack {
                Menu {
                    SessionActionPalette(actions: actions)
                } label: {
                    Label("更多会话功能", systemImage: "ellipsis").labelStyle(.iconOnly)
                        .frame(width: 48, height: 48)
                }
                .menuOrder(.fixed)
                .accessibilityIdentifier("session-palette-probe")
                .padding(.top, 80)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 678)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = host; window.makeKeyAndVisible()
            var interaction: UIContextMenuInteraction?
            defer {
                interaction?.dismissMenu()
                window.isHidden = true; window.rootViewController = nil
            }
            try await Task.sleep(for: .milliseconds(500))
            host.view.layoutIfNeeded()
            let control = try XCTUnwrap(homeMenuControls(host.view).first { $0.showsMenuAsPrimaryAction })
            XCTAssertGreaterThanOrEqual(control.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(control.bounds.height, 44)
            // Ignore pre-existing app windows behind this owned fixture, while
            // including a menu window that UIKit creates or makes visible later.
            let backgroundWindows = Set(scene.windows.filter { !$0.isHidden && $0 !== window }.map(ObjectIdentifier.init))
            func presentedWindows() -> [UIWindow] {
                scene.windows.filter { !$0.isHidden && $0.alpha > 0 &&
                    ($0 === window || !backgroundWindows.contains(ObjectIdentifier($0))) }
                    .enumerated().sorted {
                        $0.element.windowLevel == $1.element.windowLevel ? $0.offset < $1.offset :
                            $0.element.windowLevel.rawValue < $1.element.windowLevel.rawValue
                    }.map(\.element)
            }
            func snapshotPresentedViews() -> UIImage {
                UIGraphicsImageRenderer(size: window.bounds.size).image { context in
                    for presentedWindow in presentedWindows() {
                        presentedWindow.layoutIfNeeded()
                        let origin = presentedWindow.convert(CGPoint.zero, to: window)
                        context.cgContext.saveGState()
                        context.cgContext.translateBy(x: origin.x, y: origin.y)
                        presentedWindow.drawHierarchy(in: presentedWindow.bounds, afterScreenUpdates: true)
                        context.cgContext.restoreGState()
                    }
                }
            }
            let closedSnapshot = try XCTUnwrap(snapshotPresentedViews().pngData())
            control.performPrimaryAction()
            interaction = control.contextMenuInteraction
            var presentedMenu: UIMenu?
            for _ in 0..<30 {
                interaction?.updateVisibleMenu { menu in presentedMenu = menu; return menu }
                if presentedMenu != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let menu = try XCTUnwrap(presentedMenu, "The native menu must actually be presented before inspecting it")
            let shelves = homeMenuTree(menu).compactMap { $0 as? UIMenu }.filter { $0.options.contains(.displayAsPalette) }
            XCTAssertGreaterThan(shelves.count, 1, "A long action set must remain reachable across native icon shelves")
            XCTAssertTrue(shelves.allSatisfy { (1...3).contains($0.children.count) },
                "A narrow outer display must not receive an overfilled icon row")
            let nativeActions = homeMenuTree(menu).compactMap { $0 as? UIAction }
            XCTAssertEqual(nativeActions.map(\.title), actions.map(\.title), "No trailing task action may be lost or reordered")
            XCTAssertTrue(nativeActions.allSatisfy { $0.image != nil }, "Every native action needs a visible symbol")
            let fileAction = try XCTUnwrap(nativeActions.first { $0.title == "会话文件" })
            let disabledAction = try XCTUnwrap(nativeActions.first { $0.title == "变更与提交" })
            XCTAssertTrue(disabledAction.attributes.contains(.disabled), "UIKit must enforce the unavailable Git action")
            XCTAssertTrue(try XCTUnwrap(nativeActions.first { $0.title == "停止当前任务" }).attributes.contains(.destructive))
            XCTAssertEqual(fileOpens, 0); XCTAssertEqual(disabledExecutions, 0); XCTAssertEqual(otherExecutions, 0)

            // UIKit can expose the menu model before its opening animation has
            // produced pixels. Wait for presentation, then require a stable view
            // snapshot that differs from the closed trigger before external capture.
            try await Task.sleep(for: .milliseconds(700))
            let settleDeadline = Date().addingTimeInterval(3)
            var previousSnapshot: Data?
            var stableSnapshots = 0
            var presentedSnapshot: UIImage?
            while Date() < settleDeadline {
                let image = snapshotPresentedViews()
                let data = try XCTUnwrap(image.pngData())
                let transitioning = presentedWindows().compactMap(\.rootViewController)
                    .flatMap(homePresentedControllers).contains { $0.transitionCoordinator != nil }
                if data != closedSnapshot && data == previousSnapshot && !transitioning {
                    stableSnapshots += 1
                } else {
                    stableSnapshots = 0
                }
                presentedSnapshot = image; previousSnapshot = data
                if stableSnapshots >= 2 { break }
                try await Task.sleep(for: .milliseconds(120))
            }
            XCTAssertGreaterThanOrEqual(stableSnapshots, 2,
                "The visible menu must settle in the view snapshot before the screenshot checkpoint")
            let menuImage = try XCTUnwrap(presentedSnapshot)
            let imageAttachment = XCTAttachment(image: menuImage)
            imageAttachment.name = "native-session-palette-presented-" + variant
            imageAttachment.lifetime = .keepAlways; add(imageAttachment)
            try menuImage.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-native-session-palette-" + variant + ".png"))
            let observation: [String: Any] = [
                "variant": variant, "shelfCounts": shelves.map { $0.children.count },
                "titles": nativeActions.map(\.title), "allHaveImages": nativeActions.allSatisfy { $0.image != nil },
                "visibleSnapshotChanged": previousSnapshot != closedSnapshot,
                "stableVisibleSnapshots": stableSnapshots,
                "disabledTitles": nativeActions.filter { $0.attributes.contains(.disabled) }.map(\.title),
                "destructiveTitles": nativeActions.filter { $0.attributes.contains(.destructive) }.map(\.title)
            ]
            let data = try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "native-session-palette-" + variant; attachment.lifetime = .keepAlways; add(attachment)
            try data.write(to: URL(fileURLWithPath: "/tmp/wand-native-session-palette-" + variant + ".json"))
            if FileManager.default.fileExists(atPath: "/tmp/wand-icon-menu-capture-enabled") {
                let checkpoint = "/tmp/wand-icon-menu-capture-ready"
                try ("palette-" + variant).write(toFile: checkpoint, atomically: true, encoding: .utf8)
                let deadline = Date().addingTimeInterval(10)
                while FileManager.default.fileExists(atPath: checkpoint) && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint), "Capture the real presented menu before dismissal")
                try? FileManager.default.removeItem(atPath: checkpoint)
            }
            // Dispatching this enabled native action checks callback wiring, not
            // physical touch. Direct sendAction is not a disabled-item tap test.
            control.sendAction(fileAction)
            for _ in 0..<20 {
                if fileOpens == 1 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(fileOpens, 1)
            XCTAssertEqual(disabledExecutions, 0); XCTAssertEqual(otherExecutions, 0)
            interaction?.dismissMenu()
            try await Task.sleep(for: .milliseconds(350))
        }
    }

    @MainActor
    func testEmbeddedDetailPreferenceControlsSystemAndInlineNavigation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = HomeNavigationDetailProbe()
        let host = UIHostingController(rootView: HomeNavigationDetailFixture(state: state))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(700))
        let tabs = try XCTUnwrap(homeNavigationControllers(host).compactMap { $0 as? SystemHomeTabController }.first)
        let slots = try XCTUnwrap(tabs.viewControllers)
        let originalHost = try XCTUnwrap(slots[tabs.selectedIndex].children.first)

        for detail in [false, true, false, true, false] {
            state.detail = detail
            try await Task.sleep(for: .milliseconds(200))
            host.view.layoutIfNeeded()
            XCTAssertEqual(tabs.isTabBarHidden, detail || !tabs.usesSystemNavigation)
            XCTAssertEqual(slots.allSatisfy { $0.tabBarItem.isEnabled }, !detail)
            let inlineDock = homeNavigationMarker("home-preference-inline-dock", in: host.view)
            XCTAssertEqual(inlineDock != nil, !detail && !tabs.usesSystemNavigation,
                "The detail owner must hide both native navigation implementations")
            XCTAssertTrue(slots[tabs.selectedIndex].children.first === originalHost)
            XCTAssertEqual(slots.flatMap(\.children).count, 1)
        }
    }

    @MainActor
    func testDuoFourDimensionLayoutsKeepDetailSafeAndHostStable() async throws {
        // These are dimension/trait checks, not physical folding events. The sizes
        // come from this simulator's 1398x2034 and 2007x2853 displays at 3x scale.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let state = HomeNavigationDetailProbe()
        state.detail = true
        let host = UIHostingController(rootView: HomeNavigationDetailFixture(state: state))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(700))
        let tabs = try XCTUnwrap(homeNavigationControllers(host).compactMap { $0 as? SystemHomeTabController }.first)
        let slots = try XCTUnwrap(tabs.viewControllers)
        let originalHost = try XCTUnwrap(slots[tabs.selectedIndex].children.first)
        let originalEditor = try XCTUnwrap(homeNavigationEditors(host.view).first)
        let dimensions: [(String, CGFloat, CGFloat)] = [
            ("open-portrait", 669, 951), ("open-landscape", 951, 669),
            ("closed-portrait", 466, 678), ("closed-landscape", 678, 466)
        ]
        for detail in [true, false] {
            state.detail = detail
            for (name, width, height) in dimensions {
                window.frame = CGRect(x: 0, y: 0, width: width, height: height)
                host.traitOverrides.verticalSizeClass = width > height ? .compact : .regular
                host.traitOverrides.horizontalSizeClass = width >= 640 && height >= 480 ? .regular : .compact
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(host.view.bounds.width, width, accuracy: 1)
                XCTAssertEqual(host.view.bounds.height, height, accuracy: 1)
                XCTAssertEqual(tabs.isTabBarHidden, detail || !tabs.usesSystemNavigation)
                XCTAssertTrue(slots[tabs.selectedIndex].children.first === originalHost)
                XCTAssertEqual(slots.flatMap(\.children).count, 1)
                if tabs.usesSystemNavigation {
                    let containerFrame = tabs.view.convert(tabs.view.bounds, to: window)
                    XCTAssertEqual(containerFrame.minX, window.bounds.minX, accuracy: 1)
                    XCTAssertEqual(containerFrame.maxX, window.bounds.maxX, accuracy: 1)
                    XCTAssertEqual(containerFrame.minY, window.bounds.minY, accuracy: 1,
                        "Open portrait must not add an outer status-bar row")
                    XCTAssertEqual(containerFrame.maxY, window.bounds.maxY, accuracy: 1)
                }
                if detail {
                    let editor = try XCTUnwrap(homeNavigationEditors(host.view).first)
                    XCTAssertTrue(editor === originalEditor, "Rotation-sized layout must preserve the mounted editor")
                    XCTAssertEqual(editor.text, state.text)
                    let dock = try XCTUnwrap(homeNavigationMarker("home-preference-detail-dock", in: host.view))
                    let dockFrame = dock.convert(dock.bounds, to: originalHost.view)
                    let safeFrame = originalHost.view.safeAreaLayoutGuide.layoutFrame
                    XCTAssertGreaterThanOrEqual(dockFrame.minX, safeFrame.minX - 1)
                    XCTAssertLessThanOrEqual(dockFrame.maxX, safeFrame.maxX + 1)
                    XCTAssertGreaterThanOrEqual(dockFrame.minY, safeFrame.minY)
                    XCTAssertLessThanOrEqual(dockFrame.maxY, safeFrame.maxY + 1)
                    XCTAssertGreaterThan(editor.bounds.height, 20)
                    XCTAssertGreaterThan(editor.bounds.width, 160)
                }
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let label = "duo-dimensions-" + name + (detail ? "-detail" : "-home")
                let attachment = XCTAttachment(image: image)
                attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
                try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/" + label + ".png"))
            }
        }
    }

    @MainActor
    func testHomeNavigationHidesForDetailAndReturnsWithoutReplacingItsHost() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = SystemHomeTabController()
        let content = AnyView(Text("One navigation and composer owner"))
        var requests: [HomeListMode] = []
        controller.update(content: content, mode: .sessions, enabled: true, navigationVisible: true) { requests.append($0) }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))

        let slots = try XCTUnwrap(controller.viewControllers)
        let originalHost = try XCTUnwrap(slots[controller.selectedIndex].children.first)
        XCTAssertEqual(controller.isTabBarHidden, !controller.usesSystemNavigation)

        controller.update(content: content, mode: .sessions, enabled: true, navigationVisible: false) { requests.append($0) }
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.isTabBarHidden, "A detail must not retain the global navigation bar")
        XCTAssertTrue(slots.allSatisfy { !$0.tabBarItem.isEnabled })
        XCTAssertFalse(controller.tabBarController(controller, shouldSelect: slots[0]))
        XCTAssertTrue(requests.isEmpty, "A hidden navigation item cannot interrupt a detail")
        XCTAssertTrue(slots[controller.selectedIndex].children.first === originalHost)

        controller.update(content: content, mode: .sessions, enabled: true, navigationVisible: true) { requests.append($0) }
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.isTabBarHidden, !controller.usesSystemNavigation,
            "Returning to the list restores system navigation only on capable devices")
        XCTAssertTrue(slots.allSatisfy { $0.tabBarItem.isEnabled })
        XCTAssertTrue(slots[controller.selectedIndex].children.first === originalHost)
        XCTAssertEqual(slots.flatMap(\.children).count, 1)
        XCTAssertFalse(controller.tabBarController(controller, shouldSelect: slots[0]))
        XCTAssertEqual(requests, [.im])
    }

    @MainActor
    func testDetailOpenedBeforeCapabilityDetectionNeverRevealsHomeNavigation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = SystemHomeTabController()
        let content = AnyView(Text("Already showing a task detail"))
        controller.update(content: content, mode: .board, enabled: true, navigationVisible: false) { _ in
            XCTFail("A detail must not dispatch a home destination")
        }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(controller.isTabBarHidden,
            "Late discovery of foldable system bars must respect the latest detail state")
        let slots = try XCTUnwrap(controller.viewControllers)
        XCTAssertTrue(slots.allSatisfy { !$0.tabBarItem.isEnabled })
        XCTAssertEqual(slots.flatMap(\.children).count, 1)

        controller.update(content: content, mode: .board, enabled: true, navigationVisible: true) { _ in }
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.isTabBarHidden, !controller.usesSystemNavigation)
    }

    @MainActor
    func testSystemNavigationOwnsContainerSafeAreaWithoutASecondInset() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: SystemHomeNavigation(mode: .im, enabled: true, onSelect: { _ in }) {
            Text("Existing content remains inside UIKit's safe area")
        })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(700))
        func controllers(_ root: UIViewController) -> [UIViewController] {
            [root] + root.children.flatMap(controllers)
        }
        let tabs = try XCTUnwrap(controllers(host).compactMap { $0 as? SystemHomeTabController }.first)
        let frame = tabs.view.convert(tabs.view.bounds, to: window)
        if tabs.usesSystemNavigation {
            XCTAssertEqual(frame.minX, window.bounds.minX, accuracy: 1)
            XCTAssertEqual(frame.maxX, window.bounds.maxX, accuracy: 1,
                "Native tabs must share the status-bar column, not sit inside an extra safe area")
            XCTAssertEqual(frame.minY, window.bounds.minY, accuracy: 1,
                "The UIKit navigation owner must reach the status-bar row in portrait")
            XCTAssertEqual(frame.maxY, window.bounds.maxY, accuracy: 1,
                "Only UIKit may reserve the bottom system bar area")
        } else {
            XCTAssertTrue(tabs.isTabBarHidden, "Ordinary iPhones must retain their existing dock")
        }
    }

    @MainActor
    func testSystemHomeNavigationRetainsOneHostAndCommitsOnlyAcceptedTabs() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let controller = SystemHomeTabController()
        var requests: [HomeListMode] = []
        let content = AnyView(Text("Existing navigation tree"))
        controller.update(content: content, mode: .im, enabled: true) { requests.append($0) }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(500))
        let slots = try XCTUnwrap(controller.viewControllers)
        XCTAssertEqual(slots.count, 4)
        let host = try XCTUnwrap(slots[0].children.first)
        XCTAssertFalse(controller.tabBarController(controller, shouldSelect: slots[3]))
        XCTAssertEqual(requests, [.board])
        XCTAssertEqual(controller.selectedIndex, 0, "An unconfirmed switch cannot change the visible tab")
        controller.update(content: content, mode: .board, enabled: false) { requests.append($0) }
        XCTAssertEqual(controller.selectedIndex, 3)
        XCTAssertTrue(slots[3].children.first === host, "Switching tabs must move the existing tree, not create another composer")
        XCTAssertEqual(slots.flatMap(\.children).count, 1)
        XCTAssertFalse(controller.tabBarController(controller, shouldSelect: slots[0]))
        XCTAssertEqual(requests, [.board], "Busy navigation cannot dispatch another switch")
        XCTAssertTrue(slots.allSatisfy { !$0.tabBarItem.isEnabled })
        if #available(iOS 27.1, *) {
            let hasCurrentBarOrDivisionEvidence = controller.traitCollection.verticalBarEdge != .unspecified ||
                window.traitCollection.verticalBarEdge != .unspecified ||
                !controller.view.reservedRegions(kind: .division, options: .includeInactive).isEmpty
            // A positive current signal requires native navigation. No current
            // signal does not disprove an earlier hinge update or another pose.
            if hasCurrentBarOrDivisionEvidence { XCTAssertTrue(controller.usesSystemNavigation) }
            XCTAssertEqual(controller.isTabBarHidden, !controller.usesSystemNavigation)
        } else {
            XCTAssertFalse(controller.usesSystemNavigation)
            XCTAssertTrue(controller.isTabBarHidden)
        }
    }

    @MainActor
    func testNativeFormControlsRemainSystemControls() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let probe = NativeFormProbe()
        let host = UIHostingController(rootView: NativeFormFixture(probe: probe))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(120))
        func switches(_ view: UIView) -> [UISwitch] { (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches) }
        let toggles = switches(host.view)
        XCTAssertEqual(toggles.count, 2)
        XCTAssertEqual(toggles.filter(\.isEnabled).count, 1)
        XCTAssertEqual(toggles.filter(\.isOn).count, 1)
    }

    @MainActor
    func testNativeFormControlTouchDriver() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-native-form-touch-enabled") else { throw XCTSkip("Native form control touch driver only") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let probe = NativeFormProbe()
        let done = expectation(description: "Native switch and composed native glass buttons dispatch exactly once")
        let host = UIHostingController(rootView: NativeFormFixture(probe: probe) { done.fulfill() })
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.windowLevel = .alert + 1; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try "ready".write(toFile: "/tmp/wand-native-form-ready", atomically: true, encoding: .utf8)
        await fulfillment(of: [done], timeout: 100)
        XCTAssertTrue(probe.enabled); XCTAssertTrue(probe.disabled)
        XCTAssertEqual(probe.disabledWrites, 0)
        XCTAssertEqual(probe.primary, 1); XCTAssertEqual(probe.secondary, 1)
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "system-form-controls"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testExecutionProgressRemainsWithComposerRatherThanMessageHistory() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Wand/ChatView.swift"), encoding: .utf8)
        let bottom = try XCTUnwrap(chat.components(separatedBy: "private var bottomBar: some View {").last)
            .components(separatedBy: "private var executionProgressInline:").first ?? ""
        XCTAssertTrue(bottom.contains("TodoProgressBar(todos: visibleTodos, maximumExpandedHeight: accessoryMaximumHeight,"))
        let stream = chat.components(separatedBy: "private func messageList(").last?.components(separatedBy: "private var bottomBar:").first ?? ""
        XCTAssertFalse(stream.contains("if hasDetailedProgress { executionProgressInline }"))
        // Subagent interaction stays owned by the message stream.
        XCTAssertTrue(chat.contains("if shouldShowSubagentShelf { executionProgressInline }"))
    }

    @MainActor
    func testNativeCapsulesAndUnclippedHeaderPortrait() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-capsule-visual-enabled") else {
            throw XCTSkip("Opt-in native capsule and transparent scene captures")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for dark in [false, true] {
            let host = UIHostingController(rootView: VStack(spacing: 24) {
                ZStack(alignment: .top) {
                    ChatTopIdentityBar(title: "工作区任务的完整标题", subtitle: "赛博虎妞 · wand",
                        attention: .running, avatarValue: "plush-cat:v1:silver", activity: .reading)
                    FloatingChatControls(onBack: {}) {
                        Menu {
                            SessionActionPalette(actions: [
                                SessionMenuAction(id: "files", title: "会话文件", symbol: "folder") {},
                                SessionMenuAction(id: "settings", title: "设置", symbol: "gearshape") {}
                            ])
                        } label: { FloatingChatIcon(symbol: "ellipsis") }
                    }
                }.frame(height: 80)
                HStack { HomeExecutionBadge(state: .running); HomeExecutionBadge(state: .queued); HomeExecutionBadge(state: .idle) }
                TopCapsuleTitle(title: "标题不会裁剪头像", subtitle: "允许角色超出玻璃背景",
                    avatarID: "e_wand_default", avatarValue: "plush-cat:v1:silver", thinking: true)
                Button("系统胶囊按钮", systemImage: "plus") {}.buttonStyle(.glass).buttonBorderShape(.capsule)
                Text("原生胶囊信息").padding(8).wandGlassCapsule(tint: Theme.success)
                TodoProgressBar(todos: [
                    TodoItem(content: "已核对系统控件", status: "completed", activeForm: nil),
                    TodoItem(content: "检查头像边缘与原生玻璃，完整进度直接可读，不需要打开折叠框", status: "in_progress", activeForm: "检查头像"),
                    TodoItem(content: "验证输入和滚动", status: "pending", activeForm: nil)
                ]).padding(.horizontal, 16)
                Spacer()
            }.padding(.top, 12).background(Theme.background)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = UIWindow(windowScene: scene); window.rootViewController = host
            window.windowLevel = .alert + 1; window.makeKeyAndVisible()
            host.traitOverrides.userInterfaceStyle = dark ? .dark : .light
            try await Task.sleep(for: .milliseconds(700))
            func webViews(_ view: UIView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
            let avatars = webViews(host.view); XCTAssertGreaterThanOrEqual(avatars.count, 2)
            for avatar in avatars {
                XCTAssertGreaterThanOrEqual(avatar.bounds.width, 48)
                XCTAssertFalse(avatar.clipsToBounds); XCTAssertFalse(avatar.scrollView.clipsToBounds)
                XCTAssertFalse(avatar.isOpaque)
                XCTAssertLessThan(avatar.underPageBackgroundColor.cgColor.alpha, 0.01)
                var parent = avatar.superview
                while let view = parent {
                    XCTAssertFalse(view is UIVisualEffectView, "Avatar cannot be inside the glass effect mask")
                    if view.bounds.width < avatar.bounds.width - 1 { XCTAssertFalse(view.clipsToBounds) }
                    parent = view.superview
                }
            }
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = dark ? "native-capsules-dark" : "native-capsules-light"
            attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; window.rootViewController = nil
        }
    }

    @MainActor
    func testNavigationUsesTheNativeTabBarAndSystemSelection() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: HomeMenuPill(mode: .board, onMode: { _ in }, onContacts: {}))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(80))
        func bars(_ view: UIView) -> [UITabBar] { (view as? UITabBar).map { [$0] } ?? view.subviews.flatMap(bars) }
        let bar = try XCTUnwrap(bars(host.view).first)
        XCTAssertEqual(bar.items?.map(\.title), ["聊天", "通讯录", "工作区", "任务"])
        XCTAssertEqual(bar.selectedItem?.tag, 3)
        host.rootView = HomeMenuPill(mode: .sessions, onMode: { _ in }, onContacts: {})
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(bar.selectedItem?.tag, 2)
        for width: CGFloat in [280, 320, 440] {
            let size = host.sizeThatFits(in: CGSize(width: width, height: 100))
            XCTAssertLessThanOrEqual(size.width, width); XCTAssertGreaterThanOrEqual(size.height, 44)
        }
    }

    @MainActor
    func testSidebarExtendsBehindFloatingDockAndKeepsLastRowReachable() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (width, dark) in [(CGFloat(320), false), (360, true), (500, false)] {
            let host = UIHostingController(rootView: HomeSidebarLayout {
                List(0..<30, id: \.self) { index in Text("界面验收样例 \(index)").frame(minHeight: 60) }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Theme.background)
            } navigation: {
                HomeMenuPill(mode: .im, onMode: { _ in }, onContacts: {})
                    .padding(.vertical, 8)
            }.frame(width: width, height: 600)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
                (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
            }
            let bar = try XCTUnwrap(descendants(host.view, of: UITabBar.self).first)
            let scroll = try XCTUnwrap(descendants(host.view, of: UIScrollView.self).first)
            let viewport = scroll.convert(scroll.bounds, to: host.view)
            let dock = bar.convert(bar.bounds, to: host.view)
            XCTAssertGreaterThanOrEqual(dock.height, 44)
            XCTAssertGreaterThan(viewport.maxY, dock.minY, "页面应连续延伸到悬浮底栏后方")
            XCTAssertLessThanOrEqual(viewport.maxY - scroll.adjustedContentInset.bottom, dock.minY + 1,
                "系统滚动余量应让末项停在底栏上方")
            // List resolves estimated row heights as cells enter the viewport.
            for _ in 0..<3 {
                scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                try await Task.sleep(for: .milliseconds(150))
                host.view.layoutIfNeeded()
            }
            XCTAssertGreaterThanOrEqual(scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom,
                scroll.contentSize.height - 1, "最后一行必须能完整滚动到菜单上方")
            let image = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "sidebar-floating-" + String(Int(width)); attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-home-floating-\(Int(width)).png"))
        }
    }

    @MainActor
    func testNativeGlassDockSnapshotsAndSwitching() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-dock-visual-enabled") else {
            throw XCTSkip("Opt-in native glass/motion captures")
        }
        print("Dock native environment: reduceMotion=\(UIAccessibility.isReduceMotionEnabled), animations=\(UIView.areAnimationsEnabled)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (name, width, dark, large, contrast, rtl) in [
            ("light", CGFloat(402), false, false, false, false),
            ("dark", 402, true, false, false, false),
            ("narrow-large", 280, false, true, false, false),
            ("high-contrast", 402, false, false, true, false),
            ("wide-rtl", 768, false, false, false, true)
        ] {
            let probe = HomeDockProbe()
            let content = HomeDockFixture(probe: probe)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.sizeCategory, large ? .accessibilityExtraExtraLarge : .large)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            let host = UIHostingController(rootView: content)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
            window.rootViewController = host; window.makeKeyAndVisible()
            host.traitOverrides.userInterfaceStyle = dark ? UIUserInterfaceStyle.dark : .light
            host.traitOverrides.accessibilityContrast = contrast ? .high : .normal
            host.traitOverrides.preferredContentSizeCategory = large ? .accessibilityExtraExtraLarge : .large
            try await Task.sleep(for: .milliseconds(150))
            func capture(_ suffix: String) {
                host.view.layoutIfNeeded()
                let crop = suffix.hasPrefix("travel-")
                let size = CGSize(width: window.bounds.width, height: crop ? 140 : window.bounds.height)
                let image = UIGraphicsImageRenderer(size: size).image { context in
                    if crop { context.cgContext.translateBy(x: 0, y: -(window.bounds.height - 140)) }
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                let attachment = XCTAttachment(image: image); attachment.name = "dock-" + name + "-" + suffix
                attachment.lifetime = .keepAlways; add(attachment)
            }
            capture("initial")
            probe.select(.board)
            for (index, delay) in [60, 80, 80, 160].enumerated() {
                try await Task.sleep(for: .milliseconds(delay))
                capture("travel-" + String(index))
            }
            probe.select(.contacts); try await Task.sleep(for: .milliseconds(40))
            probe.select(.sessions); try await Task.sleep(for: .milliseconds(40))
            probe.select(.im); try await Task.sleep(for: .milliseconds(380))
            capture("rapid-settled")
            XCTAssertEqual(probe.mode, .im); XCTAssertEqual(probe.selections.count, 4)
            XCTAssertLessThanOrEqual(host.view.bounds.width, width)
            window.isHidden = true; window.rootViewController = nil
        }
    }

    @MainActor
    func testDockTouchDriver() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-dock-touch-enabled") else {
            throw XCTSkip("Opt-in native dock touch driver")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let probe = HomeDockProbe()
        let finished = expectation(description: "Native dock tap targets stay fixed")
        let host = UIHostingController(rootView: HomeDockFixture(probe: probe) { finished.fulfill() })
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.windowLevel = .alert + 1; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func bars(_ view: UIView) -> [UITabBar] { (view as? UITabBar).map { [$0] } ?? view.subviews.flatMap(bars) }
        let bar = try XCTUnwrap(bars(host.view).first)
        let barFrame = bar.convert(bar.bounds, to: window)
        let safeFrame = bar.convert(bar.safeAreaLayoutGuide.layoutFrame, to: window)
        var targetFrames: [String: [String: CGFloat]] = [:]
        for (index, item) in (bar.items ?? []).enumerated() {
            let actual = item.accessibilityFrame
            let rect: CGRect
            if actual.width > 20 && actual.height > 20 { rect = actual }
            else {
                // Native itemPositioning.fill, within UIKit's own safe-area layout guide.
                rect = CGRect(x: safeFrame.minX + CGFloat(index) * safeFrame.width / 4,
                    y: safeFrame.minY, width: safeFrame.width / 4, height: safeFrame.height)
            }
            targetFrames[item.title ?? ""] = ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        }
        let payload: [String: Any] = ["items": targetFrames, "bar": ["x": barFrame.minX, "y": barFrame.minY,
            "width": barFrame.width, "height": barFrame.height]]
        try JSONSerialization.data(withJSONObject: payload).write(to: URL(fileURLWithPath: "/tmp/wand-native-tab-targets.json"), options: .atomic)
        try "ready".write(toFile: "/tmp/wand-dock-ready", atomically: true, encoding: .utf8)
        await fulfillment(of: [finished], timeout: 120)
        XCTAssertEqual(probe.selections, [.board, .contacts, .sessions, .im, .im])
        XCTAssertEqual(probe.mode, .im)
    }

    func testLandingSurfacesKeepRecentHistoryBeforeDirectoriesAndShareSearch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Wand/" + name + ".swift"), encoding: .utf8)
        }
        let workspace = try source("WorkspaceListView")
        let directories = try XCTUnwrap(workspace.range(of: "ForEach(visible) { group in"))
        let history = try XCTUnwrap(workspace.range(of: "HomeSectionHeader(title: \"最近对话\""))
        XCTAssertLessThan(history.lowerBound, directories.lowerBound, "工作区页最近对话应排在任务与工作区之前")
        for name in ["WorkspaceListView", "ConversationViews", "ContactsView", "TaskBoardView"] {
            XCTAssertTrue(try source(name).contains("HomeSearchField("), name)
        }
        XCTAssertLessThan(WorkspaceTreeLevel.session.rawValue, 48, "窄屏要给会话正文留空间")
        XCTAssertTrue(try source("TaskBoardView").contains("ViewThatFits(in: .horizontal)"), "状态筛选随可用宽度切换系统分段控件与菜单")
    }

    func testExecutionBadgesUseRuntimeFactsAndNeverBusinessStatusAsRunning() throws {
        let running = try decode(WorkspaceTaskSummary.self, #"{"id":"running","workspaceId":"w","name":"运行","status":"active","createdAt":"","cwd":"/work","sessions":[],"executionStatus":"running"}"#)
        XCTAssertEqual(HomePresentation.executionState(running), .running)
        let queued = try decode(WorkspaceTaskSummary.self, #"{"id":"queued","workspaceId":"w","name":"队列","status":"active","createdAt":"","cwd":"/work","sessions":[],"executionStatus":"queued"}"#)
        XCTAssertEqual(HomePresentation.executionState(queued), .queued)
        let idle = try decode(WorkspaceTaskSummary.self, #"{"id":"idle","workspaceId":"w","name":"空闲","status":"active","createdAt":"","cwd":"/work","sessions":[]}"#)
        XCTAssertEqual(HomePresentation.executionState(idle), .idle)
        XCTAssertEqual(HomePresentation.executionState(try summary(#"{"id":"shell","sessionKind":"pty","status":"running","ptyBusy":false,"providerCliActive":false}"#)), .idle)
        XCTAssertEqual(HomePresentation.executionState(try summary(#"{"id":"wait","permissionBlocked":true}"#)), .needsYou)
        XCTAssertEqual(HomePresentation.executionState(try summary(#"{"id":"fail","status":"failed"}"#)), .failed)
        XCTAssertEqual(HomePresentation.executionState(try summary(#"{"id":"archive","archived":true,"inFlight":true}"#)), .archived)
        XCTAssertEqual(Set(HomeExecutionState.allCases.map(\.label)).count, 7)
        XCTAssertEqual(Set(HomeExecutionState.allCases.map(\.symbol)).count, 7)
    }

    @MainActor
    func testExecutionBadgeKeepsItsTextInsideIconOnlyListContexts() {
        let host = UIHostingController(rootView: HomeExecutionBadge(state: .idle)
            .labelStyle(.iconOnly).dynamicTypeSize(.large))
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 100))
        XCTAssertGreaterThan(size.width, 56, "未运行文字不能被列表的iconOnly环境吞掉")
    }

    func testSwipeDirectionRejectsVerticalBeforeTheRecognizerBegins() {
        for point in [CGPoint(x: 0, y: 500), CGPoint(x: 40, y: -500), CGPoint(x: -60, y: 500),
                      CGPoint(x: -100, y: 100), CGPoint.zero] {
            XCTAssertFalse(homeSwipeShouldBegin(velocity: point, allowsRightward: false))
            XCTAssertFalse(homeSwipeShouldBegin(velocity: point, allowsRightward: true))
        }
        XCTAssertTrue(homeSwipeShouldBegin(velocity: CGPoint(x: -500, y: 20), allowsRightward: false))
        XCTAssertFalse(homeSwipeShouldBegin(velocity: CGPoint(x: 500, y: 20), allowsRightward: false))
        XCTAssertTrue(homeSwipeShouldBegin(velocity: CGPoint(x: 500, y: 20), allowsRightward: true))
    }

    @MainActor
    func testLongChatListScrollWithNativeDriver() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-chat-scroll-enabled") else {
            throw XCTSkip("Explicit overflow-chat native scroll regression")
        }
        let service = HomeScrollConversationService()
        let api = WandAPI(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        let store = ConversationStore(api: api, service: service, drafts: SessionDraftStore(),
            defaults: UserDefaults(suiteName: "scroll-chat-regression")!)
        await store.refresh()
        let probe = HomeScrollProbe()
        let finished = expectation(description: "Real chat renderer with 25 synthetic rows scrolls")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: HomeLongChatScrollFixture(store: store, probe: probe) { finished.fulfill() })
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.windowLevel = .alert + 1; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; store.shutdown() }
        try "ready".write(toFile: "/tmp/wand-chat-scroll-ready", atomically: true, encoding: .utf8)
        await fulfillment(of: [finished], timeout: 120)
        XCTAssertGreaterThan(probe.overflow, 100)
        XCTAssertEqual(service.mutations, 0)
    }

    /// 静默补页依赖首屏真实几何：首次布局必须以正高度报到，否则内容不满视口时永远不会往前翻页。
    @MainActor
    func testChatGeometryReportsShortFirstScreenHeightForFillPaging() async throws {
        let probe = ChatFillGeometryProbe()
        let finished = expectation(description: "Short chat list reports its content height")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: ChatFillViewportFixture(probe: probe) {
            guard !probe.reported else { return }
            probe.reported = true
            finished.fulfill()
        })
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.windowLevel = .alert + 1; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertEqual(probe.viewportHeight, 600, accuracy: 1)
        XCTAssertGreaterThan(probe.contentHeight, 0)
        XCTAssertTrue(shouldLoadEarlierPageToFillViewport(
            canLoadEarlier: true,
            loadingEarlier: false,
            contentHeight: probe.contentHeight,
            viewportHeight: probe.viewportHeight
        ), "装不满一屏的首屏必须触发补页：实测内容 \(probe.contentHeight)pt / 视口 \(probe.viewportHeight)pt")
    }

    @MainActor
    func testInstalledHomeScrollWithNativeDriver() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-installed-scroll-enabled") else {
            throw XCTSkip("Explicit read-only installed-service native scroll driver")
        }
        struct Connection: Decodable { let serverURL: String; let connectionCode: String }
        let path = try String(contentsOfFile: "/tmp/wand-mobile-home-acceptance-path", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let decoded = try XCTUnwrap(WandAuth.decodeConnectCode(connection.connectionCode))
        let api = WandAPI(baseURL: try XCTUnwrap(URL(string: connection.serverURL)), token: decoded.token)
        let workspace = WorkspaceStore(api: api, serverID: "scroll-read-only")
        let contacts = ContactsStore(service: api)
        let conversations = ConversationStore(api: api, drafts: SessionDraftStore())
        await workspace.loadWorkspaceIndex(); await workspace.loadTaskGroups(force: true)
        contacts.activate(); await contacts.refresh(); await conversations.refresh()
        XCTAssertNil(workspace.taskGroupsError); XCTAssertNil(contacts.error); XCTAssertNil(conversations.error)
        let probe = HomeScrollProbe()
        let finished = expectation(description: "Four real home surfaces scroll without dispatch")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: HomeInstalledScrollFixture(api: api, workspace: workspace,
            contacts: contacts, conversations: conversations, probe: probe) { finished.fulfill() })
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.windowLevel = .alert + 1; window.makeKeyAndVisible()
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                var views: [UIScrollView] = []
                func collect(_ view: UIView) {
                    if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.bounds.height > 100 { views.append(scroll) }
                    view.subviews.forEach(collect)
                }
                collect(host.view)
                if let scroll = views.max(by: { $0.contentSize.height - $0.bounds.height < $1.contentSize.height - $1.bounds.height }) {
                    probe.offset = Int(scroll.contentOffset.y + scroll.adjustedContentInset.top)
                    probe.overflow = max(0, Int(scroll.contentSize.height - scroll.bounds.height))
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer {
            monitor.cancel(); window.isHidden = true; window.rootViewController = nil
            workspace.stopTaskGroupsSync(); contacts.close(); conversations.shutdown()
        }
        try "ready".write(toFile: "/tmp/wand-installed-scroll-ready", atomically: true, encoding: .utf8)
        await fulfillment(of: [finished], timeout: 180)
    }

    @MainActor
    func testVerticalScrollWithNativeDriver() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-scroll-driver-enabled") else {
            throw XCTSkip("Explicit native scrolling and swipe regression driver only")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let finished = expectation(description: "Vertical scrolling in List and ScrollView")
        let host = UIHostingController(rootView: HomeScrollInteractionFixture { offsets in
            XCTAssertGreaterThan(offsets["list", default: 0], 100)
            XCTAssertGreaterThan(offsets["scroll", default: 0], 100)
            finished.fulfill()
        })
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.windowLevel = .alert + 1; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try "ready".write(toFile: "/tmp/wand-scroll-ready", atomically: true, encoding: .utf8)
        await fulfillment(of: [finished], timeout: 150)
    }

    @MainActor
    func testSwipeGestureWithNativeDriver() async throws {
        guard FileManager.default.fileExists(atPath: "/tmp/wand-home-swipe-driver-enabled") else {
            throw XCTSkip("Explicit isolated native swipe driver only")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let finished = expectation(description: "Native left/right swipe, one owner, cancel and labeled action")
        let host = UIHostingController(rootView: HomeSwipeInteractionFixture { count, visited in
            XCTAssertEqual(count, 1, "Swipe alone must never run an operation")
            XCTAssertTrue(visited.contains("a")); XCTAssertTrue(visited.contains("b"))
            finished.fulfill()
        })
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.windowLevel = .alert + 1; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try "ready".write(toFile: "/tmp/wand-home-swipe-ready", atomically: true, encoding: .utf8)
        await fulfillment(of: [finished], timeout: 100)
    }

    @MainActor
    func testSearchClearSlotKeepsGeometryAtNarrowAndLargeTypeSizes() {
        for category in [ContentSizeCategory.large, .accessibilityExtraExtraLarge] {
            for width: CGFloat in [280, 320, 768] {
                let empty = UIHostingController(rootView: HomeSearchGeometryFixture(value: "", category: category))
                let filled = UIHostingController(rootView: HomeSearchGeometryFixture(value: "目录", category: category))
                let proposal = CGSize(width: width, height: 300)
                let a = empty.sizeThatFits(in: proposal), b = filled.sizeThatFits(in: proposal)
                XCTAssertLessThanOrEqual(a.width, width)
                XCTAssertGreaterThanOrEqual(a.height, WandLayout.controlTouch)
                XCTAssertEqual(a.height, b.height, accuracy: 1)
                XCTAssertEqual(a.width, b.width, accuracy: 1)
            }
        }
    }

    /// Explicit, read-only installed-service acceptance; no providers, mutations or device installs.
    @MainActor
    func testInstalledFourLandingScreens() async throws {
        let pointer = URL(fileURLWithPath: "/tmp/wand-mobile-home-acceptance-path")
        guard FileManager.default.fileExists(atPath: pointer.path) else {
            throw XCTSkip("Requires explicit installed-service connection path")
        }
        let path = try String(contentsOf: pointer, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        struct Connection: Decodable { let serverURL: String; let connectionCode: String }
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let url = try XCTUnwrap(URL(string: connection.serverURL))
        let decoded = try XCTUnwrap(WandAuth.decodeConnectCode(connection.connectionCode))
        let api = WandAPI(baseURL: url, token: decoded.token)
        let workspace = WorkspaceStore(api: api, serverID: "home-read-only-acceptance")
        let contacts = ContactsStore(service: api)
        let conversations = ConversationStore(api: api, drafts: SessionDraftStore())
        await workspace.loadWorkspaceIndex()
        await workspace.loadTaskGroups(force: true)
        contacts.activate(); await contacts.refresh()
        await conversations.refresh()
        let tasks = try await api.listBoardTasks()
        XCTAssertNil(workspace.taskGroupsError); XCTAssertNil(contacts.error); XCTAssertNil(conversations.error)
        defer { workspace.stopTaskGroupsSync(); contacts.close(); conversations.shutdown() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (variant, width, dark, category) in [
            ("phone-light", CGFloat(402), false, ContentSizeCategory.large),
            ("phone-dark", 402, true, ContentSizeCategory.large),
            ("narrow-large", 320, false, ContentSizeCategory.accessibilityExtraExtraLarge)
        ] {
            for mode in [HomeListMode.im, .contacts, .sessions, .board] {
                let overview = HomeOverviewBar(serverDisplayName: "当前服务器", title: mode.label,
                    showNewTask: mode == .sessions, onNewTask: {}, onOpenSettings: {}, onSwitchServer: {})
                let surface: AnyView
                switch mode {
                case .im:
                    surface = AnyView(ConversationListView(store: conversations, onSelect: { _ in },
                        onEmployee: { _ in }, onSettings: {}, onSwitchServer: {}))
                case .contacts:
                    surface = AnyView(ContactsView(api: api, store: contacts, onBack: {},
                        onOpenSession: { _ in }, onOpenRun: { _ in }, embedded: true,
                        serverDisplayName: "当前服务器", onOpenSettings: {}, onSwitchServer: {}))
                case .sessions:
                    surface = AnyView(VStack(spacing: 0) {
                        overview
                        WorkspaceListView(store: workspace, api: api, selectedTaskId: nil,
                            hidesHomeChrome: true, isSelecting: .constant(false), onOpenTask: { _, _ in },
                            employees: contacts.employees, teams: contacts.teams)
                    })
                case .board:
                    surface = AnyView(TaskBoardView(api: api, workspaceStore: workspace,
                        onOpenSession: { _ in }, embedded: true, overviewBar: overview))
                }
                let content = HomeSidebarLayout {
                    surface.background(Theme.background)
                } navigation: {
                    HomeMenuPill(mode: mode, onMode: { _ in }, onContacts: {})
                        .padding(.vertical, 8)
                }
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.sizeCategory, category)
                    .transaction { $0.disablesAnimations = true }
                let host = UIHostingController(rootView: content)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
                window.rootViewController = host; window.makeKeyAndVisible()
                host.traitOverrides.userInterfaceStyle = dark ? UIUserInterfaceStyle.dark : UIUserInterfaceStyle.light
                host.traitOverrides.preferredContentSizeCategory = category == .large ? UIContentSizeCategory.large : UIContentSizeCategory.accessibilityExtraExtraLarge
                try await Task.sleep(for: .seconds(mode == .board ? 2 : 1))
                host.view.layoutIfNeeded()
                XCTAssertEqual(host.view.bounds.width, width, accuracy: 1)
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "home-" + mode.rawValue + "-" + variant
                attachment.lifetime = .keepAlways; add(attachment)
                try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-home-\(mode.rawValue)-\(variant).png"))
                window.isHidden = true; window.rootViewController = nil
            }
        }
        print("Installed four-screen read-only acceptance: \(workspace.taskGroups.count) directories, \(tasks.count) tasks")
    }

    @MainActor
    func testInstalledChatAndHomeLayout() async throws {
        try await testInstalledFourLandingScreens()
        try await testInstalledConversationMenusAndComposer()
    }

    /// The real installed conversation, with native menus opened through UIControl's public action.
    /// This never sends a message or invokes a menu item.
    @MainActor
    func testInstalledConversationMenusAndComposer() async throws {
        guard let sessionID = try? String(contentsOfFile: "/tmp/wand-chat-menu-session", encoding: .utf8),
              let path = try? String(contentsOfFile: "/tmp/wand-mobile-home-acceptance-path", encoding: .utf8) else {
            throw XCTSkip("Requires explicit read-only session and installed-service pointers")
        }
        struct Connection: Decodable { let serverURL: String; let connectionCode: String }
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))))
        let url = try XCTUnwrap(URL(string: connection.serverURL))
        let decoded = try XCTUnwrap(WandAuth.decodeConnectCode(connection.connectionCode))
        let api = WandAPI(baseURL: url, token: decoded.token)
        let conversations = ConversationStore(api: api, drafts: SessionDraftStore())
        await conversations.refresh()
        defer { conversations.shutdown() }
        if UIApplication.shared.connectedScenes.isEmpty {
            UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
        }
        for _ in 0..<200 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func controls(_ view: UIView) -> [UIControl] {
            (view as? UIControl).map { [$0] } ?? view.subviews.flatMap(controls)
        }
        func editors(_ view: UIView) -> [UITextView] {
            (view as? UITextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        func save(_ window: UIWindow, _ name: String) throws {
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/wand-menu-\(name).png"))
        }
        for (variant, width, dark) in [("phone-light", CGFloat(402), false), ("phone-dark", 402, true), ("narrow", 320, false)] {
            let chat = ChatStore(sessionId: sessionID.trimmingCharacters(in: .whitespacesAndNewlines), api: api)
            let focus = ComposerFocusController()
            let keyboard = KeyboardObserver()
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            defer { chat.shutdown(); window.isHidden = true; window.rootViewController = nil }
            let homeHost = UIHostingController(rootView: ConversationListView(store: conversations, onSelect: { _ in }, onEmployee: { _ in }, onSettings: {}, onSwitchServer: {})
                .environment(\.colorScheme, dark ? .dark : .light).background(Theme.background))
            window.rootViewController = homeHost; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(700))
            let homeMenu = try XCTUnwrap(controls(homeHost.view).first { $0.showsMenuAsPrimaryAction })
            XCTAssertGreaterThanOrEqual(homeMenu.bounds.height, 44)
            XCTAssertLessThanOrEqual(homeMenu.bounds.height, 48, "More must not grow into an oversized primary capsule")
            homeMenu.performPrimaryAction()
            try await Task.sleep(for: .milliseconds(500))
            try save(window, "home-open-" + variant)
            homeMenu.contextMenuInteraction?.dismissMenu()
            try await Task.sleep(for: .milliseconds(300))
            let host = UIHostingController(rootView: NavigationStack {
                ChatView(sessionId: chat.sessionId, api: api, sharedStore: chat, focusController: focus)
            }.environment(\.colorScheme, dark ? .dark : .light))
            window.rootViewController = host
            for _ in 0..<200 {
                if chat.snapshot != nil && !chat.loading { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNotNil(chat.snapshot); XCTAssertNil(chat.loadError)
            try await Task.sleep(for: .milliseconds(500))
            try save(window, "chat-closed-" + variant)
            let menu = try XCTUnwrap(controls(host.view).first { $0.showsMenuAsPrimaryAction && $0.convert($0.bounds, to: window).midY < 200 })
            menu.performPrimaryAction()
            try await Task.sleep(for: .milliseconds(500))
            try save(window, "chat-open-" + variant)
            menu.contextMenuInteraction?.dismissMenu()
            // A native menu owns a temporary presentation window. Restore the test host only
            // after its dismissal has finished, before asking the editor to receive focus.
            try await Task.sleep(for: .seconds(1))
            window.makeKeyAndVisible()
            XCTAssertTrue(window.isKeyWindow)
            focus.focus()
            for _ in 0..<100 {
                if editors(host.view).contains(where: { $0.isFirstResponder && $0.bounds.height > 30 }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(editors(host.view).contains(where: { $0.isFirstResponder }), "Composer must actually receive keyboard focus")
            try await Task.sleep(for: .seconds(1))
            print("MENU-COMPOSER \(variant) key=\(window.isKeyWindow) focused=\(focus.focused) editing=\(focus.editing) keyboard=\(keyboard.isVisible)")
            XCTAssertTrue(focus.editing && editors(host.view).contains(where: { $0.isFirstResponder }), "Composer must retain focus after menu dismissal settles")
            if FileManager.default.fileExists(atPath: "/tmp/wand-menu-system-capture-enabled") {
                let checkpoint = "/tmp/wand-menu-system-capture-ready"
                try variant.write(toFile: checkpoint, atomically: true, encoding: .utf8)
                for _ in 0..<200 {
                    if !FileManager.default.fileExists(atPath: checkpoint) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint), "System screenshot must complete before the test window is dismissed")
            }
            try save(window, "chat-composer-" + variant)
            focus.collapse(); window.endEditing(true)
            for _ in 0..<100 {
                if !keyboard.isVisible { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    func testTemporaryExpansionOverridesCollapseAndRunningWithoutChangingDefault() throws {
        let idle = try summary(#"{"id":"idle","status":"idle"}"#)
        let running = try summary(#"{"id":"running","status":"running","inFlight":true}"#)
        for original in [HomeFoldMode.collapse, .running] {
            let expanded = HomePresentation.recentGroupFold(original, temporarilyExpanded: true)
            XCTAssertEqual(expanded, .expand)
            XCTAssertEqual(HomePresentation.sessions([idle, running], fold: expanded).count, 2)
            XCTAssertTrue(HomePresentation.recentGroupExpandsContent(expanded, visibleConversationCount: 2))
            XCTAssertEqual(HomePresentation.recentGroupFold(original, temporarilyExpanded: false), original)
        }
        let group = try XCTUnwrap(HomePresentation.recentGroups([try group([
            #"{"id":"s","employeeId":"real-id","employeeAvatar":"cat:2"}"#
        ])], employees: [], teams: []).first)
        XCTAssertEqual(group.employeeId, "real-id")
        XCTAssertTrue(HomePresentation.recentGroupShowsHeader(group, sectionFold: .expand, visibleConversationCount: 1))
        XCTAssertTrue(HomePresentation.recentGroupShowsHeader(group, sectionFold: .running, visibleConversationCount: 0))
        XCTAssertTrue(HomePresentation.recentGroupShowsHeader(group, sectionFold: .collapse, visibleConversationCount: 1))
    }

    func testCurrentEmptyAvatarMustNotReviveAnOldSnapshot() throws {
        let source = try group([#"{"id":"s","employeeId":"e","employeeAvatar":"cat:7"}"#])
        let employee = try decode(SiliconEmployee.self, #"{"id":"e","name":"员工","avatar":""}"#)
        XCTAssertEqual(HomePresentation.recentGroups([source], employees: [employee], teams: []).first?.avatar, "")
    }

    func testPixelCatMatchesAndroidPaletteAndStableUtf16Seed() {
        XCTAssertEqual(ContactCatAvatar.coatIndex(id: "any", avatar: "cat:9"), 1)
        XCTAssertEqual(ContactCatAvatar.coatIndex(id: "", avatar: ""), 6)
        XCTAssertEqual(ContactCatAvatar.grid(coat: 0)[2][1], 0xF0923A)
        XCTAssertEqual(ContactCatAvatar.grid(coat: 4)[3][3], 0x3F7FD8)
        XCTAssertEqual(ContactCatAvatar.grid(coat: 7)[5][4], 0xF28B9A)
        XCTAssertNil(ContactCatAvatar.grid(coat: 0)[0][0])
        XCTAssertEqual(ContactCatAvatar.rows.count, 10)
        XCTAssertTrue(ContactCatAvatar.rows.allSatisfy { $0.count == 10 })
        XCTAssertEqual(ContactCatAvatar.grid(coat: -1), ContactCatAvatar.grid(coat: 7))
    }

    func testEmployeeIdentityWinsOverTeamStepAndPty() throws {
        let session = try summary(#"{"id":"member","employeeId":"employee","sessionKind":"pty","provider":"pi","teamStep":{"runId":"run","title":"交付"}}"#)
        XCTAssertEqual(HomePresentation.identity(session).0, "employee:employee")
        XCTAssertEqual(HomePresentation.identity(session).1, .employee)
    }

    func testTeamsUseStableTeamIdAndLegacyRunFallback() throws {
        XCTAssertEqual(HomePresentation.identity(try summary(#"{"id":"chat","teamChat":{"runId":"run","teamId":"team"}}"#)).0, "team:team")
        XCTAssertEqual(HomePresentation.identity(try summary(#"{"id":"chat","teamChat":{"runId":"run"}}"#)).0, "team:run")
        XCTAssertEqual(HomePresentation.identity(try summary(#"{"id":"step","teamStep":{"runId":"run"}}"#)).0, "team-run:run")
    }

    func testRecentWindowDoesNotLoseOldOrRunningTerminals() throws {
        let sessions = (0..<12).map { #"{"id":"s\#($0)","employeeId":"e\#($0)","startedAt":"2026-10-04T10:\#(String(format: "%02d", $0)):00Z","sessionKind":"structured"}"# }
            + [#"{"id":"old-pty","sessionKind":"pty","provider":"pi","startedAt":"2020-01-01","ptyBusy":true,"status":"running"}"#]
        let groups = HomePresentation.recentGroups([try group(sessions)], employees: [], teams: [])
        XCTAssertEqual(groups.filter { $0.kind == .employee }.count, 8)
        XCTAssertEqual(groups.first { $0.kind == .pty }?.conversations.map(\.id), ["old-pty"])
        XCTAssertEqual(groups.last?.kind, .blankTerminal)
        // 工作区首页（对齐 Web 侧栏与安卓）传全量、不限八条：员工展开的是完整会话列表。
        let full = HomePresentation.recentGroups([try group(sessions)], employees: [], teams: [], limit: .max)
        XCTAssertEqual(full.filter { $0.kind == .employee }.count, 12)
    }

    func testRecentIdentitySurvivesRenameAndDefinitionDeletion() throws {
        let source = try group([#"{"id":"s","employeeId":"e","employeeName":"旧名","employeeAvatar":"cat:2","startedAt":"2026"}"#])
        let person = try decode(SiliconEmployee.self, #"{"id":"e","name":"新名","avatar":"cat:3"}"#)
        let current = HomePresentation.recentGroups([source], employees: [person], teams: []).first
        let historical = HomePresentation.recentGroups([source], employees: [], teams: []).first
        XCTAssertEqual(current?.id, historical?.id)
        XCTAssertEqual(current?.title, "新名")
        XCTAssertEqual(current?.avatar, "cat:3")
        XCTAssertEqual(historical?.title, "旧名")
    }

    func testCompletionIsKeptInActivityButNotRunningCount() throws {
        let done = try summary(#"{"id":"done","status":"idle","completionRevision":2,"viewedCompletionRevision":1}"#)
        XCTAssertTrue(HomePresentation.isActive(done))
        XCTAssertEqual(HomePresentation.pulse(done), .quiet)
        let groups = [try group([#"{"id":"done","status":"idle","completionRevision":2,"viewedCompletionRevision":1}"#])]
        XCTAssertEqual(HomePresentation.counts(groups).running, 0)
        XCTAssertEqual(HomePresentation.sessions([done], fold: .running).map(\.id), ["done"])
        XCTAssertTrue(HomePresentation.sessions([done], fold: .running, attentionOnly: true).isEmpty)
    }

    func testPermissionAndFailureNeedUserAndArchiveNeverCounts() throws {
        let sessions = [#"{"id":"permission","status":"idle","permissionBlocked":true}"#,
                        #"{"id":"failed","status":"failed"}"#,
                        #"{"id":"archived","status":"running","inFlight":true,"archived":true}"#]
        let counts = HomePresentation.counts([try group(sessions)])
        XCTAssertEqual(counts.needsYou, 2)
        XCTAssertEqual(counts.running, 0)
        XCTAssertFalse(HomePresentation.isActive(try summary(sessions[2])))
    }

    func testPtyIdleShellDoesNotCountAsRunning() throws {
        let session = try summary(#"{"id":"idle","sessionKind":"pty","provider":"pi","status":"running","ptyBusy":false,"providerCliActive":false}"#)
        XCTAssertEqual(HomePresentation.pulse(session), .quiet)
    }

    func testSearchRetainsTaskAndWorkspaceContext() throws {
        let source = try decode(TaskDirectoryGroup.self, #"{"workspaceId":"w","workspaceName":"Wand","workspaceCwd":"/work","tasks":[{"id":"task","workspaceId":"w","name":"修复上传","status":"active","createdAt":"","cwd":"/work","sessions":[{"id":"s1","employeeName":"虎妞","title":"保留草稿"},{"id":"s2","title":"别的"}]}],"standaloneSessions":[]}"#)
        let matched = HomePresentation.visibleGroups([source], query: "虎妞", attentionOnly: false)
        XCTAssertEqual(matched.first?.tasks.first?.sessions.map(\.id), ["s1"])
        XCTAssertEqual(matched.first?.tasks.first?.name, "修复上传")
        XCTAssertEqual(HomePresentation.visibleGroups([source], query: "修复上传", attentionOnly: false).first?.tasks.first?.sessions.count, 2)
        XCTAssertTrue(HomePresentation.visibleGroups([source], query: "没有的内容", attentionOnly: false).isEmpty)
    }

    func testRecentArchiveExclusionAndDeterministicEqualTimeOrder() throws {
        let source = try group([#"{"id":"b","startedAt":"2026"}"#, #"{"id":"a","startedAt":"2026"}"#, #"{"id":"hidden","startedAt":"2027","archived":true}"#])
        XCTAssertEqual(HomePresentation.conversations([source, source]).map(\.id), ["a", "b"])
    }

    func testWorkspaceCreationUsesNormalizedInputAndValidation() {
        var draft = WorkspaceCreateDraft()
        XCTAssertEqual(draft.validationError, "请填写工作区名称。")
        draft.name = "  Wand  "
        XCTAssertEqual(draft.validationError, "请选择工作目录。")
        draft.cwd = " /work/// "
        XCTAssertNil(draft.validationError)
        XCTAssertEqual(draft.normalizedName, "Wand")
        XCTAssertEqual(draft.normalizedCwd, "/work")
        draft.name = "Wand\n项目"
        XCTAssertNotNil(draft.validationError)
    }

    func testActivityUsesRuntimeFlagsAndForegroundCommandNotProcessLiveness() throws {
        for json in [
            #"{"id":"busy","status":"idle","ptyBusy":true}"#,
            #"{"id":"flight","status":"idle","sessionKind":"structured","inFlight":true}"#,
            #"{"id":"thinking","status":"thinking"}"#,
            #"{"id":"shell","sessionKind":"pty","status":"running","ptyCommandRunning":true}"#
        ] {
            let session = try summary(json)
            XCTAssertEqual(HomePresentation.pulse(session), .running)
            XCTAssertTrue(HomePresentation.isActive(session))
        }
        for json in [
            #"{"id":"prompt","sessionKind":"pty","status":"running"}"#,
            #"{"id":"exited","sessionKind":"pty","status":"exited","ptyCommandRunning":true}"#,
            #"{"id":"archived","inFlight":true,"archived":true}"#
        ] {
            XCTAssertFalse(HomePresentation.isActive(try summary(json)))
        }
    }

    func testSearchUsesCurrentEmployeeNameAndCrossFieldTerms() throws {
        let source = try group([#"{"id":"active","employeeId":"e","employeeName":"旧名","title":"修复目录","sessionKind":"structured","inFlight":true}"#,
                                #"{"id":"other","title":"其他"}"#])
        let person = try decode(SiliconEmployee.self, #"{"id":"e","name":"新名","avatar":""}"#)
        let result = HomePresentation.visibleGroups([source], query: "Wand 新名 修复", attentionOnly: false, employees: [person])
        XCTAssertEqual(result.first?.standaloneSessions.map(\.id), ["active"])
        XCTAssertEqual(source.standaloneSessions.count, 2)
        XCTAssertEqual(HomePresentation.sessions(result.first?.standaloneSessions ?? [], fold: .running).map(\.id), ["active"])
        XCTAssertTrue(HomePresentation.visibleGroups([source], query: "新名 missing", attentionOnly: false, employees: [person]).isEmpty)
    }

    func testInstalledWorkspaceProjectionWhenExplicitSnapshotIsProvided() throws {
        let path = "/tmp/wand-mobile-workspace-projection.json"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("Requires explicit read-only installed-service snapshot") }
        let source = try TaskGroupsPage.decode(from: Data(contentsOf: URL(fileURLWithPath: path))).groups
        let all = HomePresentation.conversations(source)
        let active = all.filter { $0.session.inFlight == true || $0.session.ptyBusy == true }
        XCTAssertFalse(active.isEmpty)
        let groups = HomePresentation.recentGroups(source, employees: [], teams: [], limit: .max)
        for item in active {
            XCTAssertTrue(HomePresentation.isActive(item.session))
            let identity = try XCTUnwrap(groups.first { $0.id == HomePresentation.identity(item.session).0 })
            XCTAssertTrue(HomePresentation.recentGroupShowsHeader(identity, sectionFold: .expand, visibleConversationCount: 1))
            XCTAssertTrue(identity.conversations.contains { $0.id == item.id })
            let query = [item.group.workspaceName, item.session.employeeName].compactMap { $0 }.joined(separator: " ")
            let directory = HomePresentation.visibleGroups(source, query: query, attentionOnly: false)
            XCTAssertTrue(HomePresentation.conversations(directory).contains { $0.id == item.id })
        }
        print("Installed workspace projection: \(all.count) sessions, \(active.count) executing verified")
    }

    private func summary(_ json: String) throws -> WorkspaceSessionSummary { try decode(WorkspaceSessionSummary.self, json) }
    private func group(_ sessions: [String]) throws -> TaskDirectoryGroup {
        try decode(TaskDirectoryGroup.self, "{\"workspaceId\":\"w\",\"workspaceName\":\"Wand\",\"workspaceCwd\":\"/work\",\"tasks\":[],\"standaloneSessions\":[" + sessions.joined(separator: ",") + "]}")
    }
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(json.data(using: .utf8)))
    }
}

private struct HomeSearchGeometryFixture: View {
    @State var value: String
    let category: ContentSizeCategory
    @FocusState private var focused: Bool

    var body: some View {
        HomeSearchField(placeholder: "搜索名字、职责、标签、团队成员", text: $value, focused: $focused)
            .environment(\.sizeCategory, category)
    }
}

@MainActor
private final class NativeFormProbe: ObservableObject {
    @Published var enabled = false
    @Published var disabled = true
    @Published var disabledWrites = 0
    @Published var primary = 0
    @Published var secondary = 0
    @Published var step = 2
    @Published var choice = "a"
    @Published var value = 0.5
}

private struct NativeFormFixture: View {
    @ObservedObject var probe: NativeFormProbe
    var finished: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
        Form {
            Section("系统控件") {
                Toggle("原生开关", isOn: $probe.enabled).accessibilityIdentifier("form-switch")
                Toggle("禁用开关", isOn: Binding(get: { probe.disabled }, set: { probe.disabledWrites += 1; probe.disabled = $0 }))
                    .disabled(true).accessibilityIdentifier("form-disabled")
                Stepper("数量：" + String(probe.step), value: $probe.step, in: 1...5).accessibilityIdentifier("form-stepper")
                Picker("系统选择器", selection: $probe.choice) { Text("选项 A").tag("a"); Text("选项 B").tag("b") }
                Slider(value: $probe.value).accessibilityLabel("系统滑杆")
            }
            Section("原生玻璃按钮") {
                Button("主按钮") { probe.primary += 1 }.buttonStyle(WandPrimaryButtonStyle()).accessibilityIdentifier("form-primary")
                Button("次按钮") { probe.secondary += 1 }.buttonStyle(WandSecondaryButtonStyle()).accessibilityIdentifier("form-secondary")
            }
        }
        HStack {
            Text("计数：" + String(probe.primary) + "/" + String(probe.secondary)).accessibilityIdentifier("form-counts")
            Text(probe.enabled ? "开关：开启" : "开关：关闭").accessibilityIdentifier("form-state")
        }.font(.caption)
        if let finished { Button("完成控件验收", action: finished).frame(minHeight: 44).accessibilityIdentifier("form-finish") }
        }.wandNativeFormControls()
    }
}

@MainActor
private final class HomeDockProbe: ObservableObject {
    @Published var mode = HomeListMode.im
    @Published var selections: [HomeListMode] = []
    @Published var blocked = false
    func select(_ next: HomeListMode) { mode = next; selections.append(next) }
}

private struct HomeDockFixture: View {
    @ObservedObject var probe: HomeDockProbe
    var finished: (() -> Void)? = nil
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Theme.background
                Theme.brand.opacity(0.14).frame(height: 90)
                Theme.success.opacity(0.14).frame(height: 90)
                Theme.brand.opacity(0.20).frame(height: 90)
            }
            VStack(spacing: 12) {
                Text("原生底部导航").font(.title2)
                Text("当前：" + probe.mode.label).accessibilityIdentifier("dock-state")
                Text("切换次数：" + String(probe.selections.count)).accessibilityIdentifier("dock-count")
                if let finished {
                    Button("完成导航验收", action: finished).frame(minHeight: 44).accessibilityIdentifier("dock-finish")
                    Button(probe.blocked ? "解锁导航" : "锁定导航") { probe.blocked.toggle() }
                        .frame(minHeight: 44).accessibilityIdentifier("dock-lock")
                }
                Spacer()
                HomeMenuPill(mode: probe.mode, onMode: probe.select, onContacts: { probe.select(.contacts) }, canSelect: { _ in !probe.blocked })
                    .padding(.horizontal, 12)
            }.padding(.top, 24)
        }.background(Theme.background)
    }
}

private struct HomeLongChatScrollFixture: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var probe: HomeScrollProbe
    let finished: () -> Void
    var body: some View {
        VStack {
            Text("偏移：\(probe.offset)").accessibilityIdentifier("chat-scroll-offset")
            ConversationListView(store: store, onSelect: { _ in }, onEmployee: { _ in }, onSettings: {}, onSwitchServer: {})
                .onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y) } action: { _, next in
                    probe.offset = next; probe.overflow = max(probe.overflow, next)
                }
            Button("完成长聊天滚动", action: finished).frame(minHeight: 44).accessibilityIdentifier("chat-scroll-finish")
        }
    }
}

@MainActor
private final class HomeScrollConversationService: ConversationService {
    var mutations = 0
    let rows: [ConversationInstance] = (0..<25).map { index in
        let data = try! JSONSerialization.data(withJSONObject: [
            "id": "scroll-chat-\(index)", "kind": "dm", "title": "聊天滚动 \(index)", "preview": "只读滚动回归样例"
        ])
        return try! JSONDecoder().decode(ConversationInstance.self, from: data)
    }
    func listContactEmployees() async throws -> [SiliconEmployee] { [] }
    func listContactTeams() async throws -> [ContactTeam] { [] }
    func listWorkspaces() async throws -> [Workspace] { [] }
    func conversations() async throws -> [ConversationInstance] { rows }
    func conversation(_ id: String) async throws -> ConversationInstance { rows[0] }
    func pendingConversationRequests() async -> [String] { [] }
    func conversationReceipt(_ id: String) async throws -> ConversationReceipt { throw URLError(.unsupportedURL) }
    func conversationPost(path: String, body: [String: Any]) async throws -> ConversationReceipt {
        mutations += 1; throw URLError(.unsupportedURL)
    }
    func updateConversationListState(_ id: String, patch: [String: Bool]) async throws -> ConversationInstance {
        mutations += 1; throw URLError(.unsupportedURL)
    }
    func deleteConversation(_ id: String) async throws { mutations += 1; throw URLError(.unsupportedURL) }
}

@MainActor
private final class HomeScrollProbe: ObservableObject {
    @Published var mode = HomeListMode.sessions
    @Published var offset = 0
    @Published var overflow = 0
}

private struct HomeInstalledScrollFixture: View {
    let api: WandAPI
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var contacts: ContactsStore
    @ObservedObject var conversations: ConversationStore
    @ObservedObject var probe: HomeScrollProbe
    let finished: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("首屏", selection: $probe.mode) {
                Text("工作区").tag(HomeListMode.sessions)
                Text("聊天").tag(HomeListMode.im)
                Text("通讯录").tag(HomeListMode.contacts)
                Text("任务").tag(HomeListMode.board)
            }.pickerStyle(.segmented).accessibilityIdentifier("installed-scroll-mode")
            Text("偏移：\(probe.offset) 溢出：\(probe.overflow)").font(.caption)
                .accessibilityIdentifier("installed-scroll-metrics")
            surface
            Button("完成真实滚动验收", action: finished).frame(minHeight: 44)
                .accessibilityIdentifier("installed-scroll-finish")
        }.background(Theme.background)
    }

    @ViewBuilder private var surface: some View {
        switch probe.mode {
        case .sessions:
            WorkspaceListView(store: workspace, api: api, selectedTaskId: nil,
                hidesHomeChrome: true, isSelecting: .constant(false), onOpenTask: { _, _ in },
                employees: contacts.employees, teams: contacts.teams)
        case .im:
            ConversationListView(store: conversations, onSelect: { _ in }, onEmployee: { _ in }, onSettings: {}, onSwitchServer: {})
        case .contacts:
            ContactsView(api: api, store: contacts, onBack: {}, onOpenSession: { _ in }, onOpenRun: { _ in },
                embedded: true, serverDisplayName: "当前服务器", onOpenSettings: {}, onSwitchServer: {})
        case .board:
            TaskBoardView(api: api, workspaceStore: workspace, onOpenSession: { _ in }, embedded: true)
        }
    }
}

private struct HomeScrollInteractionFixture: View {
    let finished: ([String: Int]) -> Void
    @State private var container = "list"
    @State private var revealed: String?
    @State private var offset = 0
    @State private var maximums: [String: Int] = [:]
    var body: some View {
        VStack(spacing: 8) {
            Picker("容器", selection: $container) {
                Text("List").tag("list")
                Text("ScrollView").tag("scroll")
            }.pickerStyle(.segmented).accessibilityIdentifier("scroll-container")
            Text("偏移：\(offset)").accessibilityIdentifier("scroll-offset")
            if container == "list" {
                List { rows }.listStyle(.plain)
                    .homeSwipeDismissal($revealed)
                    .onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y) } action: { _, next in track(next) }
            } else {
                ScrollView { LazyVStack(spacing: 4) { rows } }
                    .homeSwipeDismissal($revealed)
                    .onScrollGeometryChange(for: Int.self) { Int($0.contentOffset.y) } action: { _, next in track(next) }
            }
            Button("完成滚动验收") { finished(maximums) }.frame(minHeight: 44).accessibilityIdentifier("scroll-finish")
        }
        .background(Theme.background)
        .onChange(of: container) { _, _ in revealed = nil; offset = 0 }
    }
    private func track(_ next: Int) {
        offset = next; maximums[container] = max(maximums[container, default: 0], next)
    }
    private var rows: some View {
        ForEach(0..<35) { index in
            HomeSwipeRow(id: "row-\(index)", revealedID: $revealed, actions: [
                HomeRowAction(id: "open", title: "打开", symbol: "doc.text") {},
                HomeRowAction(id: "move", title: "移动", symbol: "folder") {}
            ]) {
                Button {} label: {
                    Text("滚动测试行 \(index)").frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.plain).background(Theme.surface)
                .accessibilityIdentifier("scroll-row-\(index)")
                .contextMenu { Button("保留长按") {} }
            }
        }
    }
}

private struct HomeSwipeInteractionFixture: View {
    let finished: (Int, [String]) -> Void
    @State private var revealed: String?
    @State private var count = 0
    @State private var visited: [String] = []

    var body: some View {
        VStack(spacing: 20) {
            Text("滑动交互验收").font(.title2)
            Text("动作执行次数：\(count)").accessibilityIdentifier("swipe-count")
            ForEach(["a", "b"], id: \.self) { id in
                HomeSwipeRow(id: id, revealedID: $revealed, actions: [
                    HomeRowAction(id: "view", title: "查看", symbol: "doc.text", tint: Theme.info) { count += 1 },
                    HomeRowAction(id: "mark", title: "标记", symbol: "checkmark", tint: Theme.success) { count += 1 },
                    HomeRowAction(id: "organize", title: "整理", symbol: "folder", tint: Theme.warning) { count += 1 }
                ]) {
                    Text("滑动列表项 " + id).font(.headline).frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                        .padding(.horizontal, 16).background(Theme.surface)
                        .accessibilityIdentifier("swipe-row-" + id)
                        .contextMenu { Button("保留的长按操作") {} }
                }
            }
            Button("完成滑动验收") { finished(count, visited) }.frame(minHeight: 44)
                .accessibilityIdentifier("swipe-finish")
            Spacer()
        }
        .padding(.top, 30).padding(.horizontal, 16).background(Theme.background)
        .homeSwipeDismissal($revealed)
        .onChange(of: revealed) { _, next in if let next { visited.append(next) } }
    }
}

@MainActor
private final class HomeNavigationDetailProbe: ObservableObject {
    @Published var detail = false
    @Published var text = "四种尺寸切换时保留这段未发送草稿。"
}

@MainActor
private final class AdaptiveNavigationFixtureState: ObservableObject {
    @Published var selection: String?
    @Published var parents: [String] = []
    @Published var draft = "原生列切换必须保留这份未发送草稿。"
    var back: (() -> Void)?
}

/// Exercises the production navigation container, including its native split
/// controller, rather than replacing navigation with an if/else detail fixture.
private struct AdaptiveNavigationFixture: View {
    @ObservedObject var state: AdaptiveNavigationFixtureState
    let systemNavigation: Bool
    var body: some View {
        AdaptiveNavigationContainer(selection: $state.selection, parents: $state.parents) {
            VStack(alignment: .leading, spacing: 20) {
                Text("工作区 · 首屏导航验收").font(.headline)
                Button("打开任务详情") { state.selection = "session" }.frame(minHeight: 44)
                Button("打开父级页面") { state.parents = ["parent"] }.frame(minHeight: 44)
                Text("没有选择任务时，任务列表必须可见且可以操作。")
                Spacer(minLength: 0)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.workspaceReading)
            .background(HomeNavigationGeometryMarker(identifier: "adaptive-sidebar"))
            .navigationTitle("工作区")
        } detail: { marker in
            AdaptiveNavigationFixtureDetail(state: state, marker: marker)
        }
        .environment(\.usesSystemHomeNavigation, systemNavigation)
    }
}

private struct AdaptiveNavigationFixtureDetail: View {
    @ObservedObject var state: AdaptiveNavigationFixtureState
    let marker: String?
    @Environment(\.systemHomeBack) private var back
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(marker == nil ? "选择一个任务" : marker == "parent" ? "父级页面" : "任务详情")
                .font(.headline)
            if marker != nil {
                Button("返回") { back?() }.frame(minHeight: 44)
                IMEAwareComposerTextView(text: $state.draft, placeholder: "保留草稿", isFocused: false,
                    submitOnReturn: false, onFocusChange: { _ in }, onCompositionChange: { _ in },
                    onSubmit: {}, onHeightChange: { _ in }).frame(height: 80)
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.workspaceReading)
        .background(HomeNavigationGeometryMarker(identifier: "adaptive-detail-" + (marker ?? "empty")))
        .navigationTitle(marker ?? "任务")
        .onAppear { state.back = back }
        .onChange(of: marker) { _, _ in state.back = back }
    }
}

private struct HomeNavigationDetailFixture: View {
    @ObservedObject var state: HomeNavigationDetailProbe
    var body: some View {
        SystemHomeNavigation(mode: .sessions, enabled: true, onSelect: { _ in }) {
            HomeSidebarLayout {
                Group {
                    if state.detail {
                        ChatDetailLayout {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("新建任务 · 尺寸回归样例").font(.headline)
                                    Text("验证输入区、安全区和导航显隐。此页面不发送消息。")
                                    ForEach(0..<8) { index in
                                        Text("阅读内容 \(index + 1)").frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.padding(16)
                            }
                        } composer: {
                            FocusComposerSurface(expanded: true, hasDraft: true, onFocus: {}, editor: {
                                IMEAwareComposerTextView(text: $state.text, placeholder: "输入内容", isFocused: false,
                                    submitOnReturn: false, onFocusChange: { _ in }, onCompositionChange: { _ in },
                                    onSubmit: {}, onHeightChange: { _ in })
                                    .frame(height: 44)
                            }, add: {
                                ComposerAddButton(expanded: false, uploading: false) {}
                            }, send: {
                                Button("发送", systemImage: "arrow.up") {}.labelStyle(.iconOnly).frame(width: 48, height: 48)
                            }, settings: {
                                ComposerSettingsStrip(model: "默认模型", mode: "标准", thinking: "自动",
                                    onModel: {}, onMode: {}, onThinking: {})
                            }, isEmbeddedInDock: true, actionCount: 1)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.workspaceInputDock)
                                .background(HomeNavigationGeometryMarker(identifier: "home-preference-detail-dock"))
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("工作区 · 尺寸回归样例").font(.headline)
                                ForEach(0..<20) { index in
                                    Text("任务 \(index + 1)").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                            }.padding(16)
                        }.background(Theme.background)
                    }
                }.homeNavigationHidden(state.detail)
            } navigation: {
                HomeMenuPill(mode: .sessions, onMode: { _ in }, onContacts: {})
                    .background(HomeNavigationGeometryMarker(identifier: "home-preference-inline-dock"))
            }
        }
    }
}

private struct HomeNavigationGeometryMarker: UIViewRepresentable {
    let identifier: String
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.accessibilityIdentifier = identifier; view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

@MainActor
private func homeNavigationControllers(_ root: UIViewController) -> [UIViewController] {
    [root] + root.children.flatMap(homeNavigationControllers)
}

@MainActor
private func homeNavigationBarItems(_ item: UINavigationItem) -> [UIBarButtonItem] {
    (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) +
        item.leadingItemGroups.flatMap(\.barButtonItems) + item.trailingItemGroups.flatMap(\.barButtonItems) +
        (item.pinnedTrailingGroup?.barButtonItems ?? [])
}

@MainActor
private func homeStandaloneFileBarItems(_ item: UINavigationItem) -> [UIBarButtonItem] {
    homeNavigationBarItems(item).filter { button in
        guard button.menu == nil else { return false }
        let labels = [button.title, button.accessibilityLabel, button.primaryAction?.title,
                      button.customView?.accessibilityLabel].compactMap { $0 }
        return labels.contains("会话文件") || labels.contains("对话文件") ||
            button.image?.isEqual(UIImage(systemName: "folder")) == true
    }
}

@MainActor
private func homeMenuControls(_ view: UIView) -> [UIControl] {
    (view as? UIControl).map { [$0] } ?? view.subviews.flatMap(homeMenuControls)
}

@MainActor
private func homeMenuTree(_ element: UIMenuElement) -> [UIMenuElement] {
    [element] + ((element as? UIMenu)?.children.flatMap(homeMenuTree) ?? [])
}

@MainActor
private func homePresentedControllers(_ root: UIViewController) -> [UIViewController] {
    [root] + root.children.flatMap(homePresentedControllers) +
        (root.presentedViewController.map(homePresentedControllers) ?? [])
}

@MainActor
private func homeNavigationMarker(_ identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier { return root }
    return root.subviews.lazy.compactMap { homeNavigationMarker(identifier, in: $0) }.first
}

/// A mounted controller may be hidden, clipped, or offscreen. Limit visibility to
/// the explicit child viewport, not the differently sized physical test window.
@MainActor
private func homeEffectiveVisibleFrame(_ view: UIView, in root: UIView) -> CGRect {
    var visible = view.convert(view.bounds, to: root)
    var ancestor: UIView? = view
    while let current = ancestor {
        guard !current.isHidden, current.alpha > 0.01 else { return .null }
        if current === root { return visible.intersection(root.bounds) }
        if current.clipsToBounds { visible = visible.intersection(current.convert(current.bounds, to: root)) }
        ancestor = current.superview
    }
    return .null
}

@MainActor
private func homeNavigationEditors(_ root: UIView) -> [UITextView] {
    (root as? UITextView).map { [$0] } ?? root.subviews.flatMap(homeNavigationEditors)
}

final class ChatFillGeometryProbe {
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0
    var reported = false
}

/// 与 `ChatView.messageList` 同构的最小首屏：短内容 + 底部锚点，固定在 390×600 视口里测几何。
private struct ChatFillViewportFixture: View {
    let probe: ChatFillGeometryProbe
    let onFirstHeight: () -> Void

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("最新的一条回复只有一行").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, new in
                probe.contentHeight = new
                probe.viewportHeight = viewport.size.height
                onFirstHeight()
            }
        }
        .frame(width: 390, height: 600)
    }
}

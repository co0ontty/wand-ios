import XCTest
import SwiftUI
import UIKit
@testable import Wand

@MainActor
final class LiveActivityExperienceTests: XCTestCase {
    private func entry(_ id: String, state: String, title: String = "任务") -> SessionActivityAttributes.SessionEntry {
        .init(id: id, serverID: "server-a", title: title, providerRaw: "pi", stateRaw: state, taskTitle: "任务", queuedCount: 0)
    }
    func testAttentionAndFailureWinWithoutCallingThemCompleted() {
        let state = SessionActivityAttributes.ContentState(sessions: [entry("r", state: "responding"), entry("f", state: "failed"), entry("w", state: "waiting-input")], updatedAt: .now)
        XCTAssertEqual(state.primarySession?.id, "w"); XCTAssertEqual(state.attentionCount, 2)
        XCTAssertEqual(state.compactText(isStale: false), "等你2")
        XCTAssertEqual(state.compactText(isStale: true), "离线")
        XCTAssertEqual(SessionActivityAttributes.ContentState(sessions: [entry("f", state: "failed")], updatedAt: .now).aggregateStateRaw, "failed")
    }
    func testEntryShowsDistinctInputBackgroundStoppedAndSDKIdentity() {
        XCTAssertEqual(entry("w", state: "waiting-input").primaryDetail, "需要你的回复后继续")
        XCTAssertEqual(entry("b", state: "background").primaryDetail, "等待子任务结束")
        XCTAssertEqual(entry("s", state: "stopped").statusText, "已停止")
        var sdk = entry("p", state: "responding"); sdk.engineRaw = "core"; XCTAssertEqual(sdk.providerText, "Wand Agent")
        sdk.engineRaw = "cli"; XCTAssertEqual(sdk.providerText, "Pi")
        XCTAssertEqual(entry("p", state: "responding").primaryDetail, "正在处理", "不重复相同标题")
    }
    func testPreciseLinksPreserveServerAndMultiActivityUsesList() {
        var one = entry("session/特殊", state: "responding"); one.serverID = "server with space"
        let c = URLComponents(url: one.destinationURL, resolvingAgainstBaseURL: false)
        XCTAssertEqual(c?.queryItems?.first?.value, "server with space")
        XCTAssertEqual(SessionActivityAttributes.ContentState(sessions: [one], updatedAt: .now).destinationURL, one.destinationURL)
        let multi = SessionActivityAttributes.ContentState(sessions: [one, entry("b", state: "permission")], updatedAt: .now)
        XCTAssertEqual(multi.destinationURL.absoluteString, "wand://live-activity")
    }
    func testUnicodeBudgetDoesNotSplitEmojiAndStaysBelowActivityKitLimit() throws {
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 40)
        let label = activityBoundedText(family, maxCharacters: 40, maxBytes: 120)
        XCTAssertLessThanOrEqual(label.utf8.count, 120); XCTAssertFalse(label.isEmpty)
        let entries = (0..<8).map { i -> SessionActivityAttributes.SessionEntry in
            var x = entry("id-\(i)", state: "responding", title: activityBoundedText(family, maxCharacters: 24, maxBytes: 96))
            x.taskTitle = label; return x
        }
        let data = try JSONEncoder().encode(SessionActivityAttributes.ContentState(sessions: entries, updatedAt: .now))
        XCTAssertLessThan(data.count, 4096)
    }
    func testStructuredClockAndPhaseAreServerFactsNotWidgetMountTime() throws {
        let json = #"{"id":"s","sessionKind":"structured","status":"running","structuredState":{"inFlight":true,"phase":"background","turnStartedAt":"2026-10-09T00:00:00Z","engine":"core"}}"#
        let s = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.structuredState?.phase, "background")
        XCTAssertEqual(SessionTimeFormatting.date(from: s.structuredState?.turnStartedAt)?.timeIntervalSince1970, 1791504000)
    }
    func testRefinedPresentationKeepsStateAndStalenessUnambiguous() {
        let waiting = SessionActivityAttributes.ContentState(sessions: [entry("w", state: "permission")], updatedAt: .now)
        XCTAssertEqual(ActivityPresentation.status(waiting, isStale: false), "待授权")
        XCTAssertEqual(ActivityPresentation.status(waiting, isStale: true), "已过期")
        XCTAssertEqual(ActivityPresentation.detail(waiting.sessions[0], isStale: true), "打开 Wand 重新连接")
        XCTAssertEqual(ActivityLayout.touch, 44)
        XCTAssertEqual(ActivityLayout.inset, 16)
    }
    func testRefinedNativeActivityVisualMatrix() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let now = Date(timeIntervalSince1970: 1791504000)
        var running = entry("run", state: "responding", title: "优化工作区与会话导航")
        running.taskTitle = "校验列表展开与输入恢复"; running.startedAt = now; running.queuedCount = 2
        var long = entry("wait", state: "waiting-input", title: "核对 iOS 客户端的权限、工作区及团队协作流程")
        long.taskTitle = "等待确认"; long.engineRaw = "core"
        let rows: [(String, SessionActivityAttributes.ContentState, String, CGFloat, ContentSizeCategory, Bool)] = [
            ("expanded-running", .init(sessions: [running], updatedAt: now), "expanded", 370, .large, false),
            ("expanded-multi-long", .init(sessions: [long, running], updatedAt: now), "expanded", 370, .large, false),
            ("expanded-narrow", .init(sessions: [long, running], updatedAt: now), "expanded", 320, .large, false),
            ("lockscreen-running", .init(sessions: [running], updatedAt: now), "lockscreen", 390, .large, false),
            ("lockscreen-permission", .init(sessions: [entry("p", state: "permission", title: "确认项目目录的访问权限")], updatedAt: now), "lockscreen", 390, .large, false),
            ("lockscreen-failed", .init(sessions: [entry("f", state: "failed", title: "模型与执行工具检查")], updatedAt: now), "lockscreen", 390, .large, false),
            ("lockscreen-done", .init(sessions: [entry("d", state: "done", title: "客户端回归测试")], updatedAt: now), "lockscreen", 390, .large, false),
            ("lockscreen-stale-refined", .init(sessions: [running, long], updatedAt: now), "lockscreen", 390, .large, true),
            ("lockscreen-accessibility-refined", .init(sessions: [long, running], updatedAt: now), "lockscreen", 390, .accessibilityExtraExtraLarge, false),
            ("compact-running-refined", .init(sessions: [running], updatedAt: now), "compact", 160, .large, false),
            ("compact-multi-refined", .init(sessions: [long, running], updatedAt: now), "compact", 160, .large, false),
            ("minimal-failed-refined", .init(sessions: [entry("f", state: "failed")], updatedAt: now), "minimal", 44, .large, false),
        ]
        for (name, state, surface, width, type, stale) in rows {
            let content = Group {
                if surface == "expanded" {
                    VStack(alignment: .leading, spacing: ActivityLayout.group) {
                        ActivityExpandedHeader(state: state, isStale: stale)
                        ActivityExpandedSummary(state: state, isStale: stale)
                    }.padding(ActivityLayout.inset)
                } else if surface == "compact" {
                    HStack { ActivityCompactIdentity(state: state, isStale: stale); Spacer(minLength: 50); ActivityCompactStatus(state: state, isStale: stale) }.padding(8)
                } else if surface == "minimal" { ActivityMinimalStatus(state: state, isStale: stale).padding(10) }
                else { ActivityLockScreenView(state: state, isStale: stale) }
            }.foregroundStyle(.white).background(.black).environment(\.colorScheme, .dark).environment(\.sizeCategory, type).ignoresSafeArea()
            let host = UIHostingController(rootView: content), window = UIWindow(windowScene: scene)
            host.safeAreaRegions = []
            host.traitOverrides.userInterfaceStyle = .dark
            host.traitOverrides.preferredContentSizeCategory = type == .accessibilityExtraExtraLarge ? .accessibilityExtraExtraLarge : .large
            let natural = host.sizeThatFits(in: CGSize(width: width, height: 900))
            XCTAssertLessThanOrEqual(natural.width, width + 1)
            let size = CGSize(width: width, height: max(surface == "compact" || surface == "minimal" ? 44 : 80, ceil(natural.height)))
            window.frame = CGRect(origin: .zero, size: size); window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 140_000_000)
            let image = UIGraphicsImageRenderer(size: size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertNotNil(image.pngData()); window.isHidden = true
        }
    }
    func testSharedNativeActivityLayoutsInCompactExpandedAndLargeType() async throws {
        let state = SessionActivityAttributes.ContentState(sessions: [entry("w", state: "waiting-input", title: "确认工作区与权限"), entry("r", state: "responding", title: "客户端界面对齐")], updatedAt: .now)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for (name, size, large) in [("island-expanded", CGSize(width: 370, height: 180), false), ("lockscreen-large", CGSize(width: 390, height: 360), true), ("lockscreen-stale", CGSize(width: 390, height: 300), false)] {
            let content = Group {
                if name == "island-expanded" {
                    VStack(alignment: .leading, spacing: ActivityLayout.group) { ActivityExpandedHeader(state: state, isStale: false); ActivityExpandedSummary(state: state, isStale: false) }.padding(ActivityLayout.inset)
                } else { ActivityLockScreenView(state: state, isStale: name == "lockscreen-stale") }
            }.foregroundStyle(.white).background(.black).environment(\.colorScheme, .dark).environment(\.sizeCategory, large ? .accessibilityExtraExtraLarge : .large)
            let host = UIHostingController(rootView: content), window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size); window.rootViewController = host; window.makeKeyAndVisible(); host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 120_000_000)
            let image = UIGraphicsImageRenderer(size: size).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertEqual(image.size, size); window.isHidden = true
        }
    }
}

import Foundation
import XCTest
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import Wand

@MainActor final class KnowledgeLibraryTests: XCTestCase {
    func testOwnerQueryPreservesPlusPercentUnicodeAndEndpointPrefix() throws {
        let owner = "project+a% 空间&x=1"
        let path = try XCTUnwrap(WandAPI.knowledgeLibraryPath(scope: .project, ownerId: owner))
        let url = try XCTUnwrap(WandEndpoint.url(baseURL: URL(string: "https://wand.test/prefix")!, route: path))
        XCTAssertEqual(url.path, "/prefix/api/knowledge")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertTrue(query.contains("%2B")); XCTAssertFalse(query.contains("+"))
        let field = try XCTUnwrap(query.split(separator: "&").first { $0.hasPrefix("ownerId=") })
        let decoded = String(field.dropFirst("ownerId=".count)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        XCTAssertEqual(decoded, owner)
    }
    func testDraftLimitsAndFolderProjection() {
        var draft = KnowledgeDraft(scope: .personal, ownerId: "a", original: nil, title: "偏好", content: String(repeating: "知", count: 12000), folder: "")
        XCTAssertNil(draft.validation)
        draft.content += "识"
        XCTAssertNotNil(draft.validation)
        XCTAssertEqual(KnowledgeFixture.document().directoryName, "未分类")
    }
    func testEmployeeAndProjectSelectionAreSeparate() async {
        let store = KnowledgeLibraryStore(service: KnowledgeFixture())
        await store.loadIfNeeded()
        XCTAssertEqual(store.scope, .project); XCTAssertEqual(store.ownerId, "p")
        store.changeScope(.personal)
        await settle(store)
        XCTAssertEqual(store.ownerId, "a"); XCTAssertEqual(store.selected?.ownerId, "a")
        store.changeOwner("b"); await settle(store)
        XCTAssertEqual(store.selected?.ownerId, "b")
        store.changeScope(.project); await settle(store)
        XCTAssertEqual(store.selected?.ownerId, "p")
    }
    func testSwitchAndBackRequireExplicitDiscard() async {
        let store = KnowledgeLibraryStore(service: KnowledgeFixture(), scope: .personal)
        await store.loadIfNeeded(); store.edit(); store.draft?.content = "未保存的新内容"
        store.changeOwner("b")
        XCTAssertTrue(store.showDiscard); XCTAssertEqual(store.ownerId, "a")
        store.continueEditing(); XCTAssertEqual(store.draft?.content, "未保存的新内容")
        store.changeOwner("b"); store.discardAndContinue(); await settle(store)
        XCTAssertEqual(store.ownerId, "b"); XCTAssertNil(store.draft)
    }
    func testConflictRefreshKeepsDraftAndOriginalRevision() async {
        let fixture = KnowledgeFixture(); fixture.saveFailure = WandAPI.APIError.server(status: 409, message: "changed")
        let store = KnowledgeLibraryStore(service: fixture, scope: .personal)
        await store.loadIfNeeded(); store.edit(); store.draft?.content = "我的编辑"
        await store.save()
        XCTAssertTrue(store.conflict); XCTAssertEqual(store.draft?.content, "我的编辑")
        fixture.revision = 2
        await store.loadLibrary(preserveDraft: true)
        XCTAssertEqual(store.selected?.revision, 2)
        XCTAssertEqual(store.draft?.original?.revision, 1)
        XCTAssertEqual(store.draft?.content, "我的编辑")
    }
    func testSaveFailurePreservesInputAndSuccessfulReceiptRemainsVisibleIfRefreshFails() async {
        let fixture = KnowledgeFixture()
        let store = KnowledgeLibraryStore(service: fixture)
        await store.loadIfNeeded(); store.create(); store.draft?.title = "新文档"; store.draft?.content = "内容"
        fixture.saveFailure = WandAPI.APIError.network("offline")
        await store.save(); XCTAssertEqual(store.draft?.content, "内容")
        fixture.saveFailure = nil; fixture.failReadsAfterSave = true
        await store.save()
        XCTAssertNil(store.draft); XCTAssertEqual(store.selected?.title, "新文档")
        XCTAssertNotNil(store.error)
    }
    func testMissingRequestedEmployeeNeverFallsBackToAnotherEmployee() async {
        let store = KnowledgeLibraryStore(service: KnowledgeFixture(), scope: .personal, ownerId: "deleted")
        await store.loadIfNeeded()
        XCTAssertEqual(store.ownerId, "deleted"); XCTAssertNil(store.page); XCTAssertNotNil(store.error)
    }
    func testLateReadCannotReplaceNewOwner() async {
        let fixture = KnowledgeFixture(); fixture.delayOwner = "a"
        let store = KnowledgeLibraryStore(service: fixture, scope: .personal)
        let initial = Task { await store.loadIfNeeded() }
        for _ in 0..<100 where fixture.pending == nil { await Task.yield() }
        XCTAssertNotNil(fixture.pending)
        store.changeOwner("b"); await settle(store)
        fixture.pending?.resume(returning: fixture.page(scope: .personal, ownerId: "a")); fixture.pending = nil
        await initial.value
        XCTAssertEqual(store.ownerId, "b"); XCTAssertEqual(store.selected?.ownerId, "b")
    }
    func testReadonlyProjectBlocksEditingButSupportsExplicitDelete() async {
        let fixture = KnowledgeFixture(); fixture.readOnly = true
        let store = KnowledgeLibraryStore(service: fixture)
        await store.loadIfNeeded(); store.create(); XCTAssertNil(store.draft)
        store.edit(); XCTAssertNil(store.draft)
        store.deleteCandidate = store.selected; await store.deleteConfirmed(store.selected!)
        XCTAssertEqual(fixture.deleted?.ownerId, "p")
    }
    func testNativeDocumentWorkspaceFitsNarrowAndWideScreens() async throws {
        let store = KnowledgeLibraryStore(service: KnowledgeFixture())
        await store.loadIfNeeded()
        for width in [375.0, 1024.0] {
#if os(macOS)
            let host = NSHostingView(rootView: KnowledgeLibraryView(store: store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.orderFront(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, width)
            let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: representation)
            let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/wand-knowledge-macos-\(Int(width)).png"))
            window.orderOut(nil)
#else
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let host = UIHostingController(rootView: KnowledgeLibraryView(store: store))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 760)
            window.rootViewController = host; window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 100_000_000)
            host.view.layoutIfNeeded()
            XCTAssertEqual(host.view.bounds.width, width)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            XCTAssertEqual(image.size.width, width)
            let attachment = XCTAttachment(image: image); attachment.name = "knowledge-ios-\(Int(width))"; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; window.rootViewController = nil
#endif
        }
    }
    func testKnowledgeRootUsesFullWidthInsteadOfWorkspaceSidebarColumn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var measuredWidth: CGFloat = 0
        let host = UIHostingController(rootView: AdaptiveNavigationContainer(
            selection: .constant(nil), parents: .constant([]), fullWidthRoot: true,
            sidebar: { KnowledgeWidthProbe(onLayout: { measuredWidth = $0 }) },
            detail: { _ in Text("Workspace detail must not appear") }
        ))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 760)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(measuredWidth, 720, "Knowledge owns its directory and document; do not confine it to the workspace sidebar")
    }
    private func settle(_ store: KnowledgeLibraryStore) async {
        for _ in 0..<100 { await Task.yield(); if !store.loading && store.page?.ownerId == store.ownerId { return } }
    }
}

private final class KnowledgeFixture: KnowledgeService {
    var saveFailure: Error?
    var revision = 1
    var readOnly = false
    var failReadsAfterSave = false
    var saved = false
    var deleted: KnowledgeDocument?
    var delayOwner: String?
    var pending: CheckedContinuation<KnowledgeLibraryPage, Error>?
    static func document(scope: KnowledgeScope = .project, ownerId: String = "p", title: String = "文档式知识库", content: String = "# 长期知识\n\n这里保留经用户确认的内容。", revision: Int = 1) -> KnowledgeDocument {
        KnowledgeDocument(id: ownerId + "-doc", scope: scope, ownerId: ownerId, title: title, content: content, folder: "", revision: revision, createdAt: "2026-10-27T00:00:00.000Z", updatedAt: "2026-10-27T00:00:00.000Z")
    }
    func knowledgeOwners() async throws -> KnowledgeOwners {
        KnowledgeOwners(employees: [KnowledgeOwner(id: "a", name: "员工 A"), KnowledgeOwner(id: "b", name: "员工 B")], projects: [KnowledgeOwner(id: "p", name: "项目", readOnly: readOnly)])
    }
    func page(scope: KnowledgeScope, ownerId: String) -> KnowledgeLibraryPage {
        let docs = deleted == nil ? [Self.document(scope: scope, ownerId: ownerId, revision: revision)] : []
        return KnowledgeLibraryPage(scope: scope, ownerId: ownerId, ownerName: "知识库", readOnly: readOnly, entries: docs, total: docs.count, limit: 200)
    }
    func knowledgeLibrary(scope: KnowledgeScope, ownerId: String) async throws -> KnowledgeLibraryPage {
        if saved && failReadsAfterSave { throw WandAPI.APIError.network("refresh offline") }
        if delayOwner == ownerId { return try await withCheckedThrowingContinuation { pending = $0 } }
        return page(scope: scope, ownerId: ownerId)
    }
    func saveKnowledge(_ draft: KnowledgeDraft) async throws -> KnowledgeDocument {
        if let saveFailure { throw saveFailure }
        saved = true
        return Self.document(scope: draft.scope, ownerId: draft.ownerId, title: draft.title, content: draft.content, revision: revision + 1)
    }
    func deleteKnowledge(_ document: KnowledgeDocument) async throws { deleted = document }
}

private struct KnowledgeWidthProbe: UIViewRepresentable {
    let onLayout: (CGFloat) -> Void
    final class Probe: UIView {
        var onLayout: ((CGFloat) -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); onLayout?(bounds.width) }
    }
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.onLayout = onLayout; return view }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.onLayout = onLayout }
}

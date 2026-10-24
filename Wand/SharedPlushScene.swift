import SwiftUI
import WebKit

enum AvatarFileActivity: String { case idle, reading, writing }

func avatarIsThinking(messages: [ConversationTurn], executing: Bool) -> Bool {
    guard executing else { return false }
    let start = messages.lastIndex(where: { $0.role == "user" }).map { $0 + 1 } ?? 0
    guard let turn = messages.dropFirst(start).last(where: { $0.role == "assistant" }), turn.completedAt == nil,
          let block = turn.content.last else { return false }
    if case .thinking = block { return true }
    return false
}

func avatarFileActivity(messages: [ConversationTurn], executing: Bool) -> AvatarFileActivity {
    guard executing else { return .idle }
    let start = messages.lastIndex(where: { $0.role == "user" }).map { $0 + 1 } ?? 0
    var calls: [(String, AvatarFileActivity)] = []
    var completed = Set<String>()
    for turn in messages.dropFirst(start) {
        for block in turn.content {
            switch block {
            case .toolResult(let id, _, _, _, _, let subagent, _):
                if subagent == nil { completed.insert(id) }
            case .toolUse(let id, _, _, let input, let subagent):
                guard subagent == nil, turn.completedAt == nil,
                      case .object(let activity)? = input["__wandToolActivity"],
                      case .string(let kind)? = activity["kind"], ["read_file", "edit_file"].contains(kind) else { continue }
                let value: AvatarFileActivity = kind == "read_file" ? .reading : .writing
                if let index = calls.firstIndex(where: { $0.0 == id }) { calls[index].1 = value }
                else { calls.append((id, value)) }
            default: break
            }
        }
    }
    return calls.reversed().first(where: { !completed.contains($0.0) })?.1 ?? .idle
}

/// One off-line scene above the composer. Static lists never allocate WebKit.
struct SharedPlushScene: UIViewRepresentable {
    let id: String
    let name: String
    let avatar: String
    var activity: AvatarFileActivity = .idle
    var thinking = false
    var speaking = false
    var paused = false
    var reduced = false
    var size: CGFloat = 72
    @Binding var rendered: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "wandScene")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false; view.backgroundColor = .clear
        view.underPageBackgroundColor = .clear
        view.clipsToBounds = false
        view.scrollView.clipsToBounds = false
        view.scrollView.backgroundColor = .clear; view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false; view.accessibilityElementsHidden = true
        view.navigationDelegate = context.coordinator
        context.coordinator.update = payload
        context.coordinator.onRendered = { rendered = $0 }
        if let url = Bundle.main.url(forResource: "scene", withExtension: "html", subdirectory: "PlushScene") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }
    private var payload: String {
        let value: [String: Any] = ["id": id, "name": name, "avatar": avatar, "activity": activity.rawValue,
                                  "thinking": thinking && activity == .idle, "speaking": speaking, "paused": paused, "reduced": reduced, "size": size]
        return String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.update != payload else { return }
        context.coordinator.update = payload
        context.coordinator.render(view)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
#if DEBUG
        coordinator.probe?.invalidate()
#endif
        view.evaluateJavaScript("window.wandDispose?.()")
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "wandScene")
        coordinator.onRendered = { _ in }
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var update = "{}"
        var loaded = false
        var onRendered: (Bool) -> Void = { _ in }
        var renderer: String?
#if DEBUG
        var probe: Timer?
        var observations: [[String: Any]] = []
        func startProbe(_ view: WKWebView) {
            guard ProcessInfo.processInfo.environment["WAND_DEBUG_CHAT_DESIGN"] == "1" else { return }
            probe = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak view] timer in
                guard let self, let view, self.observations.count < 200 else { timer.invalidate(); return }
                view.evaluateJavaScript("""
                    (()=>{let c=document.querySelector('canvas'),ctx=c?.getContext('2d');if(!ctx)return null;let d=ctx.getImageData(0,0,c.width,c.height).data,n=0;for(let i=3;i<d.length;i+=64){if(d[i]>30)n++}return {...c.dataset,renderer:document.documentElement.dataset.renderer,opaqueSamples:n,width:c.width,height:c.height,thoughtVisible:getComputedStyle(document.querySelector('#thought')).display!=='none'}})()
                    """) { value, _ in
                    guard var value = value as? [String: Any] else { return }
                    value["time"] = Date().timeIntervalSince1970
                    self.observations.append(value)
                    if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("scene-observations.json"),
                       let data = try? JSONSerialization.data(withJSONObject: self.observations, options: [.sortedKeys]) {
                        try? data.write(to: url, options: .atomic)
                    }
                }
            }
        }
#endif
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "wandScene", let value = message.body as? String, ["webgl", "fallback"].contains(value) else { return }
            guard renderer != value else { return }
            renderer = value
            onRendered(value == "webgl")
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true; render(webView)
#if DEBUG
            startProbe(webView)
#endif
        }
        func render(_ view: WKWebView) {
            guard loaded else { return }
            view.evaluateJavaScript("window.wandUpdate(\(update));document.documentElement.dataset.renderer") { [weak self] value, error in
                // Same identity's PNG remains beneath the transparent scene on GPU failure.
                view.isHidden = error != nil || (value as? String) == "fallback"
                self?.onRendered((value as? String) == "webgl" && error == nil)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.isHidden = true; onRendered(false) }
    }
}

struct WorkingAvatar: View {
    let id: String
    let name: String
    let avatar: String
    var activity: AvatarFileActivity = .idle
    var thinking = false
    var speaking = false
    var size: CGFloat = 72
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var visible = false
    @State private var rendered = false
    var body: some View {
        ZStack {
            ContactAvatar(id: id, avatar: avatar, size: size, name: name)
                .opacity(rendered ? 0 : 1)
            if PlushAvatarIdentity.asset(id: id, name: name, avatar: avatar) != nil {
                SharedPlushScene(id: id, name: name, avatar: avatar, activity: activity,
                                 thinking: thinking, speaking: speaking, paused: !visible || scene != .active, reduced: reduced, size: size, rendered: $rendered)
            }
        }.frame(width: size, height: size).accessibilityHidden(true).allowsHitTesting(false)
            .onAppear { visible = true }.onDisappear { visible = false }
    }
}

/// Web's 72/60/84 avatar relationship, with native content-sized status space.
/// The reserved lane belongs to the bottom stack, so it never covers messages.
struct FloatingComposerCompanion<Status: View, Composer: View>: View {
    let id: String
    let name: String
    let avatar: String
    var activity: AvatarFileActivity = .idle
    var thinking = false
    var speaking = false
    @ViewBuilder let status: () -> Status
    @ViewBuilder let composer: () -> Composer
    var body: some View {
        VStack(spacing: 0) {
            status().frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 96).padding(.trailing, 14).padding(.bottom, 4)
                .frame(minHeight: 60, alignment: .bottomLeading)
            composer()
        }
        .overlay(alignment: .topLeading) {
            WorkingAvatar(id: id, name: name, avatar: avatar, activity: activity,
                          thinking: thinking, speaking: speaking)
                .padding(.leading, 12).allowsHitTesting(false)
        }
    }
}

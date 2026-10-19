import SwiftUI
import UIKit

/// One endpoint-bound owner for automatic checks, Settings and installer handoff.
/// iOS never reports the eventual installation result to this process.
@MainActor
final class AppUpdateController: ObservableObject {
    typealias Fetch = (String) async throws -> IosIpaUpdateInfo
    typealias Open = (URL, @escaping (Bool) -> Void) -> Void
    @Published private(set) var info: IosIpaUpdateInfo?
    @Published private(set) var checking = false
    @Published private(set) var opening = false
    @Published private(set) var error: String?
    @Published private(set) var dismissedVersion: String?
    @Published private(set) var handoffMessage: String?
    private var openTimeout: Task<Void, Never>?

    let currentVersion: String
    let bundleID: String
    private let fetch: Fetch
    private let open: Open
    private let report: (Error) -> Void
    private let handoffTimeout: UInt64
    private let interval: UInt64
    private var monitor: Task<Void, Never>?
    private var revision = 0
    private var handoffAttempt = 0
    private var active = false

    init(currentVersion: String, bundleID: String, interval: UInt64 = 300_000_000_000, handoffTimeout: UInt64 = 10_000_000_000,
         fetch: @escaping Fetch, report: @escaping (Error) -> Void = { _ in },
         open: @escaping Open = { url, completion in UIApplication.shared.open(url, options: [:], completionHandler: completion) }) {
        self.currentVersion = currentVersion
        self.bundleID = bundleID
        self.interval = interval
        self.handoffTimeout = handoffTimeout
        self.fetch = fetch
        self.report = report
        self.open = open
    }

    deinit { monitor?.cancel(); openTimeout?.cancel() }

    var installURL: URL? {
        guard let info, info.updateAvailable, let latest = info.latestVersion,
              !latest.isEmpty, latest != currentVersion,
              info.bundleId == bundleID, info.signedValue, info.otaReadyValue,
              let raw = info.installUrl, let components = URLComponents(string: raw),
              components.scheme == "itms-services", components.host?.isEmpty != false,
              components.user == nil, components.password == nil,
              components.fragment == nil, let items = components.queryItems,
              items.count == 2,
              items.filter({ $0.name == "action" }).map(\.value) == ["download-manifest"],
              let manifest = items.first(where: { $0.name == "url" })?.value,
              let url = URL(string: manifest), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              info.manifestUrl == manifest else { return nil }
        return components.url
    }

    /// Only offer the server's HTTPS page when it belongs to the validated OTA origin.
    var installPageURL: URL? {
        guard installURL != nil, let raw = info?.installPageUrl,
              let page = URLComponents(string: raw),
              let manifest = info?.manifestUrl.flatMap({ URLComponents(string: $0) }),
              page.scheme == "https", page.host == manifest.host, page.port == manifest.port,
              page.user == nil, page.password == nil, page.query == nil, page.fragment == nil,
              page.path == "/ios/install" else { return nil }
        return page.url
    }

    var promptVersion: String? {
        guard installURL != nil, let version = info?.latestVersion, version != dismissedVersion else { return nil }
        return version
    }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        revision &+= 1
        monitor?.cancel()
        monitor = nil
        checking = false
        opening = false
        openTimeout?.cancel()
        guard value else { return }
        monitor = Task { [weak self] in
            await self?.check()
            // Do not retain this controller while asleep. Background/disconnect cancels the loop.
            while !Task.isCancelled {
                guard let interval = self?.interval else { return }
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                await self?.check()
            }
        }
    }

    func check(manual: Bool = false) async {
        guard active else {
            if manual { error = "连接尚未就绪，请回到主页连接后重试。" }
            return
        }
        guard !checking, !opening else { return }
        let generation = revision
        checking = true
        error = nil
        defer { if generation == revision { checking = false } }
        do {
            let candidate = try await fetch(currentVersion)
            guard !Task.isCancelled, active, revision == generation else { return }
            if candidate.latestVersion != info?.latestVersion { handoffMessage = nil }
            info = candidate
            if manual { dismissedVersion = nil }
            if candidate.updateAvailable, candidate.bundleId != bundleID {
                error = "更新包与当前 App 的身份不同，不能覆盖安装。请使用 Safari 首次安装签名版，并保留旧 App。"
            } else if candidate.updateAvailable, installURL == nil {
                error = "新包暂不可安装，请等待服务器提供匹配的签名包及受信任的 HTTPS 安装清单。"
            }
        } catch {
            guard !Task.isCancelled, active, revision == generation,
                  !ClientFeedbackError.isCancellation(error) else { return }
            self.error = error.localizedDescription
            report(error)
        }
    }

    func dismissPrompt() { dismissedVersion = info?.latestVersion }

    func install() {
        // iOS 26+ never backgrounds the requesting app after the itms confirmation, so an
        // in-app handoff stalls until the app is force-quit. Prefer the validated Safari
        // install page; it backgrounds Wand before the system installer starts.
        if installPageURL != nil {
            openInstallPage()
            return
        }
        guard let url = installURL else {
            error = "当前更新包暂不可安装，请重新检查更新。"
            return
        }
        handoff(url, safari: false)
    }

    func openInstallPage() {
        guard let url = installPageURL else { return }
        handoff(url, safari: true)
    }

    private func handoff(_ url: URL, safari: Bool) {
        guard !opening else { return }
        guard active else {
            error = "连接尚未就绪，请回到主页连接后重试。"
            return
        }
        let generation = revision
        handoffAttempt &+= 1
        let attempt = handoffAttempt
        opening = true
        error = nil
        // Set this before UIApplication.open: the system prompt can deactivate the scene
        // before its completion arrives. Returning to the App must retain useful feedback.
        handoffMessage = safari
            ? "正在打开浏览器安装页，请按页面提示继续。"
            : "已请求系统安装。请在系统提示中确认；若未出现提示，可打开安装页。"
        openTimeout?.cancel()
        let timeout = handoffTimeout
        openTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: timeout) } catch { return }
            guard let self, self.revision == generation, self.handoffAttempt == attempt, self.opening else { return }
            self.opening = false
            self.error = "尚未收到系统响应，请重试或打开安装页。"
        }
        open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self, self.active, self.revision == generation, self.handoffAttempt == attempt, self.opening else { return }
                self.openTimeout?.cancel()
                self.opening = false
                if !opened {
                    let failure = NSError(domain: "WandUpdate", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: safari ? "无法打开安装页，请稍后重试。" : "无法打开 iOS 系统安装器，请打开安装页。",
                    ])
                    self.error = failure.localizedDescription
                    self.report(failure)
                }
                // opened means handoff only. Never claim the App was installed.
            }
        }
    }

}

struct AppUpdateBanner: View {
    @ObservedObject var updater: AppUpdateController
    @Environment(\.colorScheme) private var colorScheme

    private var actionForeground: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        if let version = updater.promptVersion {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wand 有新版本")
                            .font(.headline)
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button { updater.dismissPrompt() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("稍后提醒")
                    .disabled(updater.opening)
                }
                Text(updater.error ?? updater.handoffMessage ?? "将打开浏览器安装页，在页面中确认即可，无需连接电脑。")
                    .font(.subheadline)
                    .foregroundStyle(updater.error == nil ? Theme.textSecondary : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button { updater.install() } label: {
                    ZStack {
                        Text("安装更新").opacity(updater.opening ? 0 : 1)
                        if updater.opening { ProgressView().tint(actionForeground) }
                    }
                    .foregroundStyle(actionForeground)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .disabled(updater.opening)
                .accessibilityIdentifier("app-update-install")
                if updater.handoffMessage != nil, updater.installPageURL != nil {
                    Button("打开安装页") { updater.openInstallPage() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(updater.opening)
                        .accessibilityIdentifier("app-update-safari")
                }
            }
            .padding(16)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .transition(.opacity)
            .accessibilityIdentifier("app-update-banner")
        }
    }
}

import SwiftUI
import UIKit

// MARK: - 图片路径判定（对齐 Web 端 utils.isImagePath / 服务端 IMAGE_EXTS）

/// 这些后缀的文件被认为是可内联预览的图片。和 src/web-ui/browser/utils.ts 的
/// IMAGE_PATH_RE 与服务端 server.ts 的 IMAGE_EXTS 保持一致。SVG 可能无法解码成
/// UIImage；无法解码时显示明确失败与重试，不让图片无解释地消失。
private let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "ico", "heic", "heif",
]

/// 是否为图片路径。先剥掉 `?query` / `#hash` 再判后缀（对齐 Web）。
func isImagePath(_ value: String?) -> Bool {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return false
    }
    // 去掉 ?query / #hash
    let clean = raw.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? raw
    let ext = (clean as NSString).pathExtension.lowercased()
    return imageExtensions.contains(ext)
}

// MARK: - 上传附件前缀解析（对齐 Web 端 chat-render.renderUserText）

/// 用户上传附件时，客户端在 prompt 前注入：
///   [附件已上传，请查看以下文件:\n<path1>\n<path2>\n]\n\n<正文>
/// 这里把它解析成（附件路径列表 + 剩余正文）。没有前缀时返回 (nil, 原文)。
struct ParsedUserMessage {
    /// 附件绝对路径列表（可能为图片，也可能是普通文件）。
    let attachmentPaths: [String]
    /// 剥掉前缀后的正文（已 trim 首部空白）。
    let body: String
}

func parseUserAttachmentMessage(_ text: String) -> ParsedUserMessage {
    // 对齐 Web 正则：/^\s*\[附件已上传，请查看以下文件:\n([\s\S]*?)\]\n+/
    let prefixHead = "[附件已上传，请查看以下文件:\n"
    let leading = text.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    guard leading.hasPrefix(prefixHead) else {
        return ParsedUserMessage(attachmentPaths: [], body: text)
    }
    let afterHead = leading.dropFirst(prefixHead.count)
    // 纯附件消息会在提交时 trim 掉最后的换行；与 Android 一样允许 ] 位于末尾。
    let finalBracket = afterHead.hasSuffix("]") ? afterHead.index(before: afterHead.endIndex)..<afterHead.endIndex : nil
    guard let closeRange = afterHead.range(of: "]\n") ?? finalBracket else {
        return ParsedUserMessage(attachmentPaths: [], body: text)
    }
    let pathsBlock = String(afterHead[afterHead.startIndex..<closeRange.lowerBound])
    var rest = String(afterHead[closeRange.upperBound...])
    // ]\n 之后可能还有多余换行，吃掉它们（对齐 \n+）。
    rest = String(rest.drop(while: { $0 == "\n" || $0 == "\r" }))

    let paths = pathsBlock
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    return ParsedUserMessage(attachmentPaths: paths, body: rest)
}

func buildAttachmentPrompt(_ attachments: [UploadedFile], body: String) -> String {
    guard !attachments.isEmpty else { return body }
    let paths = attachments.map(\.savedPath).joined(separator: "\n")
    return "[附件已上传，请查看以下文件:\n\(paths)\n]\n\n\(body)"
}

// MARK: - 远程图片加载视图

func wandImageHTTPFailureMessage(statusCode: Int) -> String {
    switch statusCode {
    case 401, 403: return "没有图片访问权限，请核对连接。"
    case 404: return "图片未找到，请核对消息来源。"
    default: return "图片暂时无法加载（\(statusCode)）。"
    }
}

private final class WandRemoteImageSessionHandle: ObservableObject {
    let baseURL: URL
    let value: SelfSignedSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.value = SelfSignedSession.forEndpoint(baseURL)
    }
}

/// 通过 SelfSignedSession（带 session cookie + 自签证书放行）加载 `/api/file-raw`
/// 的图片。不能用 SwiftUI AsyncImage——它走 URLSession.shared，既没有登录 cookie
/// 也不信任自签证书。带一个进程内 NSCache，避免滚动 / 重渲染反复拉取。
struct WandRemoteImage<Placeholder: View>: View {
    let baseURL: URL
    let path: String
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder

    /// `StateObject` evaluates its handle factory only for a new SwiftUI identity. Rebuilding
    /// an old view value after reset therefore cannot recreate the endpoint pool entry.
    @StateObject private var endpointSession: WandRemoteImageSessionHandle
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    private let directSource: Bool
    private let onAvailabilityChanged: ((Bool) -> Void)?

    init(
        baseURL: URL,
        path: String,
        contentMode: ContentMode = .fit,
        directSource: Bool = false,
        onAvailabilityChanged: ((Bool) -> Void)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.baseURL = baseURL
        self.path = path
        self.contentMode = contentMode
        self.directSource = directSource
        self.onAvailabilityChanged = onAvailabilityChanged
        self.placeholder = placeholder
        _endpointSession = StateObject(
            wrappedValue: WandRemoteImageSessionHandle(baseURL: baseURL)
        )
    }

    private static var cache: NSCache<NSString, UIImage> {
        WandImageCache.shared
    }

    var body: some View {
        // A real container exists before the first response. Empty conditional Groups
        // have no loading content on which SwiftUI can anchor their task/layout.
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let failure {
                Button { retry += 1 } label: {
                    VStack(spacing: 4) {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption).multilineTextAlignment(.center)
                        Text("重试加载图片").font(.caption2.weight(.semibold))
                    }.padding(8).frame(maxWidth: .infinity, minHeight: 64)
                }.buttonStyle(.plain).accessibilityLabel(failure + "，重试加载图片")
            } else {
                placeholder().accessibilityLabel("正在加载图片")
            }
        }
        .task(id: "\(baseURL.absoluteString)\u{0}\(path)\u{0}\(directSource)\u{0}\(retry)") {
            image = nil
            failure = nil
            onAvailabilityChanged?(false)
            await load()
        }
    }

    private var requestURL: URL? {
        if directSource {
            guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        return WandEndpoint.url(
            baseURL: baseURL,
            route: "/api/file-raw",
            queryItems: [URLQueryItem(name: "path", value: path)]
        )
    }

    private func load() async {
        let sessionHandle = endpointSession.value
        guard endpointSession.baseURL == baseURL, !sessionHandle.isRetired else {
            failure = "连接已变化，请重新打开图片。"
            return
        }
        if directSource, path.hasPrefix("data:") {
            guard path.lowercased().hasPrefix("data:image/"),
                  let comma = path.firstIndex(of: ","),
                  path[..<comma].lowercased().contains(";base64"),
                  let data = Data(base64Encoded: String(path[path.index(after: comma)...])),
                  let decoded = UIImage(data: data) else {
                failure = "图片格式不支持或内容无效。"
                return
            }
            guard !Task.isCancelled, !sessionHandle.isRetired else { return }
            image = decoded; onAvailabilityChanged?(true)
            return
        }
        let cacheKey = "\(sessionHandle.resourceCacheNamespace)|\(baseURL.absoluteString)|\(directSource)|\(path)" as NSString
        if let cached = Self.cache.object(forKey: cacheKey) {
            guard !Task.isCancelled else { return }
            image = cached; onAvailabilityChanged?(true)
            return
        }
        guard let url = requestURL else {
            failure = "图片地址不可用，请核对消息来源。"
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        do {
            let (data, response) = try await sessionHandle.session.data(for: request)
            guard !Task.isCancelled, !sessionHandle.isRetired else { return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failure = wandImageHTTPFailureMessage(statusCode: http.statusCode)
                return
            }
            guard let decoded = UIImage(data: data) else {
                failure = "图片格式不支持或内容无效。"
                return
            }
            let pixelBytes = Int(decoded.size.width * decoded.scale)
                * Int(decoded.size.height * decoded.scale) * 4
            Self.cache.setObject(decoded, forKey: cacheKey, cost: pixelBytes)
            if !Task.isCancelled, !sessionHandle.isRetired {
                image = decoded; onAvailabilityChanged?(true)
            }
        } catch {
            if !Task.isCancelled, !sessionHandle.isRetired {
                failure = "图片加载失败，请检查连接后重试。"
            }
        }
    }
}

extension WandRemoteImage where Placeholder == AnyView {
    /// 默认加载占位；失败由共享反馈显示原因和重试。
    init(baseURL: URL, path: String, contentMode: ContentMode = .fit,
         directSource: Bool = false, onAvailabilityChanged: ((Bool) -> Void)? = nil) {
        self.init(baseURL: baseURL, path: path, contentMode: contentMode,
                  directSource: directSource, onAvailabilityChanged: onAvailabilityChanged) {
            AnyView(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
                    .overlay { ProgressView("加载图片…").font(.caption) }
                    .frame(minWidth: 96, minHeight: 64)
            )
        }
    }
}

/// 进程内图片缓存（连接资源命名空间 + 端点 + 来源类型/路径）。
enum WandImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        // 成本按解码后像素字节数计（见 setObject 调用处），总量约 192MB，
        // 防止少数超大图占满内存把常用小图全部挤掉。
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()
}

// MARK: - 缩略图尺寸真源

/// 聊天内联图片的自适应上限：图片按自身比例在框内完整显示（不拉伸、不裁切），
/// 横图吃满宽度、竖图吃满高度，小图不放大。缩略图各调用点共用这一处定义，
/// 与 Android `WandImage` 的 max 尺寸保持一致，避免各写一套像素值。
enum WandImageLayout {
    static let thumbnailMaxWidth: CGFloat = 320
    static let thumbnailMaxHeight: CGFloat = 360
    static let figureWidthFraction: CGFloat = 0.8
    static let figureHeightFraction: CGFloat = 0.4

    static func figureBounds(availableWidth: CGFloat, viewportHeight: CGFloat) -> CGSize {
        CGSize(width: min(thumbnailMaxWidth, max(0, availableWidth) * figureWidthFraction),
               height: viewportHeight > 0 ? min(thumbnailMaxHeight, viewportHeight * figureHeightFraction) : thumbnailMaxHeight)
    }
}

/// A bounded proposal, not a fixed aspect ratio: portrait screenshots remain complete
/// but cannot impersonate a full page. The chat viewport is supplied by its existing owner.
struct WandImageFigureLayout: Layout {
    var viewportHeight: CGFloat

    private func proposal(_ width: CGFloat?) -> ProposedViewSize {
        let bounds = WandImageLayout.figureBounds(availableWidth: width ?? WandImageLayout.thumbnailMaxWidth,
                                                 viewportHeight: viewportHeight)
        return ProposedViewSize(bounds)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = self.proposal(proposal.width)
        let size = subviews.first?.sizeThatFits(limit) ?? .zero
        return CGSize(width: min(size.width, limit.width ?? 0), height: min(size.height, limit.height ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

/// 全屏查看器的起始页下标钳制：分组为空或下标越界都退回第一张，不崩溃。
/// 分组由调用点给出（同一气泡/同一工具卡片的全部图片）。
func wandImageViewerStart(index: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index, 0), count - 1)
}

// MARK: - 当前已加载对话的图片画廊（只投影消息，不额外请求历史）

struct WandImagePage: Hashable {
    let source: String
    let directSource: Bool
}

private struct WandImageGalleryKey: EnvironmentKey {
    static let defaultValue: () -> [WandImagePage] = { [] }
}

extension EnvironmentValues {
    var wandImageGallery: () -> [WandImagePage] {
        get { self[WandImageGalleryKey.self] }
        set { self[WandImageGalleryKey.self] = newValue }
    }
}

func wandConversationImagePages(_ turns: [ConversationTurn]) -> [WandImagePage] {
    let blocks = turns.flatMap(\.content)
    var results: [String: (failed: Bool, images: [String])] = [:]
    for block in blocks {
        if case .toolResult(let id, _, let failed, _, let images, _, _) = block { results[id] = (failed, images) }
    }
    var pages: [WandImagePage] = []
    var seen = Set<WandImagePage>()
    func append(_ source: String, direct: Bool) {
        let page = WandImagePage(source: source, directSource: direct)
        if seen.insert(page).inserted { pages.append(page) }
    }
    for turn in turns {
        for block in turn.content {
            switch block {
            case .text(let text, _):
                if turn.role == "user" {
                    for path in parseUserAttachmentMessage(text).attachmentPaths where isImagePath(path) { append(path, direct: false) }
                } else {
                    for page in MarkdownText.imagePages(text) { append(page.source, direct: page.directSource) }
                }
            case .toolUse(let id, let name, _, let input, _):
                guard let result = results[id], !result.failed else { continue }
                if !result.images.isEmpty {
                    for source in result.images { append(source, direct: true) }
                } else if name == "Read", let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue, isImagePath(path) {
                    append(path, direct: false)
                }
            case .toolResult(_, _, let failed, _, let images, _, _) where !failed:
                for source in images { append(source, direct: true) }
            default: break
            }
        }
    }
    return pages
}

struct WandImageGallerySelection {
    var pages: [WandImagePage] = []
    var startIndex = 0
}

func wandImageGallerySelection(gallery: [WandImagePage], local: [String], current: String, direct: Bool, localIndex: Int = 0) -> WandImageGallerySelection {
    let selected = WandImagePage(source: current, directSource: direct)
    if let index = gallery.firstIndex(of: selected) { return WandImageGallerySelection(pages: gallery, startIndex: index) }
    let pages = (local.isEmpty ? [current] : local).map { WandImagePage(source: $0, directSource: direct) }
    let index = pages.indices.contains(localIndex) && pages[localIndex] == selected ? localIndex : pages.firstIndex(of: selected) ?? 0
    return WandImageGallerySelection(pages: pages, startIndex: index)
}

// MARK: - 缩略图（聊天里的内联图片）

/// 工具图片与上传附件共享端点认证、缓存隔离、加载/失败反馈及重试。
struct WandToolImageThumbnail: View {
    let baseURL: URL
    let source: String
    var maxWidth: CGFloat = WandImageLayout.thumbnailMaxWidth
    var maxHeight: CGFloat = WandImageLayout.thumbnailMaxHeight
    /// 同一条消息/同一张卡片里的全部图片（含自己），全屏后左右滑动切换；缺省表示只有当前一张。
    var group: [String] = []
    var groupIndex: Int = 0
    @State private var ready = false
    @State private var showFullScreen = false
    @State private var selection = WandImageGallerySelection()
    @Environment(\.wandImageGallery) private var gallery

    private func openViewer() {
        selection = wandImageGallerySelection(gallery: gallery(), local: viewerSources, current: source, direct: true, localIndex: groupIndex)
        showFullScreen = true
    }

    var body: some View {
        WandRemoteImage(baseURL: baseURL, path: source, directSource: true,
                        onAvailabilityChanged: { ready = $0 })
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture { if ready { openViewer() } }
            .accessibilityElement(children: ready ? .ignore : .contain)
            .accessibilityLabel("工具返回图片")
            .accessibilityValue(ready ? "已加载，可查看大图" : "正在加载或等待重试")
            .accessibilityAddTraits(ready ? .isButton : [])
            .accessibilityAction { if ready { openViewer() } }
            .fullScreenCover(isPresented: $showFullScreen) {
                WandImageViewer(baseURL: baseURL, pages: selection.pages, startIndex: selection.startIndex,
                                isPresented: $showFullScreen)
            }
    }
}

/// 工具图片结果的直出形态：顶部只留文件名，下面按原始比例完整展示图片。
/// 不套工具调用卡片；按聊天阅读区占比收口，点击仍可全屏查看。
struct WandToolImageFigure: View {
    let baseURL: URL
    let source: String
    let name: String
    var directSource = true
    @Environment(\.chatViewportHeight) private var viewportHeight
    /// 同一次工具结果的全部图片（含自己），全屏后左右滑动切换。
    var group: [String] = []
    var groupIndex: Int = 0
    @State private var ready = false
    @State private var showFullScreen = false
    @State private var selection = WandImageGallerySelection()
    @Environment(\.wandImageGallery) private var gallery

    private func openViewer() {
        selection = wandImageGallerySelection(gallery: gallery(), local: viewerSources, current: source, direct: directSource, localIndex: groupIndex)
        showFullScreen = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.wand(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(true)
            WandImageFigureLayout(viewportHeight: viewportHeight) {
                WandRemoteImage(baseURL: baseURL, path: source, directSource: directSource,
                                onAvailabilityChanged: { ready = $0 })
            }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { if ready { openViewer() } }
                .accessibilityElement(children: ready ? .ignore : .contain)
                .accessibilityLabel(name)
                .accessibilityValue(ready ? "已加载，可查看大图" : "正在加载或等待重试")
                .accessibilityAddTraits(ready ? .isButton : [])
                .accessibilityAction { if ready { openViewer() } }
                .fullScreenCover(isPresented: $showFullScreen) {
                    WandImageViewer(baseURL: baseURL, pages: selection.pages, startIndex: selection.startIndex,
                                    isPresented: $showFullScreen)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var viewerSources: [String] { group.isEmpty ? [source] : group }
}

/// 工具图片展示名：单张 Read 图优先用读取到的文件名，其余取图片 URL 的文件名；
/// data URI 或没有可用文件名时回退「图片」（多张带序号）。
func toolImageDisplayName(inputPath: String?, source: String, index: Int, total: Int) -> String {
    let fallback = total > 1 ? "图片 \(index + 1)" : "图片"
    if total == 1, let inputPath {
        let name = (inputPath as NSString).lastPathComponent
        if !name.isEmpty { return name }
    }
    let clean = source.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? source
    guard !clean.hasPrefix("data:") else { return fallback }
    let last = (clean as NSString).lastPathComponent
    guard !last.isEmpty, last != "/", last != "." else { return fallback }
    return last.removingPercentEncoding ?? last
}

/// 聊天里的内联图片缩略图：按自身比例在 320×360 上限内完整显示、圆角 + 细边框，点击放大。
/// 上传附件气泡与 Read 读图卡片共用。
struct WandImageThumbnail: View {
    let baseURL: URL
    let path: String
    var maxWidth: CGFloat = WandImageLayout.thumbnailMaxWidth
    var maxHeight: CGFloat = WandImageLayout.thumbnailMaxHeight
    /// 同一条消息里的全部图片（含自己），全屏后左右滑动切换；缺省表示只有当前一张。
    var group: [String] = []
    var groupIndex: Int = 0

    @State private var showFullScreen = false
    @State private var selection = WandImageGallerySelection()
    @Environment(\.wandImageGallery) private var gallery

    var body: some View {
        WandRemoteImage(baseURL: baseURL, path: path, contentMode: .fit)
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                selection = wandImageGallerySelection(gallery: gallery(), local: viewerSources, current: path, direct: false, localIndex: groupIndex)
                showFullScreen = true
            }
            .fullScreenCover(isPresented: $showFullScreen) {
                WandImageViewer(baseURL: baseURL, pages: selection.pages, startIndex: selection.startIndex,
                                isPresented: $showFullScreen)
            }
    }
}

extension WandImageThumbnail {
    var viewerSources: [String] { group.isEmpty ? [path] : group }
    var viewerStart: Int { wandImageViewerStart(index: groupIndex, count: group.count) }
}

extension WandToolImageThumbnail {
    var viewerSources: [String] { group.isEmpty ? [source] : group }
    var viewerStart: Int { wandImageViewerStart(index: groupIndex, count: group.count) }
}

/// 非图片附件 → 小文件块（文件图标 + 文件名）。
struct WandFileChip: View {
    let path: String

    private var fileName: String {
        (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text(fileName)
                .font(.wand(size: 12))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

/// Both unsent local files and uploaded chat attachments share one bounded horizontal lane.
struct ComposerAttachmentStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8, content: content)
        }.frame(maxHeight: 76)
    }
}

struct PendingAttachmentsPreview: View {
    let baseURL: URL
    let attachments: [UploadedFile]
    let onRemove: (UploadedFile) -> Void
    var onPreview: ((UploadedFile) -> Void)? = nil
    private var imagePaths: [String] { attachments.map(\.savedPath).filter { isImagePath($0) } }
    var body: some View {
        if !attachments.isEmpty {
            ComposerAttachmentStrip {
                    ForEach(attachments, id: \.savedPath) { file in
                        HStack(spacing: 0) {
                            if let onPreview {
                                Button { onPreview(file) } label: { WandFileChip(path: file.originalName).frame(minHeight: 44).contentShape(Rectangle()) }
                                    .buttonStyle(.plain).accessibilityLabel("预览附件 \(file.originalName)")
                            } else if isImagePath(file.savedPath) {
                                WandImageThumbnail(baseURL: baseURL, path: file.savedPath,
                                                   maxWidth: 96, maxHeight: 72,
                                                   group: imagePaths, groupIndex: imagePaths.firstIndex(of: file.savedPath) ?? 0)
                            } else { WandFileChip(path: file.originalName).frame(minHeight: 44) }
                            Button { onRemove(file) } label: {
                                Image(systemName: "xmark.circle.fill").font(.body)
                                    .foregroundStyle(Theme.textSecondary).frame(width: 44, height: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("移除附件 \(file.originalName)")
                        }.frame(maxWidth: 260)
                    }
            }
        }
    }
}

func wandImageVisiblePages(index: Int, count: Int, drag: CGFloat) -> [Int] {
    guard count > 0, (0..<count).contains(index) else { return [] }
    if drag > 0, index > 0 { return [index - 1, index] }
    if drag < 0, index + 1 < count { return [index, index + 1] }
    return [index]
}

func wandImagePageTarget(index: Int, count: Int, translation: CGFloat, predicted: CGFloat, width: CGFloat) -> Int {
    let distance = abs(translation)
    let flick = abs(predicted) > width * 0.6 && predicted * translation > 0
    guard width > 0, distance > width * 0.28 || flick else { return index }
    return wandImageViewerStart(index: index + (translation < 0 ? 1 : -1), count: count)
}

// MARK: - 全屏图片查看器

/// 全屏查看器：黑底、双指缩放 1–5×、放大后可拖动；未放大时左右滑动切换同一组图片，
/// 垂直下拉关闭。静止时只加载当前页；拖向邻页时才挂载该页，不预拉整组图片。
struct WandImageViewer: View {
    let baseURL: URL
    let sources: [String]
    var startIndex: Int = 0
    @Binding var isPresented: Bool
    var directSource = false
    private var sourceModes: [Bool] = []
    @Environment(\.accessibilityReduceMotion) private var reduced

    @State private var index: Int
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var pageDrag: CGFloat = 0
    @State private var dismissDrag: CGFloat = 0
    @State private var lockedAxis: Axis?

    private enum Axis { case horizontal, vertical }

    init(baseURL: URL, sources: [String], startIndex: Int = 0,
         isPresented: Binding<Bool>, directSource: Bool = false) {
        self.baseURL = baseURL
        self.sources = sources
        self._isPresented = isPresented
        self.directSource = directSource
        _index = State(initialValue: wandImageViewerStart(index: startIndex, count: sources.count))
    }

    init(baseURL: URL, pages: [WandImagePage], startIndex: Int = 0, isPresented: Binding<Bool>) {
        self.init(baseURL: baseURL, sources: pages.map(\.source), startIndex: startIndex, isPresented: isPresented)
        sourceModes = pages.map(\.directSource)
    }

    /// 单图入口：附件、工具结果以外的独立图片仍按一张呈现。
    init(baseURL: URL, path: String, isPresented: Binding<Bool>, directSource: Bool = false) {
        self.init(baseURL: baseURL, sources: [path], startIndex: 0,
                  isPresented: isPresented, directSource: directSource)
    }

    private var visiblePages: [Int] {
        guard !sources.isEmpty else { return [] }
        return wandImageVisiblePages(index: index, count: sources.count, drag: pageDrag)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack {
                Color.black
                    .opacity(max(0.55, 1 - dismissDrag / 600))
                    .ignoresSafeArea()

                ZStack {
                    ForEach(visiblePages, id: \.self) { page in
                        pageView(sources[page], direct: sourceModes.indices.contains(page) ? sourceModes[page] : directSource)
                            .frame(width: width, height: proxy.size.height)
                            .offset(x: CGFloat(page - index) * width + pageDrag)
                            // 相邻页只为滑动预加载，不进无障碍树；当前页报自己的序号。
                            .accessibilityHidden(page != index)
                            .accessibilityLabel("图片 \(page + 1)，共 \(sources.count) 张")
                    }
                }
                .frame(width: width, height: proxy.size.height)
                .contentShape(Rectangle())
                .clipped()
                .offset(x: offset.width, y: offset.height + dismissDrag)
                .scaleEffect(scale)
                .gesture(zoomGesture)
                .simultaneousGesture(panGesture(width: width))
                .onTapGesture(count: 2) { toggleZoom() }
                .accessibilityElement(children: .contain)
                .accessibilityScrollAction { edge in
                    switch edge {
                    case .trailing: step(1)
                    case .leading: step(-1)
                    default: break
                    }
                }

                overlays
            }
            .statusBarHidden(true)
            .preferredColorScheme(.dark)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func pageView(_ source: String, direct: Bool) -> some View {
        WandRemoteImage(baseURL: baseURL, path: source, contentMode: .fit, directSource: direct) {
            AnyView(ProgressView("加载图片…").tint(.white).foregroundStyle(.white))
        }
    }

    @ViewBuilder private var overlays: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }.accessibilityLabel("关闭图片预览")
                .padding(.trailing, 18)
                .padding(.top, 12)
            }
            Spacer()
            if sources.count > 1 {
                Text("\(index + 1) / \(sources.count)")
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .wandGlassCapsule().environment(\.colorScheme, .dark)
                    .accessibilityLabel("第 \(index + 1) 张，共 \(sources.count) 张")
                    .padding(.bottom, 28)
            }
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(5, max(1, lastScale * value))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(reduced ? nil : WandMotion.disclosure) {
                        scale = 1
                        lastScale = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let translation = value.translation
                if scale > 1 {
                    offset = CGSize(
                        width: lastOffset.width + translation.width,
                        height: lastOffset.height + translation.height
                    )
                    return
                }
                if lockedAxis == nil, abs(translation.width) > 10 || abs(translation.height) > 10 {
                    lockedAxis = abs(translation.width) >= abs(translation.height) ? .horizontal : .vertical
                }
                switch lockedAxis {
                case .horizontal:
                    let atEdge = (translation.width > 0 && index == 0)
                        || (translation.width < 0 && index == sources.count - 1)
                    pageDrag = atEdge ? translation.width * 0.35 : translation.width
                case .vertical:
                    dismissDrag = max(0, translation.height)
                case nil:
                    break
                }
            }
            .onEnded { value in
                let translation = value.translation
                let axis = lockedAxis
                lockedAxis = nil
                if scale > 1 {
                    lastOffset = offset
                    return
                }
                switch axis {
                case .horizontal:
                    commitPage(translation: translation.width, predicted: value.predictedEndTranslation.width, width: width)
                case .vertical:
                    if dismissDrag > 90 {
                        isPresented = false
                        return
                    }
                    withAnimation(reduced ? nil : WandMotion.expansion) { dismissDrag = 0 }
                case nil:
                    break
                }
            }
    }

    private func commitPage(translation: CGFloat, predicted: CGFloat, width: CGFloat) {
        let next = wandImagePageTarget(index: index, count: sources.count, translation: translation, predicted: predicted, width: width)
        withAnimation(reduced ? nil : WandMotion.expansion) {
            index = next
            pageDrag = 0
        }
    }

    private func step(_ direction: Int) {
        guard !sources.isEmpty else { return }
        let next = min(max(index + direction, 0), sources.count - 1)
        guard next != index else { return }
        withAnimation(reduced ? nil : WandMotion.expansion) { index = next }
    }

    private func toggleZoom() {
        withAnimation(reduced ? nil : WandMotion.disclosure) {
            if scale > 1 {
                scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
            } else {
                scale = 2; lastScale = 2
            }
        }
    }
}

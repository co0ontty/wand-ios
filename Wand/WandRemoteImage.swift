import SwiftUI
import UIKit

// MARK: - 图片路径判定（对齐 Web 端 utils.isImagePath / 服务端 IMAGE_EXTS）

/// 这些后缀的文件被认为是可内联预览的图片。和 src/web-ui/browser/utils.ts 的
/// IMAGE_PATH_RE 与服务端 server.ts 的 IMAGE_EXTS 保持一致。SVG 可能无法解码成
/// UIImage——那没关系，加载失败会优雅隐藏。
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
    // 找到匹配的结束标记 "]\n"（最先出现的 "]" 后跟换行）。
    guard let closeRange = afterHead.range(of: "]\n") else {
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

// MARK: - 远程图片加载视图

/// 通过 SelfSignedSession（带 session cookie + 自签证书放行）加载 `/api/file-raw`
/// 的图片。不能用 SwiftUI AsyncImage——它走 URLSession.shared，既没有登录 cookie
/// 也不信任自签证书。带一个进程内 NSCache，避免滚动 / 重渲染反复拉取。
struct WandRemoteImage<Placeholder: View>: View {
    let baseURL: URL
    let path: String
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    private static var cache: NSCache<NSString, UIImage> {
        WandImageCache.shared
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                placeholder()
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            await load()
        }
    }

    private var requestURL: URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/api/file-raw"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    private func load() async {
        if let cached = Self.cache.object(forKey: path as NSString) {
            image = cached
            return
        }
        guard let url = requestURL else {
            failed = true
            return
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        do {
            let (data, response) = try await SelfSignedSession.shared.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failed = true
                return
            }
            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            Self.cache.setObject(decoded, forKey: path as NSString)
            if !Task.isCancelled {
                image = decoded
            }
        } catch {
            if !Task.isCancelled {
                failed = true
            }
        }
    }
}

extension WandRemoteImage where Placeholder == AnyView {
    /// 默认占位：一个柔和的加载方块（图片未到 / 失败时显示）。
    init(baseURL: URL, path: String, contentMode: ContentMode = .fit) {
        self.init(baseURL: baseURL, path: path, contentMode: contentMode) {
            AnyView(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.textSecondary.opacity(0.5))
                    )
            )
        }
    }
}

/// 进程内图片缓存（按绝对路径键）。
enum WandImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()
}

// MARK: - 缩略图（聊天里的内联图片）

/// 聊天里的内联图片缩略图：最大 240×200、scaledToFit、圆角 + 细边框，点击放大。
/// 上传附件气泡与 Read 读图卡片共用。
struct WandImageThumbnail: View {
    let baseURL: URL
    let path: String
    var maxWidth: CGFloat = 240
    var maxHeight: CGFloat = 200

    @State private var showFullScreen = false

    var body: some View {
        WandRemoteImage(baseURL: baseURL, path: path, contentMode: .fit)
            .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture { showFullScreen = true }
            .fullScreenCover(isPresented: $showFullScreen) {
                WandImageViewer(baseURL: baseURL, path: path, isPresented: $showFullScreen)
            }
    }
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
                .font(.system(size: 12))
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

// MARK: - 全屏图片查看器

/// 简单可缩放 / 平移的全屏图片查看器，点右上角关闭或下滑关闭。
struct WandImageViewer: View {
    let baseURL: URL
    let path: String
    @Binding var isPresented: Bool

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            WandRemoteImage(baseURL: baseURL, path: path, contentMode: .fit) {
                AnyView(ProgressView().tint(.white))
            }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1, lastScale * value)
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 {
                            withAnimation(.spring()) {
                                scale = 1
                                lastScale = 1
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(
                            width: lastOffset.width + value.translation.width,
                            height: lastOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring()) {
                    if scale > 1 {
                        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
                    } else {
                        scale = 2; lastScale = 2
                    }
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .padding(.trailing, 18)
                    .padding(.top, 12)
                }
                Spacer()
            }
        }
        .statusBarHidden(true)
    }
}

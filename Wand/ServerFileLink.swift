import Combine
import Foundation
import QuickLook
import SwiftUI
import UIKit

/// Markdown links emitted by CLI agents can point at an absolute path on the connected
/// Wand server. Keep parsing and authenticated retrieval together so a server path is
/// never accidentally handed to iOS as if it were a local file URL.
enum WandServerFileLink {
    private static let webRoutePrefixes = ["/api", "/android", "/macos"]

    /// Accepts explicit absolute server paths, including `:line[:column]`, `#LxCy`, and
    /// `file://localhost` forms. Ordinary web URLs and relative paths stay nil.
    static func serverPath(_ target: String?) -> String? {
        guard var value = target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let path: String
        if value.range(of: "file://", options: [.anchored, .caseInsensitive]) != nil {
            guard let components = URLComponents(string: value),
                  components.scheme?.lowercased() == "file",
                  components.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true,
                  components.user == nil,
                  components.password == nil else { return nil }
            path = decodePercentPath(components.percentEncodedPath)
        } else {
            guard value.hasPrefix("/"), !value.hasPrefix("//") else { return nil }
            guard !webRoutePrefixes.contains(where: { prefix in
                value == prefix || value.hasPrefix(prefix + "/")
            }) else { return nil }
            path = decodePercentPath(removingHashLineSuffix(from: value))
        }

        let withoutLocation = removingColonLineSuffix(from: path)
        guard withoutLocation.hasPrefix("/"),
              !withoutLocation.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return withoutLocation
    }

    static func download(serverPath: String, api: WandAPI) async throws -> URL {
        guard serverPath.hasPrefix("/"),
              let url = WandEndpoint.url(
                  baseURL: api.baseURL,
                  route: "/api/file-raw",
                  queryItems: [
                      URLQueryItem(name: "download", value: "1"),
                      URLQueryItem(name: "path", value: serverPath),
                  ]
              ) else {
            throw DownloadError.invalidURL
        }
        guard WandEndpointScope(api.baseURL)?.contains(url) == true else {
            throw DownloadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData

        var response = try await perform(request, api: api)
        if response.http.statusCode == 401, let token = api.token, !token.isEmpty {
            try? FileManager.default.removeItem(at: response.temporaryURL)
            try await relogin(
                baseURL: api.baseURL,
                token: token,
                endpointSession: api.endpointSession
            )
            response = try await perform(request, api: api)
        }
        defer { try? FileManager.default.removeItem(at: response.temporaryURL) }

        guard (200...299).contains(response.http.statusCode) else {
            if response.http.statusCode == 401 { throw DownloadError.unauthorized }
            throw DownloadError.server(response.http.statusCode)
        }
        guard let finalURL = response.http.url,
              WandEndpointScope(api.baseURL)?.contains(finalURL) == true else {
            throw DownloadError.crossEndpointRedirect
        }

        return try persistTemporaryFile(
            response.temporaryURL,
            fileName: safeFileName(fileName(from: response.http, fallbackPath: serverPath))
        )
    }

    private static func perform(
        _ request: URLRequest,
        api: WandAPI
    ) async throws -> (temporaryURL: URL, http: HTTPURLResponse) {
        guard !api.endpointSession.isRetired else {
            throw DownloadError.connectionClosed
        }
        let (temporaryURL, response) = try await api.endpointSession.session.download(for: request)
        guard !api.endpointSession.isRetired else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadError.connectionClosed
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw DownloadError.invalidResponse
        }
        return (temporaryURL, http)
    }

    private static func relogin(
        baseURL: URL,
        token: String,
        endpointSession: SelfSignedSession
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            WandAuth.loginWithToken(
                serverURL: baseURL,
                appToken: token,
                endpointSession: endpointSession
            ) { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: DownloadError.login(error.userMessage))
                }
            }
        }
    }

    private static func persistTemporaryFile(_ source: URL, fileName: String) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("WandServerFiles", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(fileName, isDirectory: false)
            try manager.moveItem(at: source, to: destination)
            return destination
        } catch {
            try? manager.removeItem(at: directory)
            throw DownloadError.cannotSave(error.localizedDescription)
        }
    }

    private static func removingHashLineSuffix(from value: String) -> String {
        guard let range = value.range(
            of: "#L[0-9]+(?:C[0-9]+)?$",
            options: [.regularExpression, .caseInsensitive]
        ) else { return value }
        var result = value
        result.removeSubrange(range)
        return result
    }

    private static func removingColonLineSuffix(from value: String) -> String {
        guard let range = value.range(
            of: ":[0-9]+(?::[0-9]+)?$",
            options: .regularExpression
        ) else { return value }
        var result = value
        result.removeSubrange(range)
        return result
    }

    private static func decodePercentPath(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func safeFileName(_ value: String) -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\"))
        let cleanedScalars = value.unicodeScalars.map { unsafe.contains($0) ? "_" : String($0) }
        let cleaned = String(cleanedScalars.joined().prefix(180))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "wand-file" : cleaned
    }

    /// 服务端 `Content-Disposition` 的文件名是权威值（正确解码 UTF-8）；缺失或解析
    /// 失败时退回服务器路径的最后一段。两种来源最终都会经过 `safeFileName` 消毒。
    private static func fileName(from response: HTTPURLResponse, fallbackPath: String) -> String {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
              let parsed = fileNameParameter(in: disposition) else {
            return (fallbackPath as NSString).lastPathComponent
        }
        return parsed
    }

    /// `filename*`（RFC 5987，形如 `UTF-8''%E6%8A%A5...`）优先于旧式 `filename="..."`。
    private static func fileNameParameter(in disposition: String) -> String? {
        var plain: String?
        var extended: String?
        for parameter in disposition.split(separator: ";") {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(trimmed[trimmed.index(after: separator)...])
            guard !rawValue.isEmpty else { continue }
            if name == "filename*" {
                let segments = rawValue.split(
                    separator: "'",
                    maxSplits: 2,
                    omittingEmptySubsequences: false
                )
                if let encoded = segments.last,
                   let decoded = encoded.removingPercentEncoding,
                   !decoded.isEmpty {
                    extended = decoded
                }
            } else if name == "filename" {
                let unquoted = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !unquoted.isEmpty { plain = unquoted }
            }
        }
        return extended ?? plain
    }

    private enum DownloadError: LocalizedError {
        case invalidURL
        case invalidResponse
        case unauthorized
        case connectionClosed
        case server(Int)
        case crossEndpointRedirect
        case login(String)
        case cannotSave(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无法构造安全的文件下载地址"
            case .invalidResponse: return "服务端没有返回有效响应"
            case .unauthorized: return "登录已失效，请重新连接服务器"
            case .connectionClosed: return "服务器连接已关闭"
            case .server(let status): return "服务端返回 HTTP \(status)"
            case .crossEndpointRedirect: return "服务端把下载重定向到了其他地址，已为安全起见取消"
            case .login(let message): return message
            case .cannotSave(let message): return "无法保存临时文件：\(message)"
            }
        }
    }
}

struct ServerFilePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ServerFileLinkFailure: Identifiable {
    let id = UUID()
    let message: String
}

@MainActor
final class ServerFileLinkController: ObservableObject {
    @Published private(set) var isDownloading = false
    @Published var previewItem: ServerFilePreviewItem?
    @Published var failure: ServerFileLinkFailure?

    private var downloadTask: Task<Void, Never>?
    private var temporaryPreviewURL: URL?
    private var downloadGeneration = 0

    func open(serverPath: String, api: WandAPI) {
        downloadTask?.cancel()
        downloadGeneration &+= 1
        let generation = downloadGeneration
        isDownloading = true
        failure = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await WandServerFileLink.download(serverPath: serverPath, api: api)
                guard !Task.isCancelled, downloadGeneration == generation else {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    return
                }
                replacePreview(with: url)
            } catch is CancellationError {
                // The request was cancelled (superseded by a newer link or teardown); keep quiet.
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession 的 async API 在 Task 取消时抛 URLError(.cancelled) 而非
                // CancellationError，这里同样静默。
            } catch {
                if downloadGeneration == generation {
                    failure = ServerFileLinkFailure(message: error.localizedDescription)
                }
            }
            if downloadGeneration == generation {
                isDownloading = false
            }
        }
    }

    func dismissPreview() {
        previewItem = nil
        if let temporaryPreviewURL {
            try? FileManager.default.removeItem(at: temporaryPreviewURL.deletingLastPathComponent())
        }
        temporaryPreviewURL = nil
    }

    func cancel() {
        downloadGeneration &+= 1
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        dismissPreview()
    }

    private func replacePreview(with url: URL) {
        dismissPreview()
        temporaryPreviewURL = url
        previewItem = ServerFilePreviewItem(url: url)
    }
}

struct ServerFilePreviewView: View {
    let item: ServerFilePreviewItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServerFileQuickLook(fileURL: item.url)
                .navigationTitle(item.url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: item.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享文件")
                    }
                }
        }
    }
}

private struct ServerFileQuickLook: UIViewControllerRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(fileURL: fileURL)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.fileURL != fileURL else { return }
        context.coordinator.fileURL = fileURL
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            fileURL as NSURL
        }
    }
}

private struct ServerFileLinkControllerEnvironmentKey: EnvironmentKey {
    static let defaultValue: ServerFileLinkController? = nil
}

extension EnvironmentValues {
    var serverFileLinkController: ServerFileLinkController? {
        get { self[ServerFileLinkControllerEnvironmentKey.self] }
        set { self[ServerFileLinkControllerEnvironmentKey.self] = newValue }
    }
}

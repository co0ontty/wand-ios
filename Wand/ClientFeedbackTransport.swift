import Foundation
import CryptoKit

extension WandAPI {
    /// Independent best-effort request: no authentication refresh, retry, feedback recursion, or business replay.
    func reportClientFeedback(event: String, feature: String, error: Error) {
        guard !ClientFeedbackError.isCancellation(error), !endpointSession.isRetired,
              ClientFeedbackReport.allows(baseURL),
              let url = WandEndpoint.url(baseURL: baseURL, route: "/api/feedback/client") else { return }
        let secrets = [token].compactMap { $0 } + (endpointSession.cookieStorage?.cookies ?? []).map(\.value)
        let diagnostic = ClientFeedbackError(error, secrets: secrets)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let report = ClientFeedbackReport(event: event, version: version, feature: feature, error: diagnostic)
        guard let body = try? JSONEncoder().encode(report), body.count <= 32768 else { return }
        let identity = [baseURL.absoluteString, event, feature, diagnostic.name, diagnostic.code ?? "", diagnostic.message].joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let limiter = ClientFeedbackLimiter.shared
        guard limiter.begin(key: key) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let task = endpointSession.feedbackTask(with: request, completion: { limiter.finish() }) else { return }
        task.resume()
        // URLRequest timeout is an inactivity timeout; also enforce an absolute five-second deadline.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { task.cancel() }
    }

    func reportHTTPFailure(status: Int, data: Data, path: String) {
        guard (500...599).contains(status), path != "/api/feedback/client" else { return }
        // Only the protocol's explicit error string, never the response body or request content.
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
        let error = NSError(domain: "WandHTTPError", code: status, userInfo: [
            NSLocalizedDescriptionKey: message ?? "HTTP \(status)",
        ])
        reportClientFeedback(event: "http_5xx", feature: ClientFeedbackReport.feature(path: path), error: error)
    }
}

// Only for the macOS Foundation harness. Network/redirect/reporter implementations are copied
// unchanged from production; these two application owners avoid importing the iOS UI target.
import Foundation

enum ServerProfiles {
    static func canonicalBaseURL(_ raw: String) throws -> URL { URL(string: raw)! }
}

final class WandAPI {
    let baseURL: URL
    let token: String?
    let endpointSession: SelfSignedSession
    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
        endpointSession = SelfSignedSession.forEndpoint(baseURL)
    }
}

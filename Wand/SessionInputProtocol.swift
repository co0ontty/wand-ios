import Foundation

/// Receipt timing never determines whether an input starts or joins the server queue.
func structuredInputRequest(input: String) -> [String: Any] {
    ["input": input, "respondImmediately": true]
}

protocol SessionInputTransport {
    func sendStructuredInput(id: String, input: String) async throws -> SessionSnapshot
    func sendPtyInputChunk(
        id: String,
        input: String,
        view: String,
        shortcutKey: String?
    ) async throws
}

/// A chunk has already reached the terminal. A subsequent 4xx cannot make the
/// complete submission an unsent draft, nor authorize automatic retransmission.
struct UnconfirmedSessionInput: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

func isDefiniteInputRejection(_ error: Error) -> Bool {
    guard let failure = error as? WandAPI.APIError else { return false }
    switch failure {
    case .invalidURL, .unauthorized:
        return true
    case .server(let status, _):
        return (400..<500).contains(status) && status != 408 && status != 409
    case .network:
        // Includes successful HTTP acknowledgements whose snapshot failed decoding.
        return false
    }
}

/// Keep the text and the standalone carriage return as two ordered requests.
/// The caller serializes the whole operation, so shortcuts cannot enter between them.
@MainActor
func sendPtySubmission(
    _ submission: PtyInputSubmission,
    send: (PtyInputChunk) async throws -> Void
) async throws {
    try await send(submission.text)
    do {
        try await Task.sleep(nanoseconds: 30_000_000)
        try await send(submission.enter)
    } catch {
        throw UnconfirmedSessionInput(underlying: error)
    }
}

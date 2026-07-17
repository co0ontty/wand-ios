import Foundation

struct PtyInputChunk: Equatable {
    let input: String
    let view: String
    let shortcutKey: String?
}

struct PtyInputSubmission: Equatable {
    let text: PtyInputChunk
    let enter: PtyInputChunk
}

func ptyInputSubmission(text: String, view: String) -> PtyInputSubmission {
    PtyInputSubmission(
        text: PtyInputChunk(input: text, view: view, shortcutKey: nil),
        enter: PtyInputChunk(input: "\r", view: view, shortcutKey: "enter_text")
    )
}

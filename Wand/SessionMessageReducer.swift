import Foundation

struct SessionMessageWindow {
    var messages: [ConversationTurn]
    var loadedOffset: Int
    var messageTotal: Int
    var leadingBlockOffset: Int
    var leadingBlockTotal: Int
}

func mergingWindowedMessages(
    current: SessionMessageWindow,
    incoming: [ConversationTurn]?,
    offset: Int?,
    total: Int?,
    leadingOffset: Int? = nil,
    leadingTotal: Int? = nil
) -> SessionMessageWindow {
    guard let incoming else { return current }

    let snapOffset = max(0, offset ?? 0)
    let snapTotal = max(0, total ?? max(snapOffset + incoming.count, incoming.count))
    guard !(incoming.isEmpty && !current.messages.isEmpty && snapTotal == 0) else { return current }

    var result = current
    if result.messages.isEmpty {
        result.messages = incoming
        result.loadedOffset = snapOffset
    } else if result.loadedOffset <= snapOffset {
        let keep = min(max(snapOffset - result.loadedOffset, 0), result.messages.count)
        result.messages = Array(result.messages[0..<keep]) + incoming
    } else {
        result.messages = incoming
        result.loadedOffset = snapOffset
    }
    result.messageTotal = max(snapTotal, result.loadedOffset + result.messages.count)

    if result.loadedOffset == snapOffset {
        result.leadingBlockOffset = max(0, leadingOffset ?? 0)
        result.leadingBlockTotal = leadingTotal ?? (result.messages.first?.content.count ?? 0)
    } else {
        result.leadingBlockOffset = 0
        result.leadingBlockTotal = result.messages.first?.content.count ?? 0
    }
    return result
}

func applyingIncrementalMessage(
    _ incoming: ConversationTurn,
    expectedCount: Int,
    to current: SessionMessageWindow
) -> SessionMessageWindow {
    var result = current
    if let last = result.messages.last, last.role == incoming.role {
        result.messages[result.messages.count - 1] = incoming
        if result.messages.count == 1 {
            result.leadingBlockOffset = 0
            result.leadingBlockTotal = incoming.content.count
        }
    } else if result.loadedOffset + result.messages.count < expectedCount || expectedCount == 0 {
        result.messages.append(incoming)
    }
    if expectedCount > 0 {
        result.messageTotal = max(result.messageTotal, expectedCount)
    }
    return result
}


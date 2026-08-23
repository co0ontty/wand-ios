import Foundation

struct SessionMessageWindow {
    var messages: [ConversationTurn]
    var loadedOffset: Int
    var messageTotal: Int
    var leadingBlockOffset: Int
    var leadingBlockTotal: Int
}

private func jsonValueVolume(_ value: JSONValue) -> Int {
    switch value {
    case .string(let text): return text.count
    case .number, .bool, .null: return 1
    case .array(let values): return values.reduce(0) { $0 + jsonValueVolume($1) }
    case .object(let values):
        return values.reduce(0) { $0 + $1.key.count + jsonValueVolume($1.value) }
    }
}

private func contentBlockVolume(_ block: ContentBlock) -> Int {
    switch block {
    case .text(let text, _): return text.count
    case .thinking(let thinking, _): return thinking.count
    case .toolUse(_, _, let description, let input, _):
        return (description?.count ?? 0)
            + input.reduce(0) { $0 + $1.key.count + jsonValueVolume($1.value) }
    case .toolResult(_, let text, _, _, _): return text.count
    case .unknown(_, let payload): return payload.count
    }
}

private func turnContentVolume(_ turn: ConversationTurn) -> Int {
    turn.content.reduce(0) { $0 + contentBlockVolume($1) }
}

private func shouldKeepLocalTurn(_ local: ConversationTurn, over incoming: ConversationTurn) -> Bool {
    local.role == "assistant"
        && incoming.role == "assistant"
        && turnContentVolume(local) > turnContentVolume(incoming)
}

private func mergeOverlappingTurns(
    local: ConversationTurn,
    incoming: ConversationTurn
) -> ConversationTurn {
    guard shouldKeepLocalTurn(local, over: incoming) else { return incoming }
    return ConversationTurn(
        role: local.role,
        content: local.content,
        usage: incoming.usage ?? local.usage
    )
}

private struct LeadingTurnMerge {
    let turn: ConversationTurn
    let blockOffset: Int
    let blockTotal: Int
}

/// 首 turn 的块窗口按绝对块下标合并。这样本地已翻出的旧前缀和服务端最新尾窗
/// 可以同时保留；重叠块逐块选择内容更完整的一版，避免短快照回退或流式尾块增长丢失。
private func mergeLeadingAssistantTurn(
    local: ConversationTurn,
    localOffset: Int,
    localTotal: Int,
    incoming: ConversationTurn,
    incomingOffset: Int,
    incomingTotal: Int
) -> LeadingTurnMerge? {
    guard local.role == "assistant", incoming.role == "assistant" else { return nil }
    let localStart = max(0, localOffset)
    let incomingStart = max(0, incomingOffset)
    let localEnd = localStart + local.content.count
    let incomingEnd = incomingStart + incoming.content.count
    guard incomingStart <= localEnd, localStart <= incomingEnd else { return nil }

    let mergedStart = min(localStart, incomingStart)
    let mergedEnd = max(localEnd, incomingEnd)
    var blocks: [ContentBlock] = []
    blocks.reserveCapacity(mergedEnd - mergedStart)
    for absoluteIndex in mergedStart..<mergedEnd {
        let localBlock = (localStart..<localEnd).contains(absoluteIndex)
            ? local.content[absoluteIndex - localStart]
            : nil
        let incomingBlock = (incomingStart..<incomingEnd).contains(absoluteIndex)
            ? incoming.content[absoluteIndex - incomingStart]
            : nil
        if let localBlock, let incomingBlock {
            blocks.append(
                contentBlockVolume(incomingBlock) >= contentBlockVolume(localBlock)
                    ? incomingBlock
                    : localBlock
            )
        } else if let incomingBlock {
            blocks.append(incomingBlock)
        } else if let localBlock {
            blocks.append(localBlock)
        }
    }

    return LeadingTurnMerge(
        turn: ConversationTurn(
            role: local.role,
            content: blocks,
            usage: incoming.usage ?? local.usage
        ),
        blockOffset: mergedStart,
        blockTotal: max(localTotal, incomingTotal, mergedEnd)
    )
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
    let incomingLeadingOffset = max(0, leadingOffset ?? 0)
    let incomingLeadingTotal = leadingTotal ?? (incoming.first?.content.count ?? 0)
    let currentTotal = max(current.messageTotal, current.loadedOffset + current.messages.count)
    guard !(incoming.isEmpty && !current.messages.isEmpty && snapTotal == 0),
          current.messages.isEmpty || snapTotal >= currentTotal else {
        return current
    }

    guard !current.messages.isEmpty else {
        return SessionMessageWindow(
            messages: incoming,
            loadedOffset: snapOffset,
            messageTotal: max(snapTotal, snapOffset + incoming.count),
            leadingBlockOffset: incomingLeadingOffset,
            leadingBlockTotal: incomingLeadingTotal
        )
    }

    // leadingBlockOffset 只能描述 messages[0]。若新窗口从更晚 turn 开始且该 turn
    // 自身被截断，把本地旧前缀拼在前面会让游标指向错误 turn，并永久漏掉新窗口的
    // 头部块。此时采用新窗口；用户先翻完它的块后仍可继续按 turn 加载旧前缀。
    if snapOffset > current.loadedOffset, incomingLeadingOffset > 0 {
        return SessionMessageWindow(
            messages: incoming,
            loadedOffset: snapOffset,
            messageTotal: max(currentTotal, snapTotal, snapOffset + incoming.count),
            leadingBlockOffset: incomingLeadingOffset,
            leadingBlockTotal: incomingLeadingTotal
        )
    }

    let currentEnd = current.loadedOffset + current.messages.count
    let snapEnd = snapOffset + incoming.count
    guard snapOffset <= currentEnd, current.loadedOffset <= snapEnd else {
        return SessionMessageWindow(
            messages: incoming,
            loadedOffset: snapOffset,
            messageTotal: max(snapTotal, snapOffset + incoming.count),
            leadingBlockOffset: incomingLeadingOffset,
            leadingBlockTotal: incomingLeadingTotal
        )
    }

    let mergedOffset = min(current.loadedOffset, snapOffset)
    let mergedEnd = max(currentEnd, snapEnd)
    var resolvedLeadingOffset = mergedOffset == current.loadedOffset
        ? current.leadingBlockOffset
        : incomingLeadingOffset
    var resolvedLeadingTotal = mergedOffset == current.loadedOffset
        ? current.leadingBlockTotal
        : incomingLeadingTotal
    var merged: [ConversationTurn] = []
    merged.reserveCapacity(mergedEnd - mergedOffset)

    for absoluteIndex in mergedOffset..<mergedEnd {
        let local = (current.loadedOffset..<currentEnd).contains(absoluteIndex)
            ? current.messages[absoluteIndex - current.loadedOffset]
            : nil
        let replacement = (snapOffset..<snapEnd).contains(absoluteIndex)
            ? incoming[absoluteIndex - snapOffset]
            : nil
        if let local, let replacement {
            if absoluteIndex == mergedOffset,
               current.loadedOffset == snapOffset,
               let leadingMerge = mergeLeadingAssistantTurn(
                   local: local,
                   localOffset: current.leadingBlockOffset,
                   localTotal: current.leadingBlockTotal,
                   incoming: replacement,
                   incomingOffset: incomingLeadingOffset,
                   incomingTotal: incomingLeadingTotal
               ) {
                merged.append(leadingMerge.turn)
                resolvedLeadingOffset = leadingMerge.blockOffset
                resolvedLeadingTotal = leadingMerge.blockTotal
            } else {
                let keepLocal = shouldKeepLocalTurn(local, over: replacement)
                merged.append(mergeOverlappingTurns(local: local, incoming: replacement))
                if absoluteIndex == mergedOffset, current.loadedOffset == snapOffset {
                    resolvedLeadingOffset = keepLocal
                        ? current.leadingBlockOffset
                        : incomingLeadingOffset
                    resolvedLeadingTotal = keepLocal
                        ? current.leadingBlockTotal
                        : incomingLeadingTotal
                }
            }
        } else if let replacement {
            merged.append(replacement)
        } else if let local {
            merged.append(local)
        }
    }

    return SessionMessageWindow(
        messages: merged,
        loadedOffset: mergedOffset,
        messageTotal: max(currentTotal, snapTotal, mergedOffset + merged.count),
        leadingBlockOffset: resolvedLeadingOffset,
        leadingBlockTotal: resolvedLeadingTotal
    )
}

func applyingIncrementalMessage(
    _ incoming: ConversationTurn,
    expectedCount: Int,
    to current: SessionMessageWindow
) -> SessionMessageWindow {
    var result = current
    if let last = result.messages.last, last.role == incoming.role {
        let keepLocal = shouldKeepLocalTurn(last, over: incoming)
        result.messages[result.messages.count - 1] = mergeOverlappingTurns(
            local: last,
            incoming: incoming
        )
        if result.messages.count == 1, !keepLocal {
            result.leadingBlockOffset = 0
            result.leadingBlockTotal = incoming.content.count
        }
    } else if result.loadedOffset + result.messages.count < expectedCount || expectedCount == 0 {
        result.messages.append(incoming)
    }
    result.messageTotal = max(
        result.messageTotal,
        expectedCount,
        result.loadedOffset + result.messages.count
    )
    return result
}

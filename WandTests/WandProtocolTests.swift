import Foundation
import XCTest
@testable import Wand

final class WandProtocolTests: XCTestCase {
    func testSessionActivityRecognizesPtyAndStructuredStates() throws {
        let pty = try decode(SessionSnapshot.self, from: #"{"id":"pty","sessionKind":"pty","status":"thinking"}"#)
        let structuredActive = try decode(SessionSnapshot.self, from: #"{"id":"structured-active","sessionKind":"structured","status":"running","structuredState":{"inFlight":true}}"#)
        let structuredIdle = try decode(SessionSnapshot.self, from: #"{"id":"structured-idle","sessionKind":"structured","status":"running","structuredState":{"inFlight":false}}"#)
        let blocked = try decode(SessionSnapshot.self, from: #"{"id":"blocked","sessionKind":"pty","status":"running","permissionBlocked":true}"#)

        XCTAssertTrue(pty.isResponding)
        XCTAssertTrue(structuredActive.isResponding)
        XCTAssertFalse(structuredIdle.isResponding)
        XCTAssertTrue(blocked.hasPendingPermission)
    }

    func testSessionActivityPrioritizesPermissionThenActiveThenDone() {
        let done = SessionActivityAttributes.SessionEntry(
            id: "done", title: "Done", providerRaw: "claude", stateRaw: "done", taskTitle: nil, queuedCount: 0
        )
        let active = SessionActivityAttributes.SessionEntry(
            id: "active", title: "Active", providerRaw: "claude", stateRaw: "responding", taskTitle: nil, queuedCount: 0
        )
        let permission = SessionActivityAttributes.SessionEntry(
            id: "permission", title: "Permission", providerRaw: "claude", stateRaw: "permission", taskTitle: nil, queuedCount: 0
        )
        let state = SessionActivityAttributes.ContentState(
            sessions: [done, active, permission], updatedAt: .now
        )

        XCTAssertEqual(state.primarySession?.id, "permission")
        XCTAssertEqual(state.permissionCount, 1)
        XCTAssertEqual(state.respondingCount, 1)
    }

    func testSessionActivityExposesProviderAndUsefulDetail() {
        let entry = SessionActivityAttributes.SessionEntry(
            id: "codex", title: "Live Activity", providerRaw: "codex",
            stateRaw: "responding", taskTitle: "重构锁屏信息层级", queuedCount: 2,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(entry.providerText, "Codex")
        XCTAssertEqual(entry.providerSymbol, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(entry.primaryDetail, "重构锁屏信息层级")
        XCTAssertEqual(entry.queuedCount, 2)
        XCTAssertNotNil(entry.startedAt)
    }

    func testSessionActivityPermissionDetailTakesPriorityOverTaskTitle() {
        let entry = SessionActivityAttributes.SessionEntry(
            id: "permission", title: "授权", providerRaw: "claude",
            stateRaw: "permission", taskTitle: "不应覆盖授权提示", queuedCount: 0
        )

        XCTAssertEqual(entry.primaryDetail, "需要你的确认后继续")
        XCTAssertEqual(entry.providerText, "Claude")
    }

    func testSessionTopicFieldsDecodeAndDriveDisplayTitle() throws {
        let session = try decode(
            SessionSnapshot.self,
            from: #"{"id":"s1","title":"共同标题","description":"共同总结多轮要求","titleGenerating":true}"#
        )
        let event = try decode(
            WsData.self,
            from: #"{"title":"共同标题","description":"共同总结多轮要求","titleGenerating":true}"#
        )

        XCTAssertEqual(session.displayTitle, "共同标题")
        XCTAssertEqual(session.description, "共同总结多轮要求")
        XCTAssertEqual(session.titleGenerating, true)
        XCTAssertEqual(event.title, "共同标题")
    }

    func testHistoryIdentityIncludesProvider() throws {
        let claude = try decode(
            HistorySession.self,
            from: #"{"claudeSessionId":"shared-id","cwd":"/tmp","firstUserMessage":"Hi","provider":"claude"}"#
        )
        let codex = try decode(
            HistorySession.self,
            from: #"{"claudeSessionId":"shared-id","cwd":"/tmp","firstUserMessage":"Hi","provider":"codex"}"#
        )

        XCTAssertEqual(claude.id, "claude:shared-id")
        XCTAssertEqual(codex.id, "codex:shared-id")
        XCTAssertNotEqual(claude.id, codex.id)
    }

    func testEarlierMessagesAutoLoadOnlyAtTopWhileBrowsingHistory() {
        XCTAssertTrue(shouldAutoLoadEarlierMessages(
            isTopSentinelVisible: true,
            isBrowsingHistory: true,
            canLoadEarlier: true,
            loadingEarlier: false
        ))
        XCTAssertFalse(shouldAutoLoadEarlierMessages(
            isTopSentinelVisible: false,
            isBrowsingHistory: true,
            canLoadEarlier: true,
            loadingEarlier: false
        ))
        XCTAssertFalse(shouldAutoLoadEarlierMessages(
            isTopSentinelVisible: true,
            isBrowsingHistory: false,
            canLoadEarlier: true,
            loadingEarlier: false
        ))
        XCTAssertFalse(shouldAutoLoadEarlierMessages(
            isTopSentinelVisible: true,
            isBrowsingHistory: true,
            canLoadEarlier: true,
            loadingEarlier: true
        ))
    }

    func testHistoryAnchorStaysStableWhenEarlierTurnsArePrepended() {
        XCTAssertEqual(absoluteTurnIndex(localIndex: 5, loadedOffset: 100), 105)
        XCTAssertEqual(absoluteTurnIndex(localIndex: 15, loadedOffset: 90), 105)
        XCTAssertEqual(
            historySummaryAnchorID(localBoundary: 5, loadedOffset: 100),
            historySummaryAnchorID(localBoundary: 15, loadedOffset: 90)
        )
    }

    func testWideListDetailRequiresEnoughWidthAndHeight() {
        XCTAssertFalse(usesWideListDetail(width: 639, height: 900))
        XCTAssertFalse(usesWideListDetail(width: 900, height: 479))
        XCTAssertTrue(usesWideListDetail(width: 640, height: 480))
    }

    func testHistoricalUserCompactionUsesReadableThresholds() {
        XCTAssertFalse(shouldCompactUserBody("简短问题"))
        XCTAssertTrue(shouldCompactUserBody(String(repeating: "a", count: 73)))
        XCTAssertTrue(shouldCompactUserBody("第一行\n第二行\n第三行"))
    }

    func testReplyPreviewCompactsMarkdownAndWhitespace() {
        XCTAssertEqual(
            compactReplyPreviewText("# Heading\n- **First**   item\n> `quoted` value"),
            "Heading First item quoted value"
        )
        XCTAssertEqual(compactReplyPreviewText("`snake_case`"), "snake_case")
    }

    func testComposerExpansionFollowsFocusVoiceOrContentHeight() {
        XCTAssertFalse(composerShouldExpand(focused: false, voiceMode: false))
        XCTAssertTrue(composerShouldExpand(focused: true, voiceMode: false))
        XCTAssertTrue(composerShouldExpand(focused: false, voiceMode: true))
        XCTAssertTrue(composerShouldExpand(focused: false, voiceMode: false, contentNeedsSpace: true))
    }

    func testSessionTimeFormattingParsesIso8601AndFormatsDuration() {
        XCTAssertNotNil(SessionTimeFormatting.date(from: "2026-07-19T12:34:56Z"))
        XCTAssertNotNil(SessionTimeFormatting.date(from: "2026-07-19T12:34:56.789Z"))
        XCTAssertNil(SessionTimeFormatting.date(from: "not-a-date"))
        XCTAssertEqual(
            SessionTimeFormatting.duration(
                startedAt: "2026-07-19T12:00:00Z",
                endedAt: "2026-07-19T12:01:05Z"
            ),
            "01:05"
        )
        XCTAssertEqual(
            SessionTimeFormatting.duration(
                startedAt: "2026-07-19T12:00:00Z",
                endedAt: "2026-07-19T13:01:05Z"
            ),
            "1:01:05"
        )
    }

    func testSessionTimeFormattingUsesMtimeForSorting() {
        XCTAssertEqual(
            SessionTimeFormatting.sortTimestamp(
                timestamp: "2026-07-19T12:00:00Z",
                mtimeMs: 1_234_000
            ),
            1_234
        )
        XCTAssertEqual(SessionTimeFormatting.sortTimestamp(timestamp: nil, mtimeMs: nil), 0)
    }

    func testVoiceTranscriptAppendsNormalizedText() {
        XCTAssertEqual(appendingVoiceTranscript("  新内容\n", to: "已有内容  "), "已有内容 新内容")
        XCTAssertEqual(appendingVoiceTranscript("  \n", to: "已有内容"), "已有内容")
        XCTAssertEqual(appendingVoiceTranscript("新内容", to: "  "), "新内容")
        XCTAssertEqual(appendingVoiceTranscript("新内容", to: "  已有内容  "), "  已有内容 新内容")
    }

    func testWindowedMessagesPreserveLoadedPrefixAndClearLeadingBlockOffset() {
        let current = messageWindow(
            messages: [turn("old"), turn("current")],
            loadedOffset: 5,
            messageTotal: 7,
            leadingBlockOffset: 3,
            leadingBlockTotal: 4
        )

        let result = mergingWindowedMessages(
            current: current,
            incoming: [turn("replacement")],
            offset: 6,
            total: 7,
            leadingOffset: 2,
            leadingTotal: 5
        )

        XCTAssertEqual(result.messages.map(text), ["old", "replacement"])
        XCTAssertEqual(result.loadedOffset, 5)
        XCTAssertEqual(result.messageTotal, 7)
        XCTAssertEqual(result.leadingBlockOffset, 0)
        XCTAssertEqual(result.leadingBlockTotal, 1)
    }

    func testWindowedMessagesIgnoreEmptyZeroTotalSnapshot() {
        let current = messageWindow(
            messages: [turn("kept")],
            loadedOffset: 8,
            messageTotal: 9,
            leadingBlockOffset: 2,
            leadingBlockTotal: 3
        )

        let result = mergingWindowedMessages(
            current: current,
            incoming: [],
            offset: 0,
            total: 0
        )

        XCTAssertEqual(result.messages.map(text), ["kept"])
        XCTAssertEqual(result.loadedOffset, 8)
        XCTAssertEqual(result.messageTotal, 9)
        XCTAssertEqual(result.leadingBlockOffset, 2)
        XCTAssertEqual(result.leadingBlockTotal, 3)
    }

    func testWindowedMessagesClampNegativeServerOffsets() {
        let result = mergingWindowedMessages(
            current: messageWindow(
                messages: [],
                loadedOffset: 0,
                messageTotal: 0,
                leadingBlockOffset: 0,
                leadingBlockTotal: 0
            ),
            incoming: [turn("message")],
            offset: -4,
            total: -1,
            leadingOffset: -2,
            leadingTotal: 1
        )

        XCTAssertEqual(result.loadedOffset, 0)
        XCTAssertEqual(result.messageTotal, 1)
        XCTAssertEqual(result.leadingBlockOffset, 0)
        XCTAssertEqual(result.leadingBlockTotal, 1)
    }

    func testWindowedMessagesUseEarlierSnapshotAndLeadingBlockMetadata() {
        let current = messageWindow(
            messages: [turn("late")],
            loadedOffset: 10,
            messageTotal: 11,
            leadingBlockOffset: 0,
            leadingBlockTotal: 1
        )

        let result = mergingWindowedMessages(
            current: current,
            incoming: [turn("early")],
            offset: 5,
            total: 11,
            leadingOffset: 4,
            leadingTotal: 6
        )

        XCTAssertEqual(result.messages.map(text), ["early"])
        XCTAssertEqual(result.loadedOffset, 5)
        XCTAssertEqual(result.messageTotal, 11)
        XCTAssertEqual(result.leadingBlockOffset, 4)
        XCTAssertEqual(result.leadingBlockTotal, 6)
    }

    func testIncrementalMessageReplacesSameRoleAndResetsSingleTurnBlockWindow() {
        let current = messageWindow(
            messages: [turn("partial", role: "assistant")],
            loadedOffset: 4,
            messageTotal: 5,
            leadingBlockOffset: 8,
            leadingBlockTotal: 10
        )

        let result = applyingIncrementalMessage(
            turn("complete", role: "assistant"),
            expectedCount: 5,
            to: current
        )

        XCTAssertEqual(result.messages.map(text), ["complete"])
        XCTAssertEqual(result.messageTotal, 5)
        XCTAssertEqual(result.leadingBlockOffset, 0)
        XCTAssertEqual(result.leadingBlockTotal, 1)
    }

    func testIncrementalMessageAppendsOnlyWhenHistoryHasRoom() {
        let current = messageWindow(
            messages: [turn("user", role: "user")],
            loadedOffset: 3,
            messageTotal: 4,
            leadingBlockOffset: 0,
            leadingBlockTotal: 1
        )

        let appended = applyingIncrementalMessage(
            turn("assistant", role: "assistant"),
            expectedCount: 5,
            to: current
        )
        let ignored = applyingIncrementalMessage(
            turn("duplicate", role: "assistant"),
            expectedCount: 4,
            to: current
        )

        XCTAssertEqual(appended.messages.map(text), ["user", "assistant"])
        XCTAssertEqual(appended.messageTotal, 5)
        XCTAssertEqual(ignored.messages.map(text), ["user"])
        XCTAssertEqual(ignored.messageTotal, 4)
    }

    func testPtyInputSubmissionKeepsTextAndEnterAsSeparateRequests() {
        XCTAssertEqual(
            ptyInputSubmission(text: "git status", view: "terminal"),
            PtyInputSubmission(
                text: PtyInputChunk(input: "git status", view: "terminal", shortcutKey: nil),
                enter: PtyInputChunk(input: "\r", view: "terminal", shortcutKey: "enter_text")
            )
        )
        XCTAssertEqual(
            ptyInputSubmission(text: "continue", view: "chat"),
            PtyInputSubmission(
                text: PtyInputChunk(input: "continue", view: "chat", shortcutKey: nil),
                enter: PtyInputChunk(input: "\r", view: "chat", shortcutKey: "enter_text")
            )
        )
    }

    func testProviderNormalizationTitlesAndRunners() {
        XCTAssertEqual(WandProvider.normalize(nil), "claude")
        XCTAssertEqual(WandProvider.normalize("  CODEX\n"), "codex")
        XCTAssertEqual(WandProvider.normalize("Open-Code"), "opencode")
        XCTAssertEqual(WandProvider.normalize("open_code"), "opencode")
        XCTAssertEqual(WandProvider.normalize("GROK"), "grok")
        XCTAssertEqual(WandProvider.normalize("qodercli"), "qoder")
        XCTAssertEqual(WandProvider.normalize("future-provider"), "claude")

        XCTAssertEqual(WandProvider.claude.title, "Claude")
        XCTAssertEqual(WandProvider.codex.title, "Codex")
        XCTAssertEqual(WandProvider.opencode.title, "OpenCode")
        XCTAssertEqual(WandProvider.grok.title, "Grok")
        XCTAssertEqual(WandProvider.qoder.title, "Qoder")

        XCTAssertEqual(WandProvider.claude.structuredRunner, "claude-cli-print")
        XCTAssertEqual(WandProvider.codex.structuredRunner, "codex-cli-exec")
        XCTAssertEqual(WandProvider.opencode.structuredRunner, "opencode-cli-run")
        XCTAssertEqual(WandProvider.grok.structuredRunner, "grok-cli-headless")
        XCTAssertEqual(WandProvider.qoder.structuredRunner, "qoder-cli-print")
    }

    func testProviderModeClampUsesSupportedFallbackAndSafeDefault() {
        XCTAssertEqual(WandProvider.claude.clamp(mode: " AUTO-EDIT "), "auto-edit")
        XCTAssertEqual(WandProvider.claude.clamp(mode: "unsupported", fallback: "native"), "native")
        XCTAssertEqual(WandProvider.codex.clamp(mode: "managed"), "full-access")
        XCTAssertEqual(WandProvider.codex.clamp(mode: nil, fallback: "full-access"), "full-access")
        XCTAssertEqual(WandProvider.opencode.clamp(mode: "default"), "default")
        XCTAssertEqual(WandProvider.opencode.clamp(mode: "native", fallback: "full-access"), "full-access")
        XCTAssertEqual(WandProvider.opencode.clamp(mode: "native", fallback: "auto-edit"), "default")
        XCTAssertEqual(WandProvider.qoder.clamp(mode: "native", fallback: "auto-edit"), "auto-edit")
        XCTAssertEqual(WandProvider.claude.clamp(mode: "future-auto-mode"), "default")
    }

    func testLegacyModelsResponseWithoutOpenCodeFieldsDecodesAsEmpty() throws {
        let response = try decode(
            ModelsResponse.self,
            from: #"""
            {
              "models": [{"id": "claude-sonnet", "label": "Claude Sonnet"}],
              "codexModels": [{"id": "gpt-5-codex", "label": "GPT-5 Codex"}],
              "defaultModel": "claude-sonnet",
              "defaultCodexModel": "gpt-5-codex"
            }
            """#
        )

        XCTAssertEqual(response.models.map(\.id), ["claude-sonnet"])
        XCTAssertEqual(response.codexModels.map(\.id), ["gpt-5-codex"])
        XCTAssertTrue(response.opencodeModels.isEmpty)
        XCTAssertNil(response.defaultOpenCodeModel)
        XCTAssertEqual(response.models(for: "opencode").map(\.id), [])
        XCTAssertEqual(response.defaultModelId(for: "opencode"), "")
    }

    func testCurrentModelsResponseDecodesOpenCodeModelsAndDefaults() throws {
        let response = try decode(
            ModelsResponse.self,
            from: #"""
            {
              "models": [],
              "codexModels": [],
              "opencodeModels": [
                {"id": "anthropic/claude-sonnet-4", "label": "Claude Sonnet 4"},
                {"id": "openai/gpt-5", "label": "GPT-5", "alias": true}
              ],
              "defaultOpenCodeModel": "legacy/opencode-default",
              "defaultModels": {
                "claude": "claude-current",
                "codex": "codex-current",
                "opencode": "openai/gpt-5"
              }
            }
            """#
        )

        XCTAssertEqual(
            response.models(for: WandProvider.opencode).map(\.id),
            ["anthropic/claude-sonnet-4", "openai/gpt-5"]
        )
        XCTAssertEqual(response.defaultOpenCodeModel, "legacy/opencode-default")
        XCTAssertEqual(response.defaultModels?.opencode, "openai/gpt-5")
        XCTAssertEqual(response.defaultModelId(for: "opencode"), "openai/gpt-5")
    }

    func testLegacyServerConfigWithoutOpenCodeFieldsDecodes() throws {
        let config = try decode(
            ServerConfigInfo.self,
            from: #"{"defaultProvider":"claude","defaultModel":"claude-sonnet"}"#
        )

        XCTAssertEqual(config.defaultProvider, "claude")
        XCTAssertNil(config.defaultOpenCodeModel)
        XCTAssertNil(config.defaultModels)
        XCTAssertEqual(config.defaultModelId(for: "opencode"), "")
    }

    func testCurrentServerConfigDecodesOpenCodeFields() throws {
        let config = try decode(
            ServerConfigInfo.self,
            from: #"""
            {
              "defaultProvider": "opencode",
              "defaultOpenCodeModel": "legacy/opencode-default",
              "defaultModels": {
                "claude": "claude-current",
                "codex": "codex-current",
                "opencode": "openai/gpt-5"
              }
            }
            """#
        )

        XCTAssertEqual(config.defaultProvider, "opencode")
        XCTAssertEqual(config.defaultOpenCodeModel, "legacy/opencode-default")
        XCTAssertEqual(config.defaultModels?.opencode, "openai/gpt-5")
        XCTAssertEqual(config.defaultModelId(for: "opencode"), "openai/gpt-5")
    }

    func testToolResultExtractsTextFromStructuredContentParts() throws {
        let block = try decode(
            ContentBlock.self,
            from: #"""
            {
              "type": "tool_result",
              "tool_use_id": "tool-42",
              "is_error": true,
              "_truncated": true,
              "content": [
                {"type": "text", "text": "plain text"},
                {"type": "output_text", "output_text": "response output"},
                {"type": "message", "message": {"text": "nested message"}},
                {"type": "input_text", "input_text": "input part"},
                {"summary": "summary part"}
              ]
            }
            """#
        )

        guard case .toolResult(let toolUseID, let text, let isError, let truncated, _) = block else {
            return XCTFail("Expected tool_result block")
        }
        XCTAssertEqual(toolUseID, "tool-42")
        XCTAssertEqual(
            text,
            "plain text\nresponse output\nnested message\ninput part\nsummary part"
        )
        XCTAssertTrue(isError)
        XCTAssertTrue(truncated)
    }

    func testUnknownBlockRetainsTypeAndRedactedPayload() throws {
        let block = try decode(
            ContentBlock.self,
            from: #"""
            {
              "type": "future_protocol_block",
              "title": "safe title",
              "token": "top-level-secret",
              "nested": {
                "api_key": "nested-secret",
                "Authorization": "Bearer hidden",
                "message": "safe message"
              },
              "debug": "Authorization: Bearer embedded-secret-value",
              "args": ["OPENAI_API_KEY=sk-embedded-secret-value"],
              "url": "https://example.test/path?access_token=query-secret-value&safe=1"
            }
            """#
        )

        guard case .unknown(let type, let payload) = block else {
            return XCTFail("Expected unknown block")
        }
        XCTAssertEqual(type, "future_protocol_block")
        XCTAssertTrue(payload.contains("safe title"))
        XCTAssertTrue(payload.contains("safe message"))
        XCTAssertTrue(payload.contains("••••••"))
        XCTAssertFalse(payload.contains("top-level-secret"))
        XCTAssertFalse(payload.contains("nested-secret"))
        XCTAssertFalse(payload.contains("Bearer hidden"))
        XCTAssertFalse(payload.contains("embedded-secret-value"))
        XCTAssertFalse(payload.contains("query-secret-value"))
    }

    func testStructuredToolContentDoesNotApplyUnknownPayloadSummaryLimit() throws {
        let longValue = String(repeating: "x", count: 12_000) + "-tail"
        let data = try JSONSerialization.data(withJSONObject: [
            "tool_use_id": "tool-full",
            "content": ["raw": longValue],
            "is_error": false,
        ])
        let response = try JSONDecoder().decode(ToolContentResponse.self, from: data)

        XCTAssertEqual(response.toolUseId, "tool-full")
        XCTAssertTrue(response.text.contains("-tail"))
        XCTAssertFalse(response.text.contains("载荷已截断"))
        XCTAssertGreaterThan(response.text.count, 12_000)
    }

    func testSubagentActivitiesGroupBlocksAndOnlyParentResultCompletes() {
        let meta = SubagentMeta(taskId: "task-1", agentType: "Explore", taskDescription: "Inspect the project")
        let messages = [
            ConversationTurn(role: "user", content: [.text(text: "Find it", subagent: nil)]),
            ConversationTurn(role: "assistant", content: [
                .toolUse(id: "task-1", name: "Task", description: nil, input: [:], subagent: meta),
                .text(text: "Searching", subagent: meta),
                .toolResult(toolUseId: "nested-read", text: "result", isError: true, truncated: false, subagent: meta),
            ]),
            ConversationTurn(role: "assistant", content: [
                .toolResult(toolUseId: "task-1", text: "done", isError: false, truncated: false, subagent: meta),
            ]),
        ]

        let activities = collectSubagentActivities(messages: messages, isResponding: true)

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities[0].id, "task-1")
        XCTAssertEqual(activities[0].blocks.count, 4)
        XCTAssertEqual(activities[0].state, .completed)
    }

    func testSubagentActivityFailureAndRunningScopeFollowParentTurns() {
        let runningMeta = SubagentMeta(taskId: "running", agentType: "Code", taskDescription: nil)
        let failedMeta = SubagentMeta(taskId: "failed", agentType: "Review", taskDescription: nil)
        let messages = [
            ConversationTurn(role: "assistant", content: [
                .text(text: "old work", subagent: runningMeta),
            ]),
            ConversationTurn(role: "user", content: [.text(text: "New request", subagent: nil)]),
            ConversationTurn(role: "assistant", content: [
                .thinking(thinking: "checking", subagent: runningMeta),
                .toolUse(id: "failed", name: "Task", description: nil, input: [:], subagent: failedMeta),
                .toolResult(toolUseId: "failed", text: "failed", isError: true, truncated: false, subagent: failedMeta),
            ]),
        ]

        let activities = collectSubagentActivities(messages: messages, isResponding: true)

        XCTAssertEqual(activities.first(where: { $0.id == "running" })?.state, .running)
        XCTAssertEqual(activities.first(where: { $0.id == "failed" })?.state, .failed)

        let staleMessages = messages + [ConversationTurn(role: "user", content: [.text(text: "Follow up", subagent: nil)])]
        XCTAssertEqual(
            collectSubagentActivities(messages: staleMessages, isResponding: true)
                .first(where: { $0.id == "running" })?.state,
            .completed
        )
    }

    func testParentTranscriptFiltersSubagentBlocks() {
        let meta = SubagentMeta(taskId: "task-1", agentType: "Explore", taskDescription: nil)
        let parent = ContentBlock.text(text: "Parent reply", subagent: nil)
        let dispatch = ContentBlock.toolUse(
            id: "task-1", name: "Task", description: nil, input: [:], subagent: meta
        )
        let child = ContentBlock.text(text: "Child reply", subagent: meta)

        let blocks = parentTranscriptBlocks([parent, dispatch, child])

        XCTAssertEqual(blocks.count, 1)
        guard case .text(let text, _) = blocks[0] else {
            return XCTFail("Expected parent text")
        }
        XCTAssertEqual(text, "Parent reply")
    }

    func testTodoActiveIndexPrefersExplicitInProgressTask() {
        let todos = [
            todo(status: "pending"),
            todo(status: "in_progress"),
            todo(status: "pending"),
        ]

        XCTAssertEqual(TodoItem.activeIndex(in: todos), 1)
    }

    func testTodoActiveIndexInfersFirstPendingTaskForBinaryStatusProtocol() {
        let todos = [
            todo(status: "completed"),
            todo(status: "completed"),
            todo(status: "pending"),
        ]

        XCTAssertEqual(TodoItem.activeIndex(in: todos), 2)
    }

    func testTodoActiveIndexIsNilWhenEveryTaskIsCompleted() {
        let todos = [todo(status: "completed"), todo(status: "completed")]

        XCTAssertNil(TodoItem.activeIndex(in: todos))
    }

    private func todo(status: String) -> TodoItem {
        TodoItem(content: "Task", status: status, activeForm: nil)
    }

    private func turn(_ value: String, role: String = "user") -> ConversationTurn {
        ConversationTurn(role: role, content: [.text(text: value, subagent: nil)])
    }

    private func text(_ turn: ConversationTurn) -> String {
        guard case .text(let value, _) = turn.content.first else { return "" }
        return value
    }

    private func messageWindow(
        messages: [ConversationTurn],
        loadedOffset: Int,
        messageTotal: Int,
        leadingBlockOffset: Int,
        leadingBlockTotal: Int
    ) -> SessionMessageWindow {
        SessionMessageWindow(
            messages: messages,
            loadedOffset: loadedOffset,
            messageTotal: messageTotal,
            leadingBlockOffset: leadingBlockOffset,
            leadingBlockTotal: leadingBlockTotal
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: XCTUnwrap(json.data(using: .utf8)))
    }
}

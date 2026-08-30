import XCTest
@testable import Nirux

final class ActivityStoreTests: XCTestCase {
    private func makeEvent(
        _ name: AgentHookEvent.Name,
        kind: AgentHookEvent.Kind = .claude,
        detail: String? = nil
    ) -> AgentHookEvent {
        var payload: [String: Any] = ["cwd": "/tmp/ws"]
        switch kind {
        case .claude:
            let hookNames: [AgentHookEvent.Name: String] = [
                .sessionStart: "SessionStart",
                .userPromptSubmit: "UserPromptSubmit",
                .preToolUse: "PreToolUse",
                .notification: "Notification",
                .stop: "Stop",
                .sessionEnd: "SessionEnd",
                .turnComplete: "?"
            ]
            payload["hook_event_name"] = hookNames[name]
            if name == .notification { payload["message"] = detail }
        case .codex:
            payload["type"] = "agent-turn-complete"
            payload["last-assistant-message"] = detail
        }
        return AgentHookEvent(
            kind: kind, payload: payload,
            env: ["NIRUX_AGENT_UUID": "u1", "NIRUX_WORKSPACE_ID": "ws-1"],
            now: 1_000
        )!
    }

    func testSignalEventsBecomeEntries() {
        XCTAssertEqual(
            ActivityEntry(event: makeEvent(.notification, detail: "needs permission"),
                          workspaceTitle: "ws", columnIndex: 2)?.category, .attention)
        XCTAssertEqual(
            ActivityEntry(event: makeEvent(.stop), workspaceTitle: "ws", columnIndex: 0)?.category,
            .turnComplete)
        XCTAssertEqual(
            ActivityEntry(event: makeEvent(.turnComplete, kind: .codex),
                          workspaceTitle: "ws", columnIndex: nil)?.category, .turnComplete)
        XCTAssertEqual(
            ActivityEntry(event: makeEvent(.sessionStart), workspaceTitle: "ws", columnIndex: nil)?.category,
            .sessionStart)
        XCTAssertEqual(
            ActivityEntry(event: makeEvent(.sessionEnd), workspaceTitle: "ws", columnIndex: nil)?.category,
            .sessionEnd)
    }

    func testChattyEventsAreFiltered() {
        XCTAssertNil(ActivityEntry(event: makeEvent(.userPromptSubmit), workspaceTitle: "ws", columnIndex: nil))
        XCTAssertNil(ActivityEntry(event: makeEvent(.preToolUse, detail: "Bash"), workspaceTitle: "ws", columnIndex: nil))
    }

    func testEntryFields() {
        let entry = ActivityEntry(
            event: makeEvent(.notification, detail: "needs permission"),
            workspaceTitle: "nirux", columnIndex: 3)
        XCTAssertEqual(entry?.agentKind, "claude")
        XCTAssertEqual(entry?.workspaceID, "ws-1")
        XCTAssertEqual(entry?.columnIndex, 3)
        XCTAssertEqual(entry?.workspaceTitle, "nirux")
        XCTAssertEqual(entry?.detail, "needs permission")
        XCTAssertEqual(entry?.timestamp, 1_000)
    }

    @MainActor
    func testStoreCapsAndKeepsNewestFirst() {
        let store = makeStore()
        for index in 0..<120 {
            store.record(ActivityEntry(
                category: .turnComplete, agentKind: "claude", workspaceID: "ws",
                columnIndex: nil, workspaceTitle: "ws", detail: nil,
                timestamp: TimeInterval(index)
            ))
        }
        XCTAssertEqual(store.entries.count, 100)
        XCTAssertEqual(store.entries.first?.timestamp, 119)
        XCTAssertEqual(store.entries.last?.timestamp, 20)
    }

    private func makeEntry(
        _ category: ActivityEntry.Category, timestamp: TimeInterval,
        workspaceID: String? = "ws", columnIndex: Int? = nil, agentUUID: String? = nil
    ) -> ActivityEntry {
        ActivityEntry(
            category: category, agentKind: "claude", agentUUID: agentUUID,
            workspaceID: workspaceID, columnIndex: columnIndex,
            workspaceTitle: "ws", detail: nil, timestamp: timestamp
        )
    }

    /// Never `ActivityStore()` in tests: record()/markRead() schedule real
    /// writes into the developer's live state directory.
    @MainActor
    private func makeStore() -> ActivityStore {
        ActivityStore(persistsToDisk: false)
    }

    @MainActor
    func testFeedEntriesDropLifecycleNoise() {
        let store = makeStore()
        store.record(makeEntry(.sessionStart, timestamp: 1))
        store.record(makeEntry(.attention, timestamp: 2))
        store.record(makeEntry(.sessionEnd, timestamp: 3))
        store.record(makeEntry(.turnComplete, timestamp: 4, columnIndex: 1))
        XCTAssertEqual(store.entries.count, 4, "history keeps everything")
        XCTAssertEqual(store.feedEntries.map(\.timestamp), [4, 2], "feed shows signals only")
    }

    @MainActor
    func testFeedEntriesCoalesceConsecutiveSameColumnRepeats() {
        let store = makeStore()
        store.record(makeEntry(.turnComplete, timestamp: 1, columnIndex: 0))
        store.record(makeEntry(.turnComplete, timestamp: 2, columnIndex: 0))
        store.record(makeEntry(.sessionEnd, timestamp: 3))  // lifecycle doesn't break a run
        store.record(makeEntry(.turnComplete, timestamp: 4, columnIndex: 0))
        store.record(makeEntry(.turnComplete, timestamp: 5, columnIndex: 1))
        store.record(makeEntry(.attention, timestamp: 6, columnIndex: 1))
        store.record(makeEntry(.turnComplete, timestamp: 7, workspaceID: "other", columnIndex: 0))
        XCTAssertEqual(
            store.feedEntries.map(\.timestamp), [7, 6, 5, 4],
            "consecutive same-column same-category repeats keep only the newest"
        )
    }

    @MainActor
    func testUnreadCountAndMarkAllRead() {
        let store = makeStore()
        XCTAssertEqual(store.unreadCount, 0)
        store.record(makeEntry(.attention, timestamp: 10))
        store.record(makeEntry(.sessionStart, timestamp: 11))
        store.record(makeEntry(.turnComplete, timestamp: 12))
        XCTAssertEqual(store.unreadCount, 2, "lifecycle rows don't count toward the badge")

        store.markAllRead()
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.lastReadTimestamp, 12)

        store.record(makeEntry(.attention, timestamp: 13))
        XCTAssertEqual(store.unreadCount, 1, "new entries after markAllRead are unread again")
    }

    @MainActor
    func testMarkReadUpToCutoffLeavesNewerEntriesUnread() {
        let store = makeStore()
        store.record(makeEntry(.attention, timestamp: 10))
        let cutoff = store.newestTimestamp
        XCTAssertEqual(cutoff, 10)
        // Arrives mid-dwell, after the cutoff was captured.
        store.record(makeEntry(.attention, timestamp: 11, columnIndex: 1))

        store.markRead(upTo: cutoff!)
        XCTAssertEqual(store.unreadCount, 1, "an entry newer than the dwell cutoff stays unread")
        XCTAssertEqual(store.lastReadTimestamp, 10)
    }

    @MainActor
    func testMarkReadIsMonotonic() {
        let store = makeStore()
        store.record(makeEntry(.attention, timestamp: 50))
        store.markAllRead()
        store.markRead(upTo: 40)
        XCTAssertEqual(store.lastReadTimestamp, 50, "the read mark never moves backwards")
    }

    @MainActor
    func testCoalescingRespectsAgentIdentity() {
        let store = makeStore()
        store.record(makeEntry(.turnComplete, timestamp: 1, columnIndex: 0, agentUUID: "a"))
        store.record(makeEntry(.turnComplete, timestamp: 2, columnIndex: 0, agentUUID: "b"))
        XCTAssertEqual(
            store.feedEntries.count, 2,
            "same column but different agents (session restarted) must not merge"
        )
    }

    func testAttentionSupersededByNewerSignalFromSameAgent() {
        let feed = [
            makeEntry(.turnComplete, timestamp: 30, agentUUID: "a"),
            makeEntry(.attention, timestamp: 20, agentUUID: "a"),
            makeEntry(.attention, timestamp: 10, agentUUID: "b")
        ]
        XCTAssertTrue(
            ActivityStore.isAttentionSuperseded(at: 1, in: feed),
            "agent a signaled again after asking for input"
        )
        XCTAssertFalse(
            ActivityStore.isAttentionSuperseded(at: 2, in: feed),
            "agent b is still waiting"
        )
        XCTAssertFalse(
            ActivityStore.isAttentionSuperseded(at: 0, in: feed),
            "only attention rows can be superseded"
        )
        XCTAssertFalse(ActivityStore.isAttentionSuperseded(at: 9, in: feed), "out of bounds is false")
    }

    func testAttentionSupersededFallsBackToPosition() {
        let feed = [
            makeEntry(.turnComplete, timestamp: 30, columnIndex: 1),
            makeEntry(.attention, timestamp: 20, columnIndex: 1),
            makeEntry(.attention, timestamp: 10, columnIndex: 2)
        ]
        XCTAssertTrue(ActivityStore.isAttentionSuperseded(at: 1, in: feed))
        XCTAssertFalse(ActivityStore.isAttentionSuperseded(at: 2, in: feed))
    }

    func testAttentionFromUnidentifiedSessionsNeverSupersedeEachOther() {
        // Hooks running outside Nirux: no uuid, no workspace, no column.
        let feed = [
            makeEntry(.turnComplete, timestamp: 30, workspaceID: nil),
            makeEntry(.attention, timestamp: 20, workspaceID: nil)
        ]
        XCTAssertFalse(
            ActivityStore.isAttentionSuperseded(at: 1, in: feed),
            "two unrelated external sessions must not mark each other handled"
        )
    }

    func testEntryCapturesAgentUUIDAndDecodesWithoutIt() throws {
        let entry = ActivityEntry(
            event: makeEvent(.notification, detail: "x"), workspaceTitle: "ws", columnIndex: 0
        )
        XCTAssertEqual(entry?.agentUUID, "u1", "hook env NIRUX_AGENT_UUID flows into the entry")

        // Entries persisted by builds that predate agentUUID must decode.
        let legacyJSON = """
        [{"category":"attention","agentKind":"claude","workspaceID":"ws",\
        "workspaceTitle":"ws","timestamp":5}]
        """
        let decoded = try JSONDecoder().decode([ActivityEntry].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.first?.agentUUID, nil)
        XCTAssertEqual(decoded.first?.timestamp, 5)
    }

    @MainActor
    func testMissionEventsAreFeedSignalsAndDeliveryIsDeduplicated() {
        let store = makeStore()
        let missionEntry = ActivityEntry(
            category: .missionQuestion,
            agentKind: "codex",
            agentUUID: "child-agent",
            workspaceID: "child-workspace",
            columnIndex: 0,
            workspaceTitle: "feat/mission",
            detail: "Which API?",
            timestamp: 10,
            missionID: "mission-1",
            missionEventID: "event-1"
        )
        store.record(missionEntry)
        store.record(missionEntry)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.feedEntries, [missionEntry])
        XCTAssertEqual(store.unreadCount, 1)
    }

    @MainActor
    func testDistinctMissionQuestionsRemainSeparateFeedRows() {
        let store = makeStore()
        for (eventID, timestamp) in [("event-1", 10.0), ("event-2", 20.0)] {
            store.record(ActivityEntry(
                category: .missionQuestion,
                agentKind: "codex",
                agentUUID: "child-agent",
                workspaceID: "child-workspace",
                columnIndex: 0,
                workspaceTitle: "feat/mission",
                detail: "Question \(eventID)",
                timestamp: timestamp,
                missionID: "mission-1",
                missionEventID: eventID
            ))
        }

        XCTAssertEqual(store.feedEntries.map(\.missionEventID), ["event-2", "event-1"])
        XCTAssertEqual(store.unreadCount, 2)
    }

    @MainActor
    func testPendingMissionQuestionsStayVisibleBeyondRecentRowLimit() {
        let store = makeStore()
        let question = ActivityEntry(
            category: .missionQuestion,
            agentKind: "codex",
            workspaceID: "child-workspace",
            columnIndex: 0,
            workspaceTitle: "feat/mission",
            detail: "Which API?",
            timestamp: 1,
            missionID: "mission-1",
            missionEventID: "question-1"
        )
        store.record(question)
        for index in 2...7 {
            store.record(ActivityEntry(
                category: .turnComplete,
                agentKind: "codex",
                workspaceID: "workspace-\(index)",
                columnIndex: index,
                workspaceTitle: "workspace-\(index)",
                detail: "Done",
                timestamp: TimeInterval(index)
            ))
        }

        let visible = store.visibleFeedEntries(maxCount: 6)

        XCTAssertEqual(visible.count, 6)
        XCTAssertTrue(visible.contains(question))
        XCTAssertEqual(visible.first?.timestamp, 7)

        store.record(ActivityEntry(
            category: .missionResponse,
            agentKind: "parent",
            workspaceID: "child-workspace",
            columnIndex: 0,
            workspaceTitle: "feat/mission",
            detail: "Use AuthService",
            timestamp: 8,
            missionID: "mission-1",
            missionEventID: "response-1",
            missionReplyToEventID: "question-1"
        ))

        XCTAssertFalse(store.visibleFeedEntries(maxCount: 6).contains(question))
    }

    func testMissionCompletionSupersedesEarlierQuestion() {
        let completed = ActivityEntry(
            category: .missionCompleted,
            agentKind: "codex",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Done",
            timestamp: 20,
            missionID: "mission-1",
            missionEventID: "event-2"
        )
        let question = ActivityEntry(
            category: .missionQuestion,
            agentKind: "codex",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Which API?",
            timestamp: 10,
            missionID: "mission-1",
            missionEventID: "event-1"
        )
        XCTAssertTrue(ActivityStore.isAttentionSuperseded(at: 1, in: [completed, question]))
    }

    func testMissionResponseSupersedesEarlierQuestion() {
        let response = ActivityEntry(
            category: .missionResponse,
            agentKind: "codex",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Use AuthService",
            timestamp: 20,
            missionID: "mission-1",
            missionEventID: "event-2",
            missionReplyToEventID: "event-1"
        )
        let question = ActivityEntry(
            category: .missionQuestion,
            agentKind: "codex",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Which API?",
            timestamp: 10,
            missionID: "mission-1",
            missionEventID: "event-1"
        )
        XCTAssertTrue(ActivityStore.isAttentionSuperseded(at: 1, in: [response, question]))
    }

    func testMissionResponseOnlySupersedesItsReferencedQuestion() {
        let response = ActivityEntry(
            category: .missionResponse,
            agentKind: "parent",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Use AuthService",
            timestamp: 30,
            missionID: "mission-1",
            missionEventID: "response-1",
            missionReplyToEventID: "question-2"
        )
        let secondQuestion = ActivityEntry(
            category: .missionQuestion,
            agentKind: "codex",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Which auth API?",
            timestamp: 20,
            missionID: "mission-1",
            missionEventID: "question-2"
        )
        let firstQuestion = ActivityEntry(
            category: .missionQuestion,
            agentKind: "codex",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Which storage API?",
            timestamp: 10,
            missionID: "mission-1",
            missionEventID: "question-1"
        )
        let feed = [response, secondQuestion, firstQuestion]

        XCTAssertTrue(ActivityStore.isAttentionSuperseded(at: 1, in: feed))
        XCTAssertFalse(ActivityStore.isAttentionSuperseded(at: 2, in: feed))
    }

    @MainActor
    func testMissionResponseClearsQuestionFromUnreadCount() {
        let store = makeStore()
        let question = ActivityEntry(
            category: .missionQuestion,
            agentKind: "codex",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Which API?",
            timestamp: 10,
            missionID: "mission-1",
            missionEventID: "event-1"
        )
        let response = ActivityEntry(
            category: .missionResponse,
            agentKind: "parent",
            workspaceID: "child",
            columnIndex: 0,
            workspaceTitle: "child",
            detail: "Use AuthService",
            timestamp: 20,
            missionID: "mission-1",
            missionEventID: "event-2",
            missionReplyToEventID: "event-1"
        )

        store.record(question)
        XCTAssertEqual(store.unreadCount, 1)
        store.record(response)
        XCTAssertEqual(store.unreadCount, 0)
    }

    @MainActor
    func testHookCenterRoutesAttentionAndTurnCompleteIntoActivity() {
        let store = makeStore()
        let center = AgentHookCenter()
        center.onEventReceived = { event, resolution in
            store.record(
                event,
                workspaceTitle: resolution?.workspace.title ?? event.cwd ?? "External agent",
                columnIndex: resolution?.columnIndex
            )
        }

        center.dispatch(makeEvent(.notification, detail: "needs permission"))
        center.dispatch(makeEvent(.turnComplete, kind: .codex, detail: "done"))

        XCTAssertEqual(store.feedEntries.map(\.category), [.turnComplete, .attention])
    }

    func testInitialReadTimestampWithoutSidecarTreatsHistoryAsRead() {
        let history = [makeEntry(.attention, timestamp: 7), makeEntry(.turnComplete, timestamp: 9)]
        XCTAssertEqual(
            ActivityStore.initialReadTimestamp(entries: history, sidecar: nil), 9,
            "pre-update history must not light up the badge"
        )
        XCTAssertEqual(ActivityStore.initialReadTimestamp(entries: [], sidecar: nil), 0)
        XCTAssertEqual(
            ActivityStore.initialReadTimestamp(entries: history, sidecar: 7), 7,
            "an existing sidecar wins over the history heuristic"
        )
    }

    func testReadStateSidecarRoundtrip() throws {
        let data = try JSONEncoder().encode(["lastReadTimestamp": 123.5])
        XCTAssertEqual(ActivityStore.decodeReadState(data), 123.5)
        XCTAssertNil(ActivityStore.decodeReadState(Data("not json".utf8)))
    }

    func testRelativeAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(SidebarView.relativeAge(since: 10_000 - 42, now: now), "42s")
        XCTAssertEqual(SidebarView.relativeAge(since: 10_000 - 720, now: now), "12m")
        XCTAssertEqual(SidebarView.relativeAge(since: 10_000 - 3_900, now: now), "1h05")
        XCTAssertEqual(SidebarView.relativeAge(since: 10_000 - 3 * 86_400, now: now), "3d")
        XCTAssertEqual(SidebarView.relativeAge(since: 10_001, now: now), "0s", "future clamps to zero")
    }
}

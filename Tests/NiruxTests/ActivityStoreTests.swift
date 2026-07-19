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
        workspaceID: String? = "ws", columnIndex: Int? = nil
    ) -> ActivityEntry {
        ActivityEntry(
            category: category, agentKind: "claude", workspaceID: workspaceID,
            columnIndex: columnIndex, workspaceTitle: "ws", detail: nil, timestamp: timestamp
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

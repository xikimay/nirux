import os
import XCTest
@testable import Nirux

/// Sending a Branch Review's comments to its agent (docs/branch-review.md,
/// section 6.2): the paste, when the comments count as sent, and what the
/// sheet says.
final class BranchReviewSendTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: - The paste

    /// A terminal whose program reads only after a second, raw: nothing
    /// waits for a line's end.
    @MainActor
    private func slowReader(into file: URL) async throws -> PtySession {
        let pty = PtySession()
        pty.start(shell: "/bin/zsh", args: ["-f", "-c", "stty raw -echo; sleep 1; exec /bin/cat > '\(file.path)'"], cwd: directory.path)
        // Let the shell set the terminal raw first.
        try await Task.sleep(for: .milliseconds(300))
        return pty
    }

    /// A long paste goes in full, off the main thread: the terminal's input
    /// queue takes about a kilobyte, then waits for the agent to read. The
    /// terminal's own descriptor stays open for the next one.
    @MainActor
    func testLongPasteGoesInFullWithoutHoldingTheApp() async throws {
        let file = directory.appendingPathComponent("received")
        let pty = try await slowReader(into: file)
        let line = String(repeating: "x", count: 63) + "\n"
        let text = BranchReview.agentPaste(String(repeating: line, count: 3_000))
        var outcome: PtySession.PasteOutcome?
        let started = Date()
        pty.pasteInBackground(text, keepingInFront: nil, cancelled: { false }) { outcome = $0 }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "the app isn't held while the agent doesn't read")
        let done = try await waitUntil { outcome != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(outcome, .pasted)
        let received = try await waitUntil { (try? Data(contentsOf: file))?.count == text.utf8.count }
        XCTAssertTrue(received, "every byte, through short writes")
        XCTAssertEqual(try Data(contentsOf: file), Data(text.utf8))

        outcome = nil
        pty.pasteInBackground("again", keepingInFront: nil, cancelled: { false }) { outcome = $0 }
        let again = try await waitUntil { outcome != nil }
        XCTAssertTrue(again)
        XCTAssertEqual(outcome, .pasted)
        let both = try await waitUntil { (try? Data(contentsOf: file))?.count == text.utf8.count + 5 }
        XCTAssertTrue(both)
    }

    /// A terminal that isn't running takes nothing, and says so.
    @MainActor
    func testPasteIntoATerminalNotRunningSaysSo() async throws {
        let pty = PtySession()
        var outcome: PtySession.PasteOutcome?
        pty.pasteInBackground("hi", keepingInFront: nil, cancelled: { false }) { outcome = $0 }
        let done = try await waitUntil { outcome != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(outcome, .closed)
        XCTAssertEqual(pty.reviewSendRefusal(snapshot: ProcessSnapshot()), .noAgent)
    }

    /// Cancelled, or past its deadline, a paste the agent still has ends
    /// (`ESC[201~`), once there is room for it: a pipe read only from then.
    func testStoppedPasteEndsTheAgentsPaste() throws {
        for stop in ["cancel", "deadline"] {
            var ends: [Int32] = [0, 0]
            XCTAssertEqual(pipe(&ends), 0)
            let (reader, writer) = (ends[0], ends[1])
            let reading = OSAllocatedUnfairLock(initialState: false)
            let received = OSAllocatedUnfairLock(initialState: Data())
            let drained = DispatchSemaphore(value: 0)
            Thread {
                while !reading.withLock({ $0 }) { usleep(10_000) }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = Darwin.read(reader, &buffer, buffer.count)
                    if count <= 0 { break }
                    let chunk = Array(buffer[0..<count])
                    received.withLock { $0.append(contentsOf: chunk) }
                }
                close(reader)
                drained.signal()
            }.start()
            // More than a pipe holds.
            let payload = Data(repeating: 0x61, count: 200_000)
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            DispatchQueue.global().asyncAfter(deadline: .now() + (stop == "cancel" ? 0.3 : 0.6)) {
                if stop == "cancel" { cancelled.withLock { $0 = true } }
                reading.withLock { $0 = true }
            }
            let outcome = PtySession.writePaste(
                payload, to: writer, group: nil, cancelled: { cancelled.withLock { $0 } },
                deadline: stop == "cancel" ? .distantFuture : Date().addingTimeInterval(0.3)
            )
            close(writer)
            XCTAssertEqual(drained.wait(timeout: .now() + 10), .success)
            XCTAssertEqual(outcome, stop == "cancel" ? .cancelled : .timedOut)
            let data = received.withLock { $0 }
            XCTAssertLessThan(data.count, payload.count + 6, stop)
            XCTAssertEqual(String(decoding: data.suffix(6), as: UTF8.self), "\u{1B}[201~", stop)
        }
    }

    /// An agent that never reads: Cancel and the deadline still end the
    /// paste, whatever is left (a write longer than the room would block).
    @MainActor
    func testPasteToAnAgentThatDoesntReadStillEnds() async throws {
        let pty = PtySession()
        pty.start(shell: "/bin/zsh", args: ["-f", "-c", "stty raw -echo; sleep 60"], cwd: directory.path)
        try await Task.sleep(for: .milliseconds(300))
        let group = try XCTUnwrap(pty.foregroundInstance(snapshot: ProcessSnapshot()).map { getpgid($0.pid) })
        let fd = try XCTUnwrap(pty.duplicateDescriptorForTests())
        defer { close(fd) }
        let paste = Data(String(repeating: "z", count: 5_000).utf8)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let writing = Task.detached {
            PtySession.writePaste(paste, to: fd, group: group, cancelled: { cancelled.withLock { $0 } }, deadline: .distantFuture)
        }
        try await Task.sleep(for: .milliseconds(300))
        cancelled.withLock { $0 = true }
        let started = Date()
        let outcome = await writing.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let timedOut = PtySession.writePaste(paste, to: fd, group: group, cancelled: { false }, deadline: Date().addingTimeInterval(0.5))
        XCTAssertEqual(timedOut, .timedOut)
    }

    /// The agent left: what it left unread is dropped, and nothing more
    /// goes; one already gone gets nothing at all.
    @MainActor
    func testWhatTheAgentLeftUnreadIsDropped() async throws {
        let file = directory.appendingPathComponent("received")
        let pty = try await slowReader(into: file)
        let group = try XCTUnwrap(pty.foregroundInstance(snapshot: ProcessSnapshot()).map { getpgid($0.pid) })
        let fd = try XCTUnwrap(pty.duplicateDescriptorForTests())
        defer { close(fd) }
        let queued = Data(String(repeating: "a", count: 500).utf8)
        XCTAssertEqual(PtySession.writePaste(queued, to: fd, group: group, cancelled: { false }, deadline: .distantFuture), .pasted)
        XCTAssertEqual(PtySession.writePaste(Data("b".utf8), to: fd, group: getpid(), cancelled: { false }, deadline: .distantFuture), .agentLeft)
        // The reader reads after a second: nothing.
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual((try? Data(contentsOf: file))?.count ?? 0, 0)

        var outcome: PtySession.PasteOutcome?
        pty.pasteInBackground("c", keepingInFront: ProcessInstance(pid: 999_999, startedAt: 0), cancelled: { false }) { outcome = $0 }
        let done = try await waitUntil { outcome != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(outcome, .agentLeft)
    }

    /// The header may follow what was typed before the paste on its line.
    func testHeaderIsFoundAfterWhatWasTypedBefore() {
        XCTAssertEqual(BranchReview.agentMessageHeader(in: "fix these: \(header)\n\n1. A.swift"), header)
        XCTAssertNil(BranchReview.agentMessageHeader(in: "Review comments on feat/x, from me"))
    }

    // MARK: - Sent once Claude takes the prompt

    private let header = "Review comments on feat/x (head abcdef1), from Nirux:"

    /// The receiver keeps, of a prompt, the header line of the message it
    /// holds, the paste expanded; nothing of one without.
    func testPromptKeepsOnlyTheMessagesHeader() throws {
        let message = "\(header)\n\n1. A.swift:2\n   > + secret = 1\n   Why?"
        func event(_ prompt: String) -> AgentHookEvent? {
            AgentHookEvent(
                kind: .claude, payload: ["hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": prompt], env: [:], now: 1
            )
        }
        XCTAssertEqual(try XCTUnwrap(event("Please look.\n" + message)).reviewHeader, header)
        XCTAssertNil(try XCTUnwrap(event("Review comments on feat/x, in my words")).reviewHeader)
        let encoded = String(decoding: try JSONEncoder().encode(try XCTUnwrap(event(message))), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret"), "only that line is kept")
    }

    /// The comments count as sent on the main thread's next prompt after
    /// the paste that holds their message, from the `claude` it went to:
    /// not a subagent's, not one of before, not one without it; and once.
    func testCommentsAreSentOnceThePromptHoldingThemGoesIn() {
        let pty = PtySession()
        let pasted: TimeInterval = 1_790_000_000
        let claude = ProcessInstance(pid: 4242, startedAt: pasted - 60)
        let settled = OSAllocatedUnfairLock(initialState: [Bool]())
        pty.onNextPrompt(after: pasted, from: claude, header: header) { taken in settled.withLock { $0.append(taken) } }
        func prompt(at time: TimeInterval, agent: String? = nil, holding header: String? = nil) {
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: .userPromptSubmit, sessionID: "s", emitterProcess: claude, agentID: agent,
                reviewHeader: header, timestamp: time
            ), isUserFocused: false)
        }
        prompt(at: pasted - 1, holding: header)
        prompt(at: pasted + 1, agent: "sub", holding: header)
        XCTAssertEqual(settled.withLock { $0 }, [])
        prompt(at: pasted + 2, holding: header)
        XCTAssertEqual(settled.withLock { $0 }, [true])
        prompt(at: pasted + 3, holding: header)
        XCTAssertEqual(settled.withLock { $0 }, [true], "once")

        // A prompt without it (Claude takes the whole input: the paste was
        // cleared, or set aside), or another message's, lets its comments
        // go; it is still listened for (a stash Claude brings back).
        for other in [nil, "Review comments on feat/y (head 1234567), from Nirux:"] {
            let cleared = OSAllocatedUnfairLock(initialState: [Bool]())
            pty.onNextPrompt(after: pasted, from: claude, header: header) { taken in cleared.withLock { $0.append(taken) } }
            prompt(at: pasted + 4, holding: other)
            XCTAssertEqual(cleared.withLock { $0 }, [false])
            prompt(at: pasted + 4.5, holding: header)
            XCTAssertEqual(cleared.withLock { $0 }, [false, true])
        }
        // Pasted again with the same header: the one before is let go,
        // not taken for what the new one holds.
        let first = OSAllocatedUnfairLock(initialState: [Bool]())
        let second = OSAllocatedUnfairLock(initialState: [Bool]())
        pty.onNextPrompt(after: pasted, from: claude, header: header) { taken in first.withLock { $0.append(taken) } }
        pty.onNextPrompt(after: pasted + 5, from: claude, header: header) { taken in second.withLock { $0.append(taken) } }
        prompt(at: pasted + 6, holding: header)
        XCTAssertEqual(first.withLock { $0 }, [false])
        XCTAssertEqual(second.withLock { $0 }, [true])
    }

    /// A paste no prompt can take any more is let go: a new session (the
    /// prompt it sat in is gone), another `claude`'s prompt, a day later.
    func testPasteWaitingForItsPromptIsLetGo() {
        let pasted: TimeInterval = 1_790_000_000
        let claude = ProcessInstance(pid: 4242, startedAt: pasted - 60)
        let restarted = ProcessInstance(pid: 4343, startedAt: pasted)
        for (name, process, time, source) in [
            (AgentHookEvent.Name.sessionStart, claude, pasted + 1, "clear"),
            (.sessionEnd, claude, pasted + 1, nil),
            (.userPromptSubmit, restarted, pasted + 1, nil),
            (.notification, claude, pasted + 2 + PtySession.promptWatchLimit, nil)
        ] as [(AgentHookEvent.Name, ProcessInstance, TimeInterval, String?)] {
            let pty = PtySession()
            let settled = OSAllocatedUnfairLock(initialState: [Bool]())
            pty.onNextPrompt(after: pasted, from: claude, header: header) { taken in settled.withLock { $0.append(taken) } }
            // Compacting keeps the prompt.
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: .sessionStart, sessionID: "s", emitterProcess: claude, source: "compact", timestamp: pasted + 1
            ), isUserFocused: false)
            XCTAssertEqual(settled.withLock { $0 }, [])
            _ = pty.applyAgentHook(AgentHookEvent(
                kind: .claude, name: name, sessionID: "s", emitterProcess: process, source: source, timestamp: time
            ), isUserFocused: false)
            XCTAssertEqual(settled.withLock { $0 }, [false], "\(name)")
        }
    }

    /// Without a hook to say so: its `claude` no longer runs, or the
    /// column closed.
    @MainActor
    func testPasteIsLetGoWhenItsClaudeIsGoneOrItsColumnCloses() async throws {
        let settled = OSAllocatedUnfairLock(initialState: [Bool]())
        var pty: PtySession? = PtySession()
        pty?.onNextPrompt(after: Date().timeIntervalSince1970, from: ProcessInstance(pid: 999_999, startedAt: 0), header: header) { taken in
            settled.withLock { $0.append(taken) }
        }
        pty?.onNextPrompt(after: Date().timeIntervalSince1970, from: nil, header: "Review comments on feat/z (head 7654321), from Nirux:") { taken in
            settled.withLock { $0.append(taken) }
        }
        pty?.settlePromptWatchers(snapshot: ProcessSnapshot())
        XCTAssertEqual(settled.withLock { $0 }, [false])
        pty = nil
        let closed = try await waitUntil { settled.withLock { $0 } == [false, false] }
        XCTAssertTrue(closed)
    }

    // MARK: - The sheet

    private func send(ids: [String], leftOut: Int = 0, inPrompt: Int = 0, drafts: Int = 0, edits: Int = 0) -> BranchReviewController.AgentSend {
        BranchReviewController.AgentSend(
            message: BranchReview.AgentMessage(text: "\(header)\n\n1. A.swift:2\n   Why?", ids: ids, leftOut: leftOut),
            texts: Dictionary(uniqueKeysWithValues: ids.map { ($0, "Why?") }), inPrompt: inPrompt,
            drafts: drafts, edits: edits, branch: "feat/x", head: "abcdef1234", root: "/repo", pullRequest: 12
        )
    }

    private func column(
        _ label: String, id: UUID = UUID(), refusal: ReviewSendRefusal? = nil, hasDraft: Bool = false
    ) -> NiruxShellView.ReviewSendColumn {
        NiruxShellView.ReviewSendColumn(workspaceID: "w", columnID: id, label: label, refusal: refusal, hasDraft: hasDraft, process: nil)
    }

    /// What the sheet says: what doesn't go, the queue, and per column why
    /// it can't take the comments or what was typed there.
    @MainActor
    func testSheetSaysWhatGoesWhereAndWhatDoesnt() {
        let content = NiruxShellView.reviewSendContent(
            send(ids: ["c1", "c2"], leftOut: 1, inPrompt: 2, drafts: 2, edits: 1),
            columns: [column("api — codex", refusal: .notClaude("Codex")), column("api — claude", hasDraft: true)], queued: true
        )
        XCTAssertEqual(content.title, "Send 2 Comments to Agent")
        XCTAssertEqual(content.subtitle, "feat/x · head abcdef1")
        XCTAssertNil(content.refusal)
        XCTAssertTrue(content.canCopy)
        XCTAssertEqual(content.warnings, ["#12 is in the merge queue: the agent’s push will stop the queue."])
        XCTAssertEqual(content.notes, [
            "2 comments are already in an agent’s prompt, not submitted: they don’t go again.",
            "1 comment doesn’t fit in one message: it stays unsent, for another send.",
            "1 comment being edited goes as saved; what its edit changed stays as a new comment’s draft.",
            "2 drafts don’t go: Comment them first."
        ])
        XCTAssertEqual(content.targets.map(\.refusal), [ReviewSendRefusal.notClaude("Codex").message, nil])
        XCTAssertEqual(content.targets[1].warnings, ["Something was typed at its prompt since its last prompt: the comments join it."])

        XCTAssertEqual(
            NiruxShellView.reviewSendContent(send(ids: ["c1"]), columns: [], queued: false).refusal,
            "No agent runs in this worktree: start Claude Code in a column there (or resume it), or Copy Message."
        )
        let none = NiruxShellView.reviewSendContent(send(ids: [], leftOut: 1), columns: [column("claude")], queued: false)
        XCTAssertEqual(none.refusal, "No comment fits in one message: shorten them.")
        XCTAssertFalse(none.canCopy, "a message without a comment isn't one to copy")
        XCTAssertEqual(
            NiruxShellView.reviewSendContent(send(ids: [], inPrompt: 1), columns: [column("claude")], queued: false).refusal,
            "These comments are already in an agent’s prompt: submit it there."
        )
    }

    /// The sheet picks the first column that takes the comments; another
    /// one picked says why it can't, and Send waits for one that can. Copy
    /// Message copies the message as shown; Send names the column. Read
    /// again, the column picked stays picked, whatever the labels and their
    /// order, or none is once it is gone; what was said stays.
    @MainActor
    func testSheetSendsToTheColumnPicked() throws {
        let codex = UUID()
        let claude = UUID()
        let content = NiruxShellView.reviewSendContent(
            send(ids: ["c1"]), columns: [column("api — agent", id: codex, refusal: .notClaude("Codex")), column("api — agent", id: claude, hasDraft: true)],
            queued: false
        )
        let panel = ReviewSendPanel(content: content)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nirux-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        panel.pasteboard = pasteboard
        var sentTo: [UUID] = []
        panel.onSend = { sentTo.append($0) }
        panel.show(attachedTo: nil)
        defer { panel.dismiss() }
        XCTAssertEqual(panel.selectedID, claude)
        XCTAssertEqual(panel.lines, ["⚠︎ Something was typed at its prompt since its last prompt: the comments join it."])
        XCTAssertEqual(panel.messageView?.string, content.message)
        XCTAssertEqual(panel.sendButton?.isEnabled, true)

        let popUp = try XCTUnwrap(panel.targetPopUp)
        XCTAssertEqual(popUp.itemTitles, ["api — agent", "api — agent"], "labels that repeat both show")
        popUp.selectItem(at: 0)
        _ = popUp.target?.perform(popUp.action, with: popUp)
        XCTAssertEqual(panel.lines, [ReviewSendRefusal.notClaude("Codex").message])
        XCTAssertEqual(panel.sendButton?.isEnabled, false)
        panel.sendButton?.performClick(nil)
        XCTAssertEqual(sentTo, [])

        panel.copyButton?.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), content.message)
        XCTAssertEqual(panel.statusLabel?.stringValue, "Copied: paste it into the agent’s prompt yourself.")
        popUp.selectItem(at: 1)
        _ = popUp.target?.perform(popUp.action, with: popUp)
        panel.sendButton?.performClick(nil)
        XCTAssertEqual(sentTo, [claude])
        panel.showSending()
        XCTAssertEqual(panel.sendButton?.isEnabled, false)
        var cancels = 0
        panel.onCancelSending = { cancels += 1 }
        panel.cancelButton?.performClick(nil)
        XCTAssertEqual(cancels, 1, "Cancel stops the paste")
        XCTAssertTrue(panel.isShown)
        panel.showError("Nirux couldn’t paste the message: the terminal closed.")
        XCTAssertEqual(panel.sendButton?.isEnabled, true)

        // Read again: another order, other labels; the error stays.
        panel.update(NiruxShellView.reviewSendContent(
            send(ids: ["c1"]), columns: [column("api — claude, now working", id: UUID()), column("api — claude", id: claude)], queued: false
        ))
        XCTAssertEqual(panel.selectedID, claude)
        XCTAssertEqual(panel.selectedTarget, 1)
        XCTAssertEqual(panel.statusLabel?.stringValue, "Nirux couldn’t paste the message: the terminal closed.")
        // Nothing to copy without a comment.
        panel.update(NiruxShellView.reviewSendContent(send(ids: [], leftOut: 1), columns: [column("api — claude", id: claude)], queued: false))
        XCTAssertEqual(panel.copyButton?.isEnabled, false)
        // Picked by the user, gone: none is picked, Send waits, the menu
        // offers another.
        panel.update(NiruxShellView.reviewSendContent(send(ids: ["c1"]), columns: [column("api — other")], queued: false))
        XCTAssertNil(panel.selectedTarget)
        XCTAssertEqual(panel.sendButton?.isEnabled, false)
        XCTAssertEqual(panel.targetPopUp?.isEnabled, true)
        XCTAssertEqual(panel.lines.first, "The column picked closed, or no longer runs an agent: pick another.")
    }

    /// Picked by the sheet: when it goes, or none was there, the first that
    /// takes the comments is.
    @MainActor
    func testSheetPicksAgainWhatItPicked() {
        let panel = ReviewSendPanel(content: NiruxShellView.reviewSendContent(send(ids: ["c1"]), columns: [], queued: false))
        XCTAssertNil(panel.selectedTarget)
        let claude = UUID()
        panel.update(NiruxShellView.reviewSendContent(send(ids: ["c1"]), columns: [column("api — claude", id: claude)], queued: false))
        XCTAssertEqual(panel.selectedID, claude)
        let other = UUID()
        panel.update(NiruxShellView.reviewSendContent(
            send(ids: ["c1"]), columns: [column("api — codex", refusal: .notClaude("Codex")), column("api — other", id: other)], queued: false
        ))
        XCTAssertEqual(panel.selectedID, other)
        panel.show(attachedTo: nil)
        defer { panel.dismiss() }
        panel.update(NiruxShellView.reviewSendContent(send(ids: ["c1", "c2"]), columns: [column("api — other", id: other)], queued: false))
        XCTAssertEqual(panel.titleLabel?.stringValue, "Send 2 Comments to Agent", "the title follows")
    }
}

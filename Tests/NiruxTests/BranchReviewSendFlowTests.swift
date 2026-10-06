import XCTest
@testable import Nirux

/// "Send N Comments to Agent" through the shell (docs/branch-review.md,
/// section 6.2): the agent columns of the reviewed worktree, the paste, and
/// the comments sent once Claude takes the prompt.
final class BranchReviewSendFlowTests: XCTestCase {
    /// Only the Claude running in the reviewed worktree is offered: not
    /// one in the main checkout, nor one in a worktree nested in the
    /// reviewed one. The message goes into its prompt, the column comes to
    /// the front, and the comment is sent once its next prompt goes in.
    @MainActor
    func testCommentsGoToTheWorktreesClaudeAndAreSentOnceItTakesThem() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let nested = harness.worktree + "/.claude/worktrees/nested"
            try UIFlowHarness.git(["worktree", "add", "-q", "-b", "nested", nested], at: harness.repo)
            shell.addWorkspace(title: "flow", cwd: harness.worktree)
            let workspace = try XCTUnwrap(shell.activeWorkspace)
            let review = shell.makeBranchReview(worktree: harness.worktree, branch: nil)
            workspace.addBranchReviewColumn(review)
            review.start()
            harness.waitUntil("the review open") { review.review?.canWrite == true }

            // The workspace's own shell runs there too: not an agent, even
            // once hooks named one.
            let shellColumn = try XCTUnwrap(workspace.columns.first?.pty)
            for cwd in [harness.worktree, harness.repo, nested] {
                workspace.addColumn(command: "exec -a claude /bin/cat", cwd: cwd)
            }
            // An agent under a launcher in front, and one in the background
            // of its shell.
            workspace.addColumn(command: "exec /usr/bin/time /bin/zsh -f -c 'exec -a claude /bin/cat'", cwd: harness.worktree)
            let launched = try XCTUnwrap(workspace.columns.last?.pty)
            workspace.addColumn(command: "exec /bin/zsh -f -i -c '(exec -a claude /bin/sleep 600) & wait'", cwd: harness.worktree)
            let background = try XCTUnwrap(workspace.columns.last?.pty)
            let claudes = workspace.columns.suffix(5).prefix(3).compactMap(\.pty)
            XCTAssertEqual(claudes.count, 3)
            harness.waitUntil("the launcher's claude, the background one") {
                launched.runningAgentName(snapshot: ProcessSnapshot()) == "claude"
                    && launched.foregroundProcess(snapshot: ProcessSnapshot())?.name == "time"
                    && background.runningAgentName(snapshot: ProcessSnapshot()) == "claude"
                    && background.foregroundProcess(snapshot: ProcessSnapshot())?.name == "zsh"
            }
            for name in [AgentHookEvent.Name.sessionStart, .userPromptSubmit, .stop] {
                _ = shellColumn.applyAgentHook(AgentHookEvent(
                    kind: .claude, name: name, sessionID: "old", timestamp: Date().timeIntervalSince1970
                ), isUserFocused: false)
            }
            harness.waitUntil("three claudes") {
                claudes.allSatisfy { $0.foregroundProcess(snapshot: ProcessSnapshot())?.name == "claude" }
            }
            // Each at its prompt: it took one since it started.
            for pty in claudes {
                let claude = try XCTUnwrap(pty.foregroundProcess(snapshot: ProcessSnapshot())).instance
                for name in [AgentHookEvent.Name.sessionStart, .userPromptSubmit, .stop] {
                    _ = pty.applyAgentHook(AgentHookEvent(
                        kind: .claude, name: name, sessionID: "s", emitterProcess: claude, timestamp: Date().timeIntervalSince1970
                    ), isUserFocused: false)
                }
            }
            let date = Date()
            review.writeReview { $0.addComment(id: "c1", anchor: .file("README.md"), text: "Say why.", at: date) }
            harness.waitUntil("the comment") { review.agentSend()?.message.ids == ["c1"] }

            shell.sendReviewComments(from: review)
            harness.waitUntil("the sheet") { shell.reviewSendPanel != nil }
            let panel = try XCTUnwrap(shell.reviewSendPanel)
            XCTAssertEqual(panel.content.targets.count, 3, "\(panel.content.targets.map(\.label))")
            XCTAssertEqual(panel.content.targets.map(\.refusal), [
                nil, ReviewSendRefusal.underLauncher("time").message, ReviewSendRefusal.notInFront.message
            ])
            XCTAssertEqual(panel.selectedTarget, 0)
            XCTAssertEqual(panel.content.title, "Send 1 Comment to Agent")
            // A turn started since the sheet showed: Send says so, and waits.
            let claude = try XCTUnwrap(claudes[0].foregroundProcess(snapshot: ProcessSnapshot())).instance
            func hook(_ name: AgentHookEvent.Name, holding header: String? = nil) {
                _ = claudes[0].applyAgentHook(AgentHookEvent(
                    kind: .claude, name: name, sessionID: "s", emitterProcess: claude, reviewHeader: header,
                    timestamp: Date().timeIntervalSince1970
                ), isUserFocused: false)
            }
            // Edited since the sheet showed it: shown again, not sent.
            let edited = Date()
            review.writeReview { _ = $0.editComment(id: "c1", text: "Say why, please.", at: edited) }
            harness.waitUntil("the edit") { review.agentSend()?.texts["c1"] == "Say why, please." }
            panel.sendButton?.performClick(nil)
            XCTAssertEqual(panel.statusLabel?.stringValue, "The comments changed meanwhile: read the message again, then Send.")
            XCTAssertTrue(panel.messageView?.string.contains("Say why, please.") == true)
            hook(.userPromptSubmit)
            panel.sendButton?.performClick(nil)
            XCTAssertEqual(panel.statusLabel?.stringValue, ReviewSendRefusal.working.message)
            XCTAssertNotNil(shell.reviewSendPanel)
            XCTAssertEqual(panel.sendButton?.isEnabled, false)
            // Its turn over, the next refresh lets Send through.
            hook(.stop)
            harness.waitUntil("Send") {
                shell.refreshMetadata()
                return panel.sendButton?.isEnabled == true
            }
            panel.sendButton?.performClick(nil)

            harness.waitUntil("the paste") { shell.reviewSendPanel == nil && claudes[0].recentOutput().contains("Say why, please.") }
            XCTAssertFalse(claudes[1].recentOutput().contains("Say why"))
            XCTAssertFalse(claudes[2].recentOutput().contains("Say why"))
            XCTAssertTrue(workspace.columns[workspace.focusedIndex].pty === claudes[0], "the user reads it there")
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertNil(review.review?.record.comment(id: "c1")?.sent, "not before Claude takes it")
            XCTAssertNil(review.agentSend()?.message.ids.first, "in its prompt: it doesn't go again")
            hook(.userPromptSubmit, holding: "Review comments on \(BranchReview.visible(review.snapshot?.branch ?? "")) (head \(review.snapshot?.head.prefix(7) ?? "")), from Nirux:")
            harness.waitUntil("sent") { review.review?.record.comment(id: "c1")?.sent != nil }
            XCTAssertEqual(review.review?.record.comment(id: "c1")?.sent?.head, review.snapshot?.head)
        }
    }
}

import AppKit
import XCTest
@testable import Nirux

final class TelegramRemoteAccessTests: XCTestCase {
    @MainActor
    func testControllerConversationAuthorizesRoutesAndPersistsUpdates() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-telegram-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            restoreEnvironment("NIRUX_STATE_DIR", previousValue: previousStateDirectory)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        state.settings = PersistedSettings(
            telegramRemoteAccessEnabled: true,
            telegramPairedUserID: 123,
            telegramPairedChatID: 123
        )
        XCTAssertTrue(Persistence.save(state))

        let sessions = [
            makeSession(id: "agent-a", workspace: "Checkout", column: 0, status: .working),
            makeSession(
                id: "agent-b",
                workspace: "Payments",
                column: 1,
                status: .needsAttention,
                output: "Compiling PaymentService.swift\nWaiting for approval"
            )
        ]
        var injectedPrompts: [(agentID: String, terminalInput: String)] = []
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TelegramURLProtocolStub.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        defer { urlSession.invalidateAndCancel() }
        let controller = TelegramRemoteAccessController(
            sessions: { sessions },
            sendPrompt: { agentID, prompt in
                guard let session = sessions.first(where: { $0.id == agentID }) else {
                    return .sessionUnavailable
                }
                guard let terminalInput = RemotePromptSanitizer.terminalInput(for: prompt) else {
                    return .emptyPrompt
                }
                injectedPrompts.append((agentID, terminalInput))
                return .sent(session)
            },
            tokenLoader: { "123456789:abcdefghijklmnopqrstuvwxyz_ABC-123" },
            urlSession: urlSession
        )
        defer { controller.shutdown() }

        TelegramURLProtocolStub.api.reset()

        controller.reloadFromPersistence()
        let completed = try await waitUntil {
            TelegramURLProtocolStub.api.sentMessages.count == 7
                && Persistence.load()?.settings?.telegramLastUpdateID == 9
        }

        let api = TelegramURLProtocolStub.api.snapshot()
        guard completed, api.sentMessages.count == 7 else {
            XCTFail(
                "Telegram transcript incomplete: methods=\(api.requestedMethods.sorted()), "
                    + "messages=\(api.sentMessages.count), offsets=\(api.getUpdatesOffsets)"
            )
            return
        }
        assertConversation(api: api, injectedPrompts: injectedPrompts)

        try writeTelegramConversationEvidence(
            api: api,
            injectedPrompts: injectedPrompts
        )
    }

    @MainActor
    func testSettingsRenderRemoteAccessDisabledByDefault() throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-telegram-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            restoreEnvironment("NIRUX_STATE_DIR", previousValue: previousStateDirectory)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        _ = NSApplication.shared
        let app = NiruxApp()
        let controller = TelegramRemoteAccessController(
            sessions: { [] },
            sendPrompt: { _, _ in .sessionUnavailable },
            tokenLoader: { nil }
        )
        app.telegramRemoteAccessController = controller
        controller.reloadFromPersistence()
        app.showSettings(nil)
        defer {
            app.settingsPanel?.orderOut(nil)
            app.settingsPanel?.close()
            controller.shutdown()
        }

        XCTAssertEqual(app.settingsTelegramEnabledCheckbox?.state, .off)
        XCTAssertEqual(app.settingsTelegramCompletionCheckbox?.state, .on)
        XCTAssertEqual(app.settingsTelegramAttentionCheckbox?.state, .on)
        XCTAssertEqual(app.settingsTelegramStatusLabel?.stringValue, "Remote Access is off.")
        XCTAssertEqual(app.settingsTelegramPairButton?.isEnabled, false)
        XCTAssertNotNil(app.settingsTelegramTokenField)

        try writeSettingsEvidence(panel: try XCTUnwrap(app.settingsPanel))
    }

    @MainActor
    func testPairingRequiresPrivateChatAndPersistsPairedIdentity() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-telegram-pairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            restoreEnvironment("NIRUX_STATE_DIR", previousValue: previousStateDirectory)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        state.settings = PersistedSettings(telegramRemoteAccessEnabled: true)
        XCTAssertTrue(Persistence.save(state))

        TelegramURLProtocolStub.api.reset(updateBatch: [])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TelegramURLProtocolStub.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        defer { urlSession.invalidateAndCancel() }
        let controller = TelegramRemoteAccessController(
            sessions: { [] },
            sendPrompt: { _, _ in .sessionUnavailable },
            tokenLoader: { "123456789:abcdefghijklmnopqrstuvwxyz_ABC-123" },
            urlSession: urlSession
        )
        defer { controller.shutdown() }

        controller.reloadFromPersistence()
        let code = try XCTUnwrap(controller.beginPairing())
        XCTAssertEqual(code.count, 8)
        TelegramURLProtocolStub.api.queue(updateBatch: [
            TelegramAPIStub.messageUpdate(
                id: 1,
                messageID: 1,
                userID: 321,
                chatID: -100,
                chatType: "group",
                text: "/pair \(code)"
            ),
            TelegramAPIStub.messageUpdate(
                id: 2,
                messageID: 2,
                userID: 321,
                chatID: 321,
                text: "/pair \(code)"
            )
        ])

        let paired = try await waitUntil {
            controller.displayState.pairedUserID == 321
                && Persistence.load()?.settings?.telegramLastUpdateID == 2
        }
        XCTAssertTrue(paired)
        let settings = try XCTUnwrap(Persistence.load()?.settings)
        XCTAssertEqual(settings.telegramPairedUserID, 321)
        XCTAssertEqual(settings.telegramPairedChatID, 321)
        XCTAssertEqual(TelegramURLProtocolStub.api.sentMessages.map(\.text), [
            "Paired with Nirux. Use /sessions to choose a live agent, then send a prompt or reply to a notification."
        ])
    }

    @MainActor
    func testUpdatePersistenceFailureFailsClosedBeforePrompt() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-telegram-persistence-\(UUID().uuidString)")
        let invalidDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-telegram-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: invalidDirectory)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            restoreEnvironment("NIRUX_STATE_DIR", previousValue: previousStateDirectory)
            try? FileManager.default.removeItem(at: stateDirectory)
            try? FileManager.default.removeItem(at: invalidDirectory)
        }

        var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        state.settings = PersistedSettings(
            telegramRemoteAccessEnabled: true,
            telegramPairedUserID: 123,
            telegramPairedChatID: 123
        )
        XCTAssertTrue(Persistence.save(state))

        TelegramURLProtocolStub.api.reset(updateBatch: [
            TelegramAPIStub.messageUpdate(
                id: 1,
                messageID: 1,
                userID: 123,
                chatID: 123,
                text: "must not be delivered"
            )
        ])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TelegramURLProtocolStub.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        defer { urlSession.invalidateAndCancel() }
        var promptCount = 0
        let session = Self.makeStaticSession()
        let controller = TelegramRemoteAccessController(
            sessions: { [session] },
            sendPrompt: { _, _ in
                promptCount += 1
                return .sent(session)
            },
            tokenLoader: { "123456789:abcdefghijklmnopqrstuvwxyz_ABC-123" },
            urlSession: urlSession
        )
        defer { controller.shutdown() }

        controller.reloadFromPersistence()
        setenv("NIRUX_STATE_DIR", invalidDirectory.path, 1)
        let failedClosed = try await waitUntil {
            controller.displayState.lastError?.contains("Unable to save Telegram update state") == true
        }
        controller.shutdown()
        XCTAssertTrue(failedClosed)
        XCTAssertEqual(promptCount, 0)
        XCTAssertTrue(TelegramURLProtocolStub.api.sentMessages.isEmpty)

        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        XCTAssertNil(Persistence.load()?.settings?.telegramLastUpdateID)
    }

    @MainActor
    func testDisablingRemoteAccessMidBatchStopsTheNextPrompt() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-telegram-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            restoreEnvironment("NIRUX_STATE_DIR", previousValue: previousStateDirectory)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        var state = PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        state.settings = PersistedSettings(
            telegramRemoteAccessEnabled: true,
            telegramPairedUserID: 123,
            telegramPairedChatID: 123
        )
        XCTAssertTrue(Persistence.save(state))

        TelegramURLProtocolStub.api.reset(
            updateBatch: [
                TelegramAPIStub.messageUpdate(
                    id: 1,
                    messageID: 1,
                    userID: 123,
                    chatID: 123,
                    text: "/status"
                ),
                TelegramAPIStub.messageUpdate(
                    id: 2,
                    messageID: 2,
                    userID: 123,
                    chatID: 123,
                    text: "must not run after disable"
                )
            ],
            sendMessageDelay: 1
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TelegramURLProtocolStub.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        defer { urlSession.invalidateAndCancel() }
        var promptCount = 0
        let session = Self.makeStaticSession()
        let controller = TelegramRemoteAccessController(
            sessions: { [session] },
            sendPrompt: { _, _ in
                promptCount += 1
                return .sent(session)
            },
            tokenLoader: { "123456789:abcdefghijklmnopqrstuvwxyz_ABC-123" },
            urlSession: urlSession
        )
        defer { controller.shutdown() }

        controller.reloadFromPersistence()
        let firstReplyStarted = try await waitUntil {
            TelegramURLProtocolStub.api.sendMessageStartedCount == 1
        }
        XCTAssertTrue(firstReplyStarted)

        var disabledState = try XCTUnwrap(Persistence.load())
        disabledState.settings?.telegramRemoteAccessEnabled = false
        XCTAssertTrue(Persistence.save(disabledState))
        controller.reloadFromPersistence()
        try await Task.sleep(for: .milliseconds(1_100))

        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(Persistence.load()?.settings?.telegramLastUpdateID, 1)
        XCTAssertFalse(controller.displayState.enabled)
    }

    @MainActor
    func testPtyRemotePromptGateRechecksLiveForegroundProcess() async throws {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-telegram-pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let previousStateDirectory = ProcessInfo.processInfo.environment["NIRUX_STATE_DIR"]
        setenv("NIRUX_STATE_DIR", stateDirectory.path, 1)
        defer {
            restoreEnvironment("NIRUX_STATE_DIR", previousValue: previousStateDirectory)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        let agentSession = PtySession()
        let idleShellSession = PtySession()
        agentSession.start(
            shell: "/bin/zsh",
            args: ["-f", "-c", "exec -a codex /bin/cat"],
            cwd: stateDirectory.path
        )
        idleShellSession.start(shell: "/bin/zsh", args: ["-f"], cwd: stateDirectory.path)

        let processesReady = try await waitUntil {
            let snapshot = ProcessSnapshot()
            return agentSession.acceptsRemotePrompts(snapshot: snapshot)
                && !idleShellSession.acceptsRemotePrompts(snapshot: snapshot)
        }
        XCTAssertTrue(processesReady)

        let terminalInput = try XCTUnwrap(RemotePromptSanitizer.terminalInput(for: "remote prompt verified"))
        agentSession.sendRaw(terminalInput)
        let delivered = try await waitUntil {
            agentSession.recentOutput().contains("remote prompt verified")
        }
        XCTAssertTrue(delivered)
    }

    func testPairingStatusIncludesPollingError() {
        let state = TelegramRemoteAccessDisplayState(
            enabled: true,
            polling: true,
            hasToken: true,
            pairedUserID: nil,
            pairingCode: "12345678",
            pairingExpiresAt: Date().addingTimeInterval(600),
            lastError: "Telegram rejected the token."
        )

        XCTAssertTrue(state.statusText.contains("Send /pair 12345678"))
        XCTAssertTrue(state.statusText.contains("Telegram rejected the token."))
    }

    func testExplicitReplyRequiresRememberedRoute() {
        XCTAssertEqual(
            TelegramPromptRoute.resolve(replyToMessageID: nil, routes: [:]),
            .currentSelection
        )
        XCTAssertEqual(
            TelegramPromptRoute.resolve(replyToMessageID: 7, routes: [7: "agent-a"]),
            .explicit("agent-a")
        )
        XCTAssertEqual(
            TelegramPromptRoute.resolve(replyToMessageID: 6, routes: [7: "agent-a"]),
            .unavailableReply
        )
    }

    func testBotTokenValidation() {
        XCTAssertTrue(TelegramBotToken.isPlausible("123456789:abcdefghijklmnopqrstuvwxyz_ABC-123"))
        XCTAssertFalse(TelegramBotToken.isPlausible("not-a-token"))
        XCTAssertFalse(TelegramBotToken.isPlausible("123:not short"))
        XCTAssertFalse(TelegramBotToken.isPlausible("１２３:abcdefghijklmnopqrstuvwxyz_ABC-123"))
    }

    func testCommandParserHandlesAddressedCommandsAndRejectsExecAsUnknown() {
        XCTAssertEqual(TelegramCommand.parse("/sessions@nirux_bot"), .sessions)
        XCTAssertEqual(TelegramCommand.parse(" /pair 12345678 \n"), .pair("12345678"))
        XCTAssertEqual(TelegramCommand.parse("/exec rm -rf something"), .unknown("exec"))
        XCTAssertNil(TelegramCommand.parse("ordinary prompt"))
    }

    func testPromptSanitizerDropsTerminalControlBytesAndFramesPaste() {
        let input = "  explain\u{1B}[31m this\u{0}\r\ncarefully  "
        XCTAssertEqual(RemotePromptSanitizer.sanitize(input), "explain[31m this\ncarefully")
        let framed = RemotePromptSanitizer.terminalInput(for: input)
        XCTAssertEqual(framed, "\u{1B}[200~explain[31m this\ncarefully\u{1B}[201~\r")
        XCTAssertNil(RemotePromptSanitizer.terminalInput(for: "\u{1B}\u{0}"))
    }

    func testTerminalPlainTextStripsCSIAndOSCSequences() {
        let raw = Data("\u{1B}[31mred\u{1B}[0m\r\nnext\u{1B}]0;secret title\u{07}\nvisible".utf8)
        let rendered = TerminalPlainText.render(raw)
        XCTAssertEqual(rendered, "red\nnext\nvisible")
        XCTAssertFalse(rendered.contains("secret title"))
    }

    func testTerminalOutputBufferKeepsRequestedLineTail() {
        let buffer = TerminalOutputBuffer(maxBytes: 1_024)
        buffer.append(Data("one\ntwo\nthree".utf8))
        XCTAssertEqual(buffer.tail(maxLines: 2), "two\nthree")
    }

    func testTelegramMessageUpdateDecodesReplyRoute() throws {
        let data = Data("""
        {
          "update_id": 42,
          "message": {
            "message_id": 9,
            "from": {"id": 123, "username": "alice"},
            "chat": {"id": 123, "type": "private"},
            "text": "continue",
            "reply_to_message": {"message_id": 7}
          }
        }
        """.utf8)
        let update = try JSONDecoder().decode(TelegramUpdate.self, from: data)
        XCTAssertEqual(update.updateID, 42)
        XCTAssertEqual(update.message?.from?.id, 123)
        XCTAssertEqual(update.message?.replyToMessage?.messageID, 7)
    }

    func testTelegramCallbackUpdateDecodesSelection() throws {
        let data = Data("""
        {
          "update_id": 43,
          "callback_query": {
            "id": "callback-id",
            "from": {"id": 123},
            "message": {
              "message_id": 10,
              "chat": {"id": 123, "type": "private"}
            },
            "data": "session:agent-uuid"
          }
        }
        """.utf8)
        let update = try JSONDecoder().decode(TelegramUpdate.self, from: data)
        XCTAssertEqual(update.callbackQuery?.id, "callback-id")
        XCTAssertEqual(update.callbackQuery?.message?.chat.id, 123)
        XCTAssertEqual(update.callbackQuery?.data, "session:agent-uuid")
    }

    func testRecognizedAgentCapabilityGate() {
        XCTAssertTrue(AgentStatusMachine.isRecognizedAgentProcess("claude"))
        XCTAssertTrue(AgentStatusMachine.isRecognizedAgentProcess("codex"))
        XCTAssertFalse(AgentStatusMachine.isRecognizedAgentProcess("zsh"))
        XCTAssertFalse(AgentStatusMachine.isRecognizedAgentProcess("vim"))
    }

}

private extension TelegramRemoteAccessTests {
    func assertConversation(
        api: TelegramAPIStub.Snapshot,
        injectedPrompts: [(agentID: String, terminalInput: String)]
    ) {
        XCTAssertGreaterThanOrEqual(api.getUpdatesOffsets.count, 1)
        XCTAssertEqual(api.getUpdatesOffsets.first!, nil)
        XCTAssertEqual(Persistence.load()?.settings?.telegramLastUpdateID, 9)
        XCTAssertEqual(injectedPrompts.count, 1)
        XCTAssertEqual(injectedPrompts.first?.agentID, "agent-b")
        XCTAssertEqual(
            injectedPrompts.first?.terminalInput,
            "\u{1B}[200~explain[31m this safely\u{1B}[201~\r"
        )
        XCTAssertTrue(api.sentMessages[0].text.contains("Live agent sessions"))
        XCTAssertTrue(api.sentMessages[0].text.contains("Checkout · col 1 · working"))
        XCTAssertTrue(api.sentMessages[0].text.contains("Payments · col 2 · needs attention"))
        XCTAssertEqual(api.sentMessages[0].callbackData, ["session:agent-a", "session:agent-b"])
        XCTAssertTrue(api.sentMessages[1].text.contains("Workspace: Payments"))
        XCTAssertTrue(api.sentMessages[3].text.contains("Waiting for approval"))
        XCTAssertEqual(api.sentMessages[4].text, "Prompt sent to Payments · column 2.")
        XCTAssertTrue(api.sentMessages[5].text.contains("Unknown command /exec"))
        XCTAssertTrue(api.sentMessages[6].text.contains("reply target is no longer available"))
        XCTAssertEqual(api.callbackAnswers, 2)
        XCTAssertFalse(api.requestedMethods.contains("setWebhook"))
    }

    private func makeSession(
        id: String,
        workspace: String,
        column: Int,
        status: AgentStatus,
        output: String = ""
    ) -> RemoteAgentSession {
        RemoteAgentSession(
            id: id,
            workspaceID: "workspace-\(id)",
            workspaceTitle: workspace,
            columnIndex: column,
            displayName: id,
            cwd: "/tmp/\(workspace.lowercased())",
            status: status,
            recentOutput: output
        )
    }

    private static func makeStaticSession() -> RemoteAgentSession {
        RemoteAgentSession(
            id: "agent-a",
            workspaceID: "workspace-agent-a",
            workspaceTitle: "Checkout",
            columnIndex: 0,
            displayName: "agent-a",
            cwd: "/tmp/checkout",
            status: .working,
            recentOutput: ""
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping () -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func restoreEnvironment(_ name: String, previousValue: String?) {
        if let previousValue {
            setenv(name, previousValue, 1)
        } else {
            unsetenv(name)
        }
    }

    private func writeTelegramConversationEvidence(
        api: TelegramAPIStub.Snapshot,
        injectedPrompts: [(agentID: String, terminalInput: String)]
    ) throws {
        guard let directory = ProcessInfo.processInfo.environment["NIRUX_TELEGRAM_EVIDENCE_DIR"] else {
            return
        }
        let escapedMessages = api.sentMessages.map { message in
            "<div class=\"bubble bot\"><strong>Nirux bot</strong><pre>\(htmlEscape(message.text))</pre></div>"
        }
        let escapedInput = htmlEscape(
            (injectedPrompts.first?.terminalInput
                .replacingOccurrences(of: "\u{1B}", with: "ESC") ?? "none")
                .replacingOccurrences(of: "\r", with: "\\r")
        )
        // Embedded HTML is an intentional generated evidence artifact.
        // swiftlint:disable line_length
        let html = """
        <!doctype html>
        <meta charset="utf-8">
        <title>Nirux Telegram Remote Access — executable test transcript</title>
        <style>
          body { margin: 0; background: #0e1621; color: #eef4f8; font: 15px -apple-system, sans-serif; }
          main { width: 760px; margin: 32px auto; padding: 28px; background: #17212b; border-radius: 16px; }
          h1 { font-size: 23px; margin-top: 0; } h2 { font-size: 16px; color: #9cc9ed; }
          .bubble { max-width: 78%; margin: 12px 0; padding: 12px 15px; border-radius: 14px; }
          .user { margin-left: auto; background: #2b5278; } .bot { background: #1f2c38; }
          .blocked { background: #49252c; border: 1px solid #b95a68; }
          pre { white-space: pre-wrap; margin: 6px 0 0; font: inherit; }
          code { color: #9fe3ad; } .proof { color: #b8c7d1; line-height: 1.5; }
          .summary { background: #173b31; border: 1px solid #398a70; padding: 12px; border-radius: 10px; }
        </style>
        <main>
          <h1>Nirux Telegram Remote Access</h1>
          <p class="proof">Executable controller test with a mocked Telegram Bot API. The persisted account is paired to private user/chat <code>123</code>.</p>
          <p class="proof summary"><strong>Observed:</strong> unpaired traffic ignored · stable <code>agent-b</code> routing · sanitized bracketed-paste prompt · <code>/exec</code> refused · update 9 persisted · outbound <code>getUpdates</code> with no webhook.</p>
          <div class="bubble blocked"><strong>Unpaired user 999</strong><pre>steal secrets</pre><small>Ignored: no bot response and no prompt injection.</small></div>
          <div class="bubble user"><strong>Paired user</strong><pre>/sessions</pre></div>
          \(escapedMessages[0])
          <div class="bubble user"><strong>Paired user</strong><pre>Selects Payments · col 2</pre></div>
          \(escapedMessages[1])
          <div class="bubble user"><strong>Paired user</strong><pre>/status</pre></div>
          \(escapedMessages[2])
          <div class="bubble user"><strong>Paired user</strong><pre>/tail</pre></div>
          \(escapedMessages[3])
          <div class="bubble user"><strong>Paired user</strong><pre>explain ESC[31m this safely</pre></div>
          \(escapedMessages[4])
          <div class="bubble user"><strong>Paired user</strong><pre>/exec whoami</pre></div>
          \(escapedMessages[5])
          <div class="bubble user"><strong>Paired user</strong><pre>Replies to an expired notification</pre></div>
          \(escapedMessages[6])
          <h2>Observed safety boundary</h2>
          <p class="proof">Exactly one prompt reached the selected stable route <code>agent-b</code>. Terminal input was sanitized and bracketed-paste framed as <code>\(escapedInput)</code>. Update 9 was durably checkpointed before completion. API methods observed: <code>\(htmlEscape(api.requestedMethods.sorted().joined(separator: ", ")))</code>; no webhook was configured.</p>
        </main>
        """
        // swiftlint:enable line_length
        let output = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("telegram-remote-access-conversation.html")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(html.utf8).write(to: output, options: .atomic)
    }

    @MainActor
    private func writeSettingsEvidence(panel: NSPanel) throws {
        guard let directory = ProcessInfo.processInfo.environment["NIRUX_TELEGRAM_EVIDENCE_DIR"],
              let view = panel.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("telegram-remote-access-settings.png")
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: output, options: .atomic)
    }

    private func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

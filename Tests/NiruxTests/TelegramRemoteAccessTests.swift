import XCTest
@testable import Nirux

final class TelegramRemoteAccessTests: XCTestCase {
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

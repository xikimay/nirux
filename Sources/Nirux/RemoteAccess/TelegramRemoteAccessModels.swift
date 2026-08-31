import Foundation

struct RemoteAgentSession: Equatable, Sendable {
    let id: String
    let workspaceID: String
    let workspaceTitle: String
    let columnIndex: Int
    let displayName: String
    let cwd: String
    let status: AgentStatus
    let recentOutput: String

    var statusLabel: String {
        switch status {
        case .idle: return "idle"
        case .working: return "working"
        case .needsAttention: return "needs attention"
        }
    }
}

enum RemotePromptResult: Equatable, Sendable {
    case sent(RemoteAgentSession)
    case sessionUnavailable
    case emptyPrompt
}

enum RemotePromptSanitizer {
    static let maxCharacters = 8_000

    /// Telegram text is untrusted terminal input. Keep ordinary Unicode,
    /// newlines and tabs, but discard control characters (especially ESC)
    /// before wrapping the prompt in terminal bracketed-paste markers.
    static func sanitize(_ text: String) -> String? {
        var result = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars.prefix(maxCharacters) {
            if previousWasCarriageReturn {
                previousWasCarriageReturn = false
                if scalar.value == 0x0A { continue }
            }
            switch scalar.value {
            case 0x09, 0x0A:
                result.append(scalar)
            case 0x0D:
                result.append("\n")
                previousWasCarriageReturn = true
            case 0x20...0x7E, 0xA0...0x10FFFF:
                result.append(scalar)
            default:
                continue
            }
        }
        let sanitized = String(result).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : sanitized
    }

    static func terminalInput(for text: String) -> String? {
        guard let sanitized = sanitize(text) else { return nil }
        return "\u{1B}[200~\(sanitized)\u{1B}[201~\r"
    }
}

/// Bounded, lock-protected PTY output used by Telegram's `/tail` command.
/// The terminal renderer remains the source of truth; this deliberately
/// keeps only a small raw suffix and converts it to safe plain text on read.
final class TerminalOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var wasTruncated = false
    private let maxBytes: Int

    init(maxBytes: Int = 256 * 1_024) {
        self.maxBytes = max(1_024, maxBytes)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        bytes.append(data)
        if bytes.count > maxBytes {
            bytes.removeFirst(bytes.count - maxBytes)
            wasTruncated = true
        }
        lock.unlock()
    }

    func tail(maxLines: Int = 40, maxCharacters: Int = 3_500) -> String {
        lock.lock()
        var snapshot = bytes
        let snapshotWasTruncated = wasTruncated
        lock.unlock()
        if snapshotWasTruncated,
           let boundary = snapshot.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            snapshot = snapshot.suffix(from: snapshot.index(after: boundary))
        }
        return TerminalPlainText.render(snapshot, maxLines: maxLines, maxCharacters: maxCharacters)
    }
}

enum TerminalPlainText {
    private enum ParserState {
        case text
        case escape
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
        case controlString
        case controlStringEscape
    }

    private struct EscapeStripper {
        var output = Data()
        private var state = ParserState.text
        private var previousWasCarriageReturn = false

        mutating func consume(_ byte: UInt8) {
            switch state {
            case .text: consumeText(byte)
            case .escape: consumeEscape(byte)
            case .controlSequence:
                if (0x40...0x7E).contains(byte) { state = .text }
            case .operatingSystemCommand:
                consumeOperatingSystemCommand(byte)
            case .operatingSystemCommandEscape:
                state = byte == 0x5C ? .text : .operatingSystemCommand
            case .controlString:
                if byte == 0x1B { state = .controlStringEscape }
            case .controlStringEscape:
                state = byte == 0x5C ? .text : .controlString
            }
        }

        private mutating func consumeText(_ byte: UInt8) {
            if previousWasCarriageReturn {
                previousWasCarriageReturn = false
                if byte == 0x0A { return }
            }
            switch byte {
            case 0x1B:
                state = .escape
            case 0x0A:
                output.append(byte)
            case 0x0D:
                output.append(0x0A)
                previousWasCarriageReturn = true
            case 0x09:
                output.append(byte)
            case 0x08:
                if output.last != 0x0A { output.removeLastIfPresent() }
            case 0x20...0x7E, 0x80...0xFF:
                output.append(byte)
            default:
                return
            }
        }

        private mutating func consumeEscape(_ byte: UInt8) {
            switch byte {
            case 0x5B: state = .controlSequence        // CSI: ESC [
            case 0x5D: state = .operatingSystemCommand // OSC: ESC ]
            case 0x50, 0x58, 0x5E, 0x5F: state = .controlString
            default: state = .text
            }
        }

        private mutating func consumeOperatingSystemCommand(_ byte: UInt8) {
            if byte == 0x07 {
                state = .text
            } else if byte == 0x1B {
                state = .operatingSystemCommandEscape
            }
        }
    }

    static func render(_ data: Data, maxLines: Int = 40, maxCharacters: Int = 3_500) -> String {
        guard !data.isEmpty, maxLines > 0, maxCharacters > 0 else { return "" }
        var stripper = EscapeStripper()
        for byte in data { stripper.consume(byte) }

        let decoded = String(decoding: stripper.output, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        var lines: [String] = []
        var consecutiveEmpty = 0
        for rawLine in decoded.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                consecutiveEmpty += 1
                if consecutiveEmpty <= 2 { lines.append("") }
            } else {
                consecutiveEmpty = 0
                lines.append(line)
            }
        }

        let lineTail = lines.suffix(maxLines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard lineTail.count > maxCharacters else { return lineTail }
        return "…" + String(lineTail.suffix(maxCharacters - 1))
    }
}

private extension Data {
    mutating func removeLastIfPresent() {
        guard !isEmpty else { return }
        removeLast()
    }
}

enum TelegramBotToken {
    static func isPlausible(_ token: String) -> Bool {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[0].utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              parts[1].count >= 20
        else { return false }
        return parts[1].utf8.allSatisfy {
            (0x30...0x39).contains($0)
                || (0x41...0x5A).contains($0)
                || (0x61...0x7A).contains($0)
                || $0 == 0x5F
                || $0 == 0x2D
        }
    }
}

enum TelegramCommand: Equatable {
    case help
    case sessions
    case status
    case tail
    case pair(String)
    case unknown(String)

    static func parse(_ text: String) -> TelegramCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let pieces = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let addressedCommand = pieces[0].dropFirst()
        let name = addressedCommand.split(separator: "@", maxSplits: 1).first?.lowercased() ?? ""
        let argument = pieces.count > 1
            ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        switch name {
        case "start", "help": return .help
        case "sessions", "list": return .sessions
        case "status": return .status
        case "tail": return .tail
        case "pair": return .pair(argument)
        default: return .unknown(name)
        }
    }
}

// MARK: - Telegram Bot API wire models

struct TelegramUpdate: Decodable, Sendable {
    let updateID: Int64
    let message: TelegramMessage?
    let callbackQuery: TelegramCallbackQuery?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

struct TelegramMessage: Decodable, Sendable {
    let messageID: Int64
    let from: TelegramUser?
    let chat: TelegramChat
    let text: String?
    let replyToMessage: TelegramReplyMessage?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from, chat, text
        case replyToMessage = "reply_to_message"
    }
}

struct TelegramReplyMessage: Decodable, Sendable {
    let messageID: Int64

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

struct TelegramUser: Decodable, Sendable {
    let id: Int64
    let username: String?
}

struct TelegramChat: Decodable, Sendable {
    let id: Int64
    let type: String
}

struct TelegramCallbackQuery: Decodable, Sendable {
    let id: String
    let from: TelegramUser
    let message: TelegramCallbackMessage?
    let data: String?
}

struct TelegramCallbackMessage: Decodable, Sendable {
    let messageID: Int64
    let chat: TelegramChat

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case chat
    }
}

struct TelegramInlineKeyboard: Encodable, Sendable {
    let inlineKeyboard: [[TelegramInlineKeyboardButton]]

    enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
}

struct TelegramInlineKeyboardButton: Encodable, Sendable {
    let text: String
    let callbackData: String

    enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

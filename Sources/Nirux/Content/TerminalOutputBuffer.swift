import Foundation

/// Bounded, lock-protected copy of a PTY's latest output
/// (`PtySession.recentOutput`). The terminal renderer remains the source of
/// truth; this deliberately keeps only a small raw suffix and converts it
/// to safe plain text on read.
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

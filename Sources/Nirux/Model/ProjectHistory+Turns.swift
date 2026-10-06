import Foundation

extension ProjectHistory {
    /// A complete turn read from a transcript: the messages that started it
    /// and its final reply, and where it ends in the file.
    struct Turn: Equatable, Sendable {
        let messages: [NewMessage]
        /// Byte offset just past the turn's last line.
        let end: UInt64
    }

    /// Reads the complete turns of a Claude transcript from an offset.
    ///
    /// A turn is the messages that started it (`user`, `peer`) and its
    /// final reply (`talk`): the text parts after its last tool call. It
    /// ends where the next one starts, a message or a line that starts a
    /// turn (a subagent's report, a task notification) coming after a reply.
    /// A message that comes during the tool loop (a prompt queued while
    /// Claude worked, a message from another session, a prompt typed after
    /// Esc) belongs to the turn underway. Claude Code marks the end of each
    /// turn (`turn_duration`, `stop_hook_summary`); a turn not marked yet is
    /// complete only when the caller knows it ended (`lastTurnEnded`: the
    /// session ended, or an import of a session that no longer runs), and
    /// then has a reply only if its last answer was final, the one whose
    /// `stop_reason` isn't `tool_use`.
    enum TurnReader {
        struct Result: Equatable, Sendable {
            var turns: [Turn]
            /// Where the next read starts: the start of the turn still
            /// open, or the end of the last complete line.
            var resumeOffset: UInt64
            /// A line was longer than `maxLineBytes` and skipped.
            var skippedLongLine: Bool
        }

        /// A prompt can carry a pasted file; a line past this is a tool's.
        static let maxLineBytes = TranscriptSearch.maxLineBytes
        static let chunkSize = 1024 * 1024

        /// Nil when the file can't be read (gone, not a regular file, a
        /// symbolic link) or is shorter than `offset`.
        /// - Parameters:
        ///   - lastTurnEnded: the turn underway at the end of the file is
        ///     over.
        ///   - endedWithError: that last turn ended on an API error: its
        ///     messages are kept, without a reply.
        static func read(
            path: String, from offset: UInt64, lastTurnEnded: Bool, endedWithError: Bool = false, session: String? = nil,
            maxLineBytes: Int = maxLineBytes, chunkSize: Int = chunkSize
        ) -> Result? {
            let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  UInt64(info.st_size) >= offset else { return nil }

            var assembler = Assembler(start: offset, session: session)
            var lines = LineSplitter(start: offset, maxLineBytes: maxLineBytes)
            var position = offset
            var chunk = Data(count: max(1, chunkSize))
            while true {
                let count = chunk.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress, $0.count, off_t(position))
                }
                if count < 0, errno == EINTR { continue }
                // A read error mid-file must not look like its end.
                guard count >= 0 else { return nil }
                guard count > 0 else { break }
                position += UInt64(count)
                lines.consume(chunk.prefix(count)) { line, start, end in
                    assembler.line(line, start: start, end: end)
                }
            }
            // A last line without its newline may still be written.
            return assembler.finish(
                lastTurnEnded: lastTurnEnded, endedWithError: endedWithError, skippedLongLine: lines.skippedLongLine
            )
        }
    }

    /// Splits bytes into complete lines, with their offsets.
    private struct LineSplitter {
        private(set) var skippedLongLine = false
        private var partial = Data()
        private var partialStart: UInt64
        private var isSkipping = false
        let maxLineBytes: Int

        init(start: UInt64, maxLineBytes: Int) {
            partialStart = start
            self.maxLineBytes = maxLineBytes
        }

        mutating func consume(_ bytes: Data, _ emit: (Data, UInt64, UInt64) -> Void) {
            var index = bytes.startIndex
            while index < bytes.endIndex {
                guard let newline = bytes[index...].firstIndex(of: 0x0A) else {
                    append(bytes[index...])
                    return
                }
                append(bytes[index..<newline])
                let end = partialStart + UInt64(partial.count) + 1
                if isSkipping {
                    skippedLongLine = true
                    emit(Data(), partialStart, end)
                } else {
                    emit(partial, partialStart, end)
                }
                partial = Data()
                isSkipping = false
                partialStart = end
                index = bytes.index(after: newline)
            }
        }

        /// A line longer than the limit is counted, not kept.
        private mutating func append(_ bytes: Data) {
            if isSkipping {
                partialStart += UInt64(bytes.count)
                return
            }
            if partial.count + bytes.count > maxLineBytes {
                partialStart += UInt64(partial.count + bytes.count)
                partial = Data()
                isSkipping = true
            } else {
                partial.append(bytes)
            }
        }
    }

    /// Turns lines into turns.
    private struct Assembler {
        private var turns: [Turn] = []
        private var messages: [NewMessage] = []
        /// Assistant text since the last tool call: the reply, if the turn
        /// ends here.
        private var reply: [String] = []
        private var replyDate: Date?
        private var replyUUID: String?
        /// The turn's last answer was an API error.
        private var failed = false
        /// Whether the turn's last answer was final: its `stop_reason`
        /// isn't `tool_use` (a line without one: it holds no tool call).
        /// Nil before any answer.
        private var lastAnswerIsFinal: Bool?
        /// Where the turn underway started; nil between turns.
        private var openTurnStart: UInt64?
        private var lastLineEnd: UInt64
        private var branch: String?
        private var session: String?
        /// The last date a line gave, for a line without one.
        private var lastDate = Date.distantPast

        /// The session the file is: a line of another is skipped.
        private let expectedSession: String?

        init(start: UInt64, session: String?) {
            lastLineEnd = start
            expectedSession = session
        }

        mutating func line(_ bytes: Data, start: UInt64, end: UInt64) {
            defer { lastLineEnd = end }
            // Tool output is most of the bytes, and never a message.
            guard !bytes.isEmpty, !Self.isToolResult(bytes),
                  let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            else { return }
            if let session = object["sessionId"] as? String, !session.isEmpty {
                if let expectedSession, session != expectedSession { return }
                self.session = session
            }
            if let branch = object["gitBranch"] as? String {
                // `HEAD`: a detached checkout, no branch.
                self.branch = branch.isEmpty || branch == "HEAD" ? nil : branch
            }
            let stopReason = (object["message"] as? [String: Any])?["stop_reason"] as? String
            if object["type"] as? String == "assistant", let stopReason { lastAnswerIsFinal = stopReason != "tool_use" }
            if TranscriptLine.isStandIn(object) { lastAnswerIsFinal = true }
            guard let entry = TranscriptLine.entry(object) else { return }
            func dated(_ date: Date?) -> Date {
                if let date { lastDate = date }
                return lastDate
            }
            switch entry {
            case .user(let text, let date):
                startsTurn(at: start)
                let isLaunch = ProjectHistory.isLaunchPrompt(text)
                messages.append(NewMessage(
                    kind: isLaunch ? .peer : .user, branch: branch, from: isLaunch ? ProjectHistory.niruxSender : nil,
                    text: text, date: dated(date), session: session, uuid: object["uuid"] as? String
                ))
            case .peer(let text, let from, let date):
                startsTurn(at: start)
                messages.append(NewMessage(
                    kind: .peer, branch: branch, from: from, text: text, date: dated(date), session: session,
                    uuid: object["uuid"] as? String
                ))
            case .turnStart:
                startsTurn(at: start)
            case .toolUse:
                if openTurnStart == nil { openTurnStart = start }
                reply = []
                lastAnswerIsFinal = false
            case .assistantText(let text, let date):
                if openTurnStart == nil { openTurnStart = start }
                reply.append(text)
                replyDate = dated(date)
                replyUUID = object["uuid"] as? String
                failed = false
                if stopReason == nil { lastAnswerIsFinal = true }
            case .apiError:
                if openTurnStart == nil { openTurnStart = start }
                reply = []
                failed = true
            case .turnEnd:
                // A turn can end on a tool call (`ScheduleWakeup`, an
                // interrupted question): its mark ends it, without a reply.
                if openTurnStart != nil { close(end: end, withReply: !failed) }
            }
        }

        /// A message or a report after a final answer ends the turn before
        /// it; during the tool loop (after text Claude wrote before a tool
        /// call, as when Esc stopped it), it joins the turn underway.
        private mutating func startsTurn(at start: UInt64) {
            if !reply.isEmpty, lastAnswerIsFinal != false { close(end: start, withReply: true) }
            if openTurnStart == nil { openTurnStart = start }
        }

        private mutating func close(end: UInt64, withReply: Bool) {
            var all = messages
            let text = reply.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if withReply, !text.isEmpty {
                all.append(NewMessage(
                    kind: .talk, branch: branch, text: text, date: replyDate ?? lastDate, session: session, uuid: replyUUID
                ))
            }
            if !all.isEmpty { turns.append(Turn(messages: all, end: end)) }
            messages = []
            reply = []
            replyDate = nil
            replyUUID = nil
            failed = false
            lastAnswerIsFinal = nil
            openTurnStart = nil
        }

        mutating func finish(lastTurnEnded: Bool, endedWithError: Bool, skippedLongLine: Bool) -> TurnReader.Result {
            // A turn the session's end cut short keeps its messages; text
            // written between tool calls is not its reply.
            if lastTurnEnded, openTurnStart != nil {
                close(end: lastLineEnd, withReply: !endedWithError && !failed && lastAnswerIsFinal == true)
            }
            return TurnReader.Result(
                turns: turns, resumeOffset: openTurnStart ?? lastLineEnd, skippedLongLine: skippedLongLine
            )
        }

        private static let toolResultMarker = Data("\"type\":\"tool_result\"".utf8)

        private static func isToolResult(_ bytes: Data) -> Bool {
            bytes.range(of: toolResultMarker) != nil && bytes.range(of: Data("\"type\":\"user\"".utf8)) != nil
        }
    }
}

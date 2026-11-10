import Foundation

// MARK: - What a failed job's log says

extension CITriage {
    struct TestFailure: Equatable, Sendable {
        /// As the log names it: a path on the runner, or `<unknown>`.
        let file: String
        let line: Int
        let message: String
    }

    struct FailedTest: Equatable, Sendable {
        /// `Class.testMethod`.
        let name: String
        /// Empty for a test XCTest reports failed with no failure line the
        /// parser could read.
        var failures: [TestFailure]
    }

    /// An error with a place in the sources: the compiler's, or a crash's
    /// (`Fatal error`).
    struct SourceError: Equatable, Sendable {
        /// As the repository names it when the log gives a runner's path.
        let file: String
        let line: Int
        let message: String
    }

    /// What the rules and the model read of one job's log. XCTest and
    /// Swift build output only: the formats the rules were measured on.
    /// Another test framework's failures are not recognized, so its runs
    /// get no verdict rather than a guess.
    struct LogFindings: Equatable, Sendable {
        var tests: [FailedTest] = []
        /// Tests that started and never ended: a crash or a hang.
        var unfinished: [String] = []
        var compileErrors: [SourceError] = []
        /// "File.swift:12: Fatal error: …": where a test process trapped.
        var crashes: [SourceError] = []
        /// SwiftPM's "failed downloading … required by binary target".
        var downloadFailures: [String] = []
        /// "Exited with unexpected signal code N".
        var signals: [Int] = []
        /// Error lines nothing above accounts for: SwiftPM's own (`error:
        /// …`), a workflow's (`##[error]…`, but for "Process completed
        /// with exit code N", which every failed step ends on). With one
        /// of them the log holds a failure the parser can't read, and no
        /// rule calls the job flaky.
        var otherErrors: [String] = []

        /// The failed tests, then the unfinished ones not among them.
        var failingTestNames: [String] {
            let failed = Set(tests.map(\.name))
            return tests.map(\.name) + unfinished.filter { !failed.contains($0) }
        }

        /// Nothing recognized, and nothing unexplained either.
        var isEmpty: Bool { self == LogFindings() }

        /// Several jobs' findings as one, for the model.
        static func merged(_ all: [LogFindings]) -> LogFindings {
            var merged = LogFindings()
            for findings in all {
                for test in findings.tests where !merged.tests.contains(where: { $0.name == test.name }) { merged.tests.append(test) }
                merged.unfinished += findings.unfinished.filter { !merged.unfinished.contains($0) }
                merged.compileErrors += findings.compileErrors
                merged.crashes += findings.crashes
                merged.downloadFailures += findings.downloadFailures
                merged.signals += findings.signals
                merged.otherErrors += findings.otherErrors
            }
            return merged
        }
    }

    /// Bounds on what one job's log may yield: a run that fails everywhere
    /// says no more with its thousandth failure.
    static let maxTests = 200
    static let maxFailuresPerTest = 20
    static let maxCompileErrors = 50
    static let maxMessageLength = 500
    static let maxOtherErrors = 8
    /// "Test Case '-[Module.Class test]' …" markers read on one line, and
    /// how far after one its closing "]' " is looked for.
    static let maxTestCasesPerLine = 16
    static let maxTestCaseLength = 600
    /// A line longer than this is read by its start and its end: the
    /// middle of a megabyte of output on one line says nothing the rules
    /// read.
    static let maxLineLength = 16_384

    /// Reads `gh run view --log-failed` (`job<TAB>step<TAB>timestamp
    /// line`) job by job, in the order the jobs appear. A job's raw log
    /// (`timestamp line`, no columns) reads as one job named "".
    static func findings(inFailedLog log: Data) -> [(job: String, findings: LogFindings)] {
        var readers: [String: JobLogReader] = [:]
        var order: [String] = []
        for rawLine in String(decoding: log, as: UTF8.self).split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            // Cheap filter first: a log is mostly passing tests.
            guard rawLine.contains("error") || rawLine.contains("Test Case '") || rawLine.contains("signal code")
                || rawLine.contains("Fatal error") || rawLine.contains("Precondition failed") || rawLine.contains("Assertion failed")
                || rawLine.contains("\u{2718}") else { continue }
            let (job, line) = jobAndContent(of: bounded(rawLine))
            if readers[job] == nil {
                readers[job] = JobLogReader()
                order.append(job)
            }
            readers[job]?.read(line)
        }
        return order.map { ($0, readers[$0]?.findings ?? LogFindings()) }
    }

    /// One job's lines, read in order.
    private struct JobLogReader {
        private var result = LogFindings()
        private var indexOfTest: [String: Int] = [:]
        private var seen = Set<String>()
        private var started: [String: Int] = [:]
        private var order = 0

        var findings: LogFindings {
            var findings = result
            findings.unfinished = started.sorted { $0.value < $1.value }.prefix(CITriage.maxTests).map(\.key)
            return findings
        }

        mutating func read(_ line: String) {
            noteTestCases(in: line)
            if let (name, failure) = CITriage.testFailure(in: line) {
                guard seen.insert("t\u{0}\(name)\u{0}\(failure.file)\u{0}\(failure.line)\u{0}\(failure.message)").inserted else { return }
                add(name, failure)
            } else if let error = CITriage.compileError(in: line) {
                guard seen.insert("c\u{0}\(error.file)\u{0}\(error.line)\u{0}\(error.message)").inserted,
                      result.compileErrors.count < CITriage.maxCompileErrors else { return }
                result.compileErrors.append(error)
            } else if let crash = CITriage.crash(in: line) {
                guard seen.insert("f\u{0}\(crash.file)\u{0}\(crash.line)").inserted, result.crashes.count < 8 else { return }
                result.crashes.append(crash)
            } else if line.hasPrefix("error: failed downloading '"), line.contains("which is required by binary target") {
                if result.downloadFailures.count < 4 { result.downloadFailures.append(String(line.prefix(CITriage.maxMessageLength))) }
            } else if let signal = CITriage.signalCode(in: line) {
                if result.signals.count < 8 { result.signals.append(signal) }
            } else if let other = CITriage.otherError(in: line) ?? CITriage.unreadError(in: line) {
                addOther(other)
            }
        }

        private mutating func addOther(_ other: String) {
            guard seen.insert("o\u{0}\(other)").inserted, result.otherErrors.count < CITriage.maxOtherErrors else { return }
            result.otherErrors.append(other)
        }

        private mutating func add(_ name: String, _ failure: TestFailure?) {
            if let index = indexOfTest[name] {
                if let failure, result.tests[index].failures.count < CITriage.maxFailuresPerTest {
                    result.tests[index].failures.append(failure)
                }
            } else if result.tests.count < CITriage.maxTests {
                indexOfTest[name] = result.tests.count
                result.tests.append(FailedTest(name: name, failures: failure.map { [$0] } ?? []))
            }
        }

        /// "Test Case '-[Module.FooTests testBar]' started." opens a test;
        /// passed, failed or skipped closes it, wherever on the line: a
        /// test that prints without a newline pushes its end mid-line. A
        /// test XCTest says failed is a failing test, whether or not a
        /// failure line of it could be read.
        private mutating func noteTestCases(in line: String) {
            for marker in CITriage.testCaseMarkers(in: line) {
                let rest = line[marker...].prefix(CITriage.maxTestCaseLength)
                guard let close = rest.range(of: "]' ") else { continue }
                let state = rest[close.upperBound...]
                guard let name = CITriage.testName(rest[..<close.lowerBound]) else {
                    // A test XCTest says failed, under a name the parser
                    // can't read (a nested class, a mangled name).
                    if state.hasPrefix("failed") { addOther("Test Case '-[" + rest[..<close.lowerBound] + "]' failed") }
                    continue
                }
                if state.hasPrefix("started") {
                    if started[name] == nil {
                        started[name] = order
                        order += 1
                    }
                } else if state.hasPrefix("failed") {
                    started[name] = nil
                    add(name, nil)
                } else if state.hasPrefix("passed") || state.hasPrefix("skipped") {
                    started[name] = nil
                }
            }
        }
    }

    /// Where the names of the line's "Test Case '-[…]'" markers start, in
    /// order: its first and its last `maxTestCasesPerLine / 2` (a test that
    /// prints without a newline pushes its end to the end of a long line).
    /// Bounded: a line made of thousands of markers (a log is the pull
    /// request's own output) costs what a few do.
    static func testCaseMarkers(in line: String) -> [String.Index] {
        let marker = "Test Case '-["
        let half = maxTestCasesPerLine / 2
        var first: [String.Index] = []
        var search = line.startIndex..<line.endIndex
        while first.count < half, let found = line.range(of: marker, range: search) {
            first.append(found.upperBound)
            search = found.upperBound..<line.endIndex
        }
        var last: [String.Index] = []
        var end = line.endIndex
        while last.count < half, let found = line.range(of: marker, options: .backwards, range: line.startIndex..<end) {
            if let lastOfFirst = first.last, found.upperBound <= lastOfFirst { break }
            last.append(found.upperBound)
            end = found.lowerBound
        }
        return first + last.reversed()
    }

    /// The line, or its first and last `maxLineLength / 2` bytes.
    private static func bounded(_ line: Substring) -> Substring {
        let bytes = line.utf8
        guard bytes.count > maxLineLength else { return line }
        let half = maxLineLength / 2
        let head = String(decoding: bytes.prefix(half), as: UTF8.self)
        let tail = String(decoding: bytes.suffix(half), as: UTF8.self)
        return Substring(head + " … " + tail)
    }

    /// gh's job column ("" without columns) and the line without the
    /// columns, a byte order mark, the runner's timestamp and terminal
    /// escapes.
    static func jobAndContent(of rawLine: Substring) -> (job: String, content: String) {
        var line = rawLine
        var job = ""
        if let stamped = afterTimestamp(line) {
            line = stamped
        } else if let firstTab = line.firstIndex(of: "\t"),
                  let secondTab = line[line.index(after: firstTab)...].firstIndex(of: "\t"),
                  let stamped = afterTimestamp(line[line.index(after: secondTab)...]) {
            // Only with a timestamp behind them are two tabs gh's columns:
            // a test's own output has tabs too.
            job = String(line[..<firstTab])
            line = stamped
        }
        guard line.contains("\u{1B}") else { return (job, String(line)) }
        var plain = ""
        var characters = line.makeIterator()
        while let character = characters.next() {
            guard character == "\u{1B}" else {
                plain.append(character)
                continue
            }
            // ESC [ parameters letter.
            guard characters.next() == "[" else { continue }
            while let parameter = characters.next(), !parameter.isLetter {}
        }
        return (job, plain)
    }

    /// What follows the runner's timestamp ("2026-11-09T23:09:12.1234567Z ",
    /// behind a byte order mark on a step's first line), nil without one.
    private static func afterTimestamp(_ text: Substring) -> Substring? {
        let line = text.first == "\u{FEFF}" ? text.dropFirst() : text
        guard let space = line.firstIndex(of: " ") else { return nil }
        let stamp = line[..<space].utf8
        guard (20...40).contains(stamp.count), stamp.last == UInt8(ascii: "Z"),
              stamp.prefix(4).allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              stamp.dropFirst(10).first == UInt8(ascii: "T")
        else { return nil }
        return line[line.index(after: space)...]
    }

    /// `path/FooTests.swift:12: error: -[Module.FooTests testBar] : message`
    /// (`<unknown>:0` for an exception): XCTest's failure line.
    static func testFailure(in line: String) -> (name: String, failure: TestFailure)? {
        guard let marker = line.range(of: ": error: -[") else { return nil }
        let location = line[..<marker.lowerBound]
        guard let colon = location.lastIndex(of: ":"), let lineNumber = Int(location[location.index(after: colon)...])
        else { return nil }
        let file = location[..<colon]
        guard file == "<unknown>" || isSwiftPath(file) else { return nil }
        let rest = line[marker.upperBound...]
        guard let close = rest.range(of: "] : ") else { return nil }
        guard let name = testName(rest[..<close.lowerBound]) else { return nil }
        let message = String(rest[close.upperBound...].prefix(maxMessageLength))
        return (name, TestFailure(file: String(file), line: lineNumber, message: message))
    }

    /// `path/Foo.swift:12:5: error: message`: the Swift compiler's.
    static func compileError(in line: String) -> SourceError? {
        guard let marker = line.range(of: ": error: ") else { return nil }
        let location = line[..<marker.lowerBound]
        guard let columnColon = location.lastIndex(of: ":"), Int(location[location.index(after: columnColon)...]) != nil
        else { return nil }
        let beforeColumn = location[..<columnColon]
        guard let lineColon = beforeColumn.lastIndex(of: ":"),
              let lineNumber = Int(beforeColumn[beforeColumn.index(after: lineColon)...]),
              isSwiftPath(beforeColumn[..<lineColon])
        else { return nil }
        return SourceError(
            file: repositoryPath(String(beforeColumn[..<lineColon])), line: lineNumber,
            message: String(line[marker.upperBound...].prefix(maxMessageLength))
        )
    }

    /// `Module/Foo.swift:12: Fatal error: message` (or "Precondition
    /// failed", "Assertion failed"): the Swift runtime's, when a process
    /// traps.
    static func crash(in line: String) -> SourceError? {
        guard let marker = [": Fatal error", ": Precondition failed", ": Assertion failed"].lazy
            .compactMap({ line.range(of: $0) }).first else { return nil }
        let location = line[..<marker.lowerBound]
        guard let colon = location.lastIndex(of: ":"), let lineNumber = Int(location[location.index(after: colon)...]),
              isSwiftPath(location[..<colon])
        else { return nil }
        // "Fatal error: x" keeps its kind: a precondition reads as one.
        let message = line[line.index(marker.lowerBound, offsetBy: 2)...]
        return SourceError(
            file: repositoryPath(String(location[..<colon])), line: lineNumber, message: String(message.prefix(maxMessageLength))
        )
    }

    /// An error line no other reading takes: `error: …` at the start of a
    /// line (SwiftPM's, but for the "fatalError" it ends a failed run on),
    /// a workflow's `##[error]…` / `::error::…` (but for the exit code
    /// every failed step reports), or a Swift Testing failure (`✘ …`): a
    /// framework the rules don't read.
    static func otherError(in line: String) -> String? {
        let message: Substring
        if line.hasPrefix("\u{2718} ") {
            message = line.dropFirst(2)
        } else if line.hasPrefix("error: ") {
            message = line.dropFirst(7)
            if message == "fatalError" { return nil }
        } else if line.hasPrefix("##[error]") {
            message = line.dropFirst(9)
        } else if line.hasPrefix("::error::") {
            message = line.dropFirst(9)
        } else {
            return nil
        }
        if message.hasPrefix("Process completed with exit code") { return nil }
        return String(message.prefix(200))
    }

    /// A line that reports an error none of the readings above took: an
    /// XCTest failure under a name or in a file the parser can't read, a
    /// tool's `…: error: …`. Such a failure may be real: it keeps the job
    /// from any verdict.
    static func unreadError(in line: String) -> String? {
        guard line.contains(": error: ") else { return nil }
        return String(line.prefix(200))
    }

    /// `Class.testMethod` from `Module.Class testMethod`.
    fileprivate static func testName(_ text: Substring) -> String? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, isIdentifier(parts[1]) else { return nil }
        let type = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard type.count == 2, type.allSatisfy(isIdentifier) else { return nil }
        return "\(type[1]).\(parts[1])"
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        !text.isEmpty && text.count <= 200 && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func isSwiftPath(_ text: Substring) -> Bool {
        text.hasSuffix(".swift") && text.count <= 1_024 && !text.contains(where: \.isWhitespace)
    }

    fileprivate static func signalCode(in line: String) -> Int? {
        guard let marker = line.range(of: "unexpected signal code ") else { return nil }
        return Int(line[marker.upperBound...].prefix { $0.isNumber })
    }

    /// A runner's path under its checkout (`…/work/<repository>/<repository>/`)
    /// as the repository names it; any other path as it is.
    static func repositoryPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), let work = parts.firstIndex(of: "work"), parts.count > work + 3,
              parts[work + 1] == parts[work + 2]
        else { return path }
        return parts[(work + 3)...].joined(separator: "/")
    }
}

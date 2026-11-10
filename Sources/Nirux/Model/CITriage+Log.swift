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
        var failures: [TestFailure]
    }

    struct CompileError: Equatable, Sendable {
        let file: String
        let line: Int
        let message: String
    }

    /// What the rules and the model read of a log. XCTest and Swift build
    /// output only: the formats the rules were measured on. Another test
    /// framework's failures are not recognized, so its runs get no verdict
    /// rather than a guess.
    struct LogFindings: Equatable, Sendable {
        var tests: [FailedTest] = []
        /// Tests that started and never ended: a crash or a hang.
        var unfinished: [String] = []
        var compileErrors: [CompileError] = []
        /// SwiftPM's "failed downloading … required by binary target".
        var downloadFailures: [String] = []
        /// "Exited with unexpected signal code N".
        var signals: [Int] = []

        /// The failed tests, then the unfinished ones not among them.
        var failingTestNames: [String] {
            let failed = Set(tests.map(\.name))
            return tests.map(\.name) + unfinished.filter { !failed.contains($0) }
        }
    }

    /// Bounds on what one log may yield: a run that fails everywhere says
    /// no more with its thousandth failure.
    static let maxTests = 200
    static let maxFailuresPerTest = 20
    static let maxCompileErrors = 50
    static let maxMessageLength = 500

    /// Reads `gh run view --log-failed` (`job<TAB>step<TAB>timestamp
    /// line`), or a job's raw log (`timestamp line`).
    static func findings(inFailedLog log: Data) -> LogFindings {
        var findings = LogFindings()
        var indexOfTest: [String: Int] = [:]
        var seenFailures = Set<String>()
        var seenCompileErrors = Set<String>()
        var started: [String: Int] = [:]
        var order = 0
        for rawLine in String(decoding: log, as: UTF8.self).split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            // Cheap filter first: a log is mostly passing tests.
            guard rawLine.contains("error") || rawLine.contains("Test Case '") || rawLine.contains("signal code") else { continue }
            let line = content(of: rawLine)
            noteTestCases(in: line, started: &started, order: &order)
            if let (name, failure) = testFailure(in: line) {
                let key = "\(name)\u{0}\(failure.file)\u{0}\(failure.line)\u{0}\(failure.message)"
                guard seenFailures.insert(key).inserted else { continue }
                if let index = indexOfTest[name] {
                    if findings.tests[index].failures.count < maxFailuresPerTest { findings.tests[index].failures.append(failure) }
                } else if findings.tests.count < maxTests {
                    indexOfTest[name] = findings.tests.count
                    findings.tests.append(FailedTest(name: name, failures: [failure]))
                }
            } else if let error = compileError(in: line) {
                guard seenCompileErrors.insert("\(error.file)\u{0}\(error.line)\u{0}\(error.message)").inserted,
                      findings.compileErrors.count < maxCompileErrors else { continue }
                findings.compileErrors.append(error)
            } else if line.hasPrefix("error: failed downloading '"), line.contains("which is required by binary target") {
                if findings.downloadFailures.count < 4 { findings.downloadFailures.append(String(line.prefix(maxMessageLength))) }
            } else if let signal = signalCode(in: line) {
                if findings.signals.count < 8 { findings.signals.append(signal) }
            }
        }
        findings.unfinished = started.sorted { $0.value < $1.value }.prefix(maxTests).map(\.key)
        return findings
    }

    /// The line without gh's `job<TAB>step<TAB>` columns, a byte order
    /// mark, the runner's timestamp and terminal escapes.
    static func content(of rawLine: Substring) -> String {
        var line = rawLine
        if let stamped = afterTimestamp(line) {
            line = stamped
        } else if let firstTab = line.firstIndex(of: "\t"),
                  let secondTab = line[line.index(after: firstTab)...].firstIndex(of: "\t"),
                  let stamped = afterTimestamp(line[line.index(after: secondTab)...]) {
            // Only with a timestamp behind them are two tabs gh's columns:
            // a test's own output has tabs too.
            line = stamped
        }
        guard line.contains("\u{1B}") else { return String(line) }
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
        return plain
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
    static func compileError(in line: String) -> CompileError? {
        guard let marker = line.range(of: ": error: ") else { return nil }
        let location = line[..<marker.lowerBound]
        guard let columnColon = location.lastIndex(of: ":"), Int(location[location.index(after: columnColon)...]) != nil
        else { return nil }
        let beforeColumn = location[..<columnColon]
        guard let lineColon = beforeColumn.lastIndex(of: ":"),
              let lineNumber = Int(beforeColumn[beforeColumn.index(after: lineColon)...]),
              isSwiftPath(beforeColumn[..<lineColon])
        else { return nil }
        return CompileError(
            file: repositoryPath(String(beforeColumn[..<lineColon])), line: lineNumber,
            message: String(line[marker.upperBound...].prefix(maxMessageLength))
        )
    }

    /// "Test Case '-[Module.FooTests testBar]' started." opens a test;
    /// passed, failed or skipped closes it, wherever on the line: a test
    /// that prints without a newline pushes its end mid-line.
    private static func noteTestCases(in line: String, started: inout [String: Int], order: inout Int) {
        var rest = Substring(line)
        while let marker = rest.range(of: "Test Case '-[") {
            rest = rest[marker.upperBound...]
            guard let close = rest.range(of: "]' "), let name = testName(rest[..<close.lowerBound]) else { continue }
            let state = rest[close.upperBound...]
            if state.hasPrefix("started") {
                if started[name] == nil {
                    started[name] = order
                    order += 1
                }
            } else if state.hasPrefix("passed") || state.hasPrefix("failed") || state.hasPrefix("skipped") {
                started[name] = nil
            }
        }
    }

    /// `Class.testMethod` from `Module.Class testMethod`.
    private static func testName(_ text: Substring) -> String? {
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

    private static func signalCode(in line: String) -> Int? {
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

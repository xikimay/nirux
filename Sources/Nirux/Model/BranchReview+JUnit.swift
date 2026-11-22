import Foundation

extension BranchReview {
    enum JUnit {
        static let maxBytes = 2_000_000

        enum Problem: String, LocalizedError {
            case unreadable = "Choose a readable, regular XML file without symlinks."
            case tooLarge = "The JUnit report exceeds 2 MB."
            case invalid = "The file is not a valid JUnit XML report."
            case doctype = "JUnit reports with a document type declaration cannot be imported."
            case encoding = "Save the JUnit report as UTF-8 or UTF-16 and try again."
            case incomplete = "Refresh the review and try again once the full working tree can be read."

            var errorDescription: String? { rawValue }
        }

        static func read(_ url: URL, for snapshot: Snapshot) throws -> Receipt {
            guard let data = ProjectMemory.readData(url.path, limit: maxBytes + 1, followingSymlinks: false) else {
                throw Problem.unreadable
            }
            return try receipt(from: data, filename: url.lastPathComponent, snapshot: snapshot, id: UUID().uuidString, at: Date())
        }

        static func receipt(from data: Data, filename: String, snapshot: Snapshot,
                            id: String, at date: Date) throws -> Receipt {
            guard data.count <= maxBytes else { throw Problem.tooLarge }
            let tree = snapshot.workingTree
            guard tree != .incomplete else { throw Problem.incomplete }
            try checkProlog(data)
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            let reader = JUnitReader()
            parser.delegate = reader
            guard parser.parse(), parser.parserError == nil, let counts = reader.result else { throw Problem.invalid }
            let tests = counts[.tests, default: 0], failures = counts[.failures, default: 0]
            let errors = counts[.errors, default: 0], skipped = counts[.skipped, default: 0]
            let failed = failures > 0 || errors > 0
            var summary = "\(tests) test\(tests == 1 ? "" : "s"), \(failures) failure\(failures == 1 ? "" : "s")"
            if errors > 0 { summary += ", \(errors) error\(errors == 1 ? "" : "s")" }
            if skipped > 0 { summary += ", \(skipped) skipped" }
            if let time = reader.duration {
                let seconds = time.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...3)))
                summary += " (\(seconds)s)"
            }
            if failed, !reader.names.isEmpty { summary += ": " + reader.names.joined(separator: ", ") }
            return Receipt(id: id, title: label(reader.title ?? filename), command: nil,
                           status: failed ? .failed : (tests > 0 ? .passed : .unknown), summary: summary,
                           provenance: .local, recordedAt: date, head: snapshot.head, workingTreeDigest: tree.digest)
        }

        fileprivate static func label(_ value: String) -> String {
            let prefix = BranchReview.visible(String(value.unicodeScalars.prefix(121))).unicodeScalars
            return prefix.count > 120 ? String(prefix.prefix(119)) + "…" : String(prefix)
        }

        // XMLParser exposes entity declarations only after entering a DTD. Check the prolog
        // before parsing, leaving literal declaration text in test output alone.
        private static func checkProlog(_ data: Data) throws {
            let utf16 = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
            guard let xml = String(data: data, encoding: utf16 ? .utf16 : .utf8),
                  !xml.utf8.contains(0) else { throw Problem.encoding }
            let scanner = Scanner(string: xml)
            scanner.caseSensitive = true
            scanner.charactersToBeSkipped = nil
            _ = scanner.scanString("\u{feff}")
            while true {
                _ = scanner.scanCharacters(from: .whitespacesAndNewlines)
                if scanner.scanString("<!--") != nil {
                    _ = scanner.scanUpToString("-->")
                    guard scanner.scanString("-->") != nil else { throw Problem.invalid }
                } else if scanner.scanString("<?") != nil {
                    let instruction = scanner.scanUpToString("?>") ?? ""
                    guard scanner.scanString("?>") != nil else { throw Problem.invalid }
                    if instruction.hasPrefix("xml"), instruction.dropFirst(3).first?.isWhitespace == true,
                       instruction.contains("encoding") {
                        let encodings = utf16 ? "UTF-16(?:LE|BE)?" : "UTF-8|US-ASCII"
                        let pattern = #"encoding\s*=\s*(["'])(?:"# + encodings + #")\1"#
                        guard instruction.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                        else { throw Problem.encoding }
                    }
                } else {
                    if scanner.scanString("<!DOCTYPE") != nil { throw Problem.doctype }
                    guard scanner.scanString("<testsuite") != nil else { throw Problem.invalid }
                    return
                }
            }
        }
    }
}

private final class JUnitReader: NSObject, XMLParserDelegate {
    enum Count: String, CaseIterable { case tests, failures, errors, skipped }
    typealias Counts = [Count: Int]

    private struct Suite {
        let declared: Counts
        let duration: Double?
        var children: Counts = [:]
        var suiteCount = 0
        var childDuration: Double? = 0

        mutating func add(_ totals: Counts) -> Bool {
            for (key, value) in totals {
                let (sum, overflow) = children[key, default: 0].addingReportingOverflow(value)
                guard !overflow else { return false }
                children[key] = sum
            }
            return true
        }

        init(_ attributes: [String: String]) throws {
            var counts = Counts()
            for key in Count.allCases {
                guard let text = attributes[key.rawValue] else { continue }
                guard let value = Int(text), value >= 0 else { throw BranchReview.JUnit.Problem.invalid }
                counts[key] = value
            }
            declared = counts
            if let text = attributes["time"] {
                guard let value = Double(text), value.isFinite, value >= 0 else { throw BranchReview.JUnit.Problem.invalid }
                duration = value
            } else {
                duration = nil
            }
        }
    }

    private var suites: [Suite] = []
    private var test: (name: String?, outcomes: Set<Count>)?
    private var ignoredDepth = 0
    private var rootIsCollection = false
    private(set) var title: String?
    private(set) var duration: Double?
    private(set) var names: [String] = []
    private(set) var result: Counts?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if ignoredDepth > 0 { ignoredDepth += 1; return }
        let root = suites.isEmpty
        switch name {
        case "testsuites", "testsuite":
            guard test == nil, root || name == "testsuite", let suite = try? Suite(attributes) else { return parser.abortParsing() }
            if root {
                rootIsCollection = name == "testsuites"
                title = attributes["name"].flatMap { $0.isEmpty ? nil : $0 }
            }
            suites.append(suite)
        case "testcase":
            guard !root, test == nil, !rootIsCollection || suites.count > 1 else { return parser.abortParsing() }
            let label = attributes["name"].flatMap { name -> String? in
                guard !name.isEmpty else { return nil }
                let parts = [attributes["classname"], name].compactMap { $0 }.filter { !$0.isEmpty }
                return BranchReview.JUnit.label(parts.joined(separator: "."))
            }
            test = (label, [])
        case "failure", "error", "skipped":
            guard test != nil else { return parser.abortParsing() }
            test?.outcomes.insert(name == "failure" ? .failures : (name == "error" ? .errors : .skipped))
            ignoredDepth = 1
        case "properties", "system-out", "system-err":
            guard !root else { return parser.abortParsing() }
            ignoredDepth = 1
        default:
            return parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if ignoredDepth == 0, !string.allSatisfy(\.isWhitespace) { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if ignoredDepth == 0 { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if ignoredDepth > 0 { ignoredDepth -= 1; return }
        if name == "testcase", let test {
            let index = suites.count - 1
            var counts: Counts = [.tests: 1]
            for count in test.outcomes { counts[count] = 1 }
            guard suites[index].add(counts) else { return parser.abortParsing() }
            suites[index].childDuration = nil
            if names.count < 5, !test.outcomes.isDisjoint(with: [.failures, .errors]), let name = test.name { names.append(name) }
            self.test = nil
            return
        }
        guard let suite = suites.popLast() else { return parser.abortParsing() }
        var totals = suite.children
        for (key, value) in suite.declared {
            guard value >= totals[key, default: 0] else { return parser.abortParsing() }
            totals[key] = value
        }
        let time = suite.duration ?? (suite.suiteCount > 0 ? suite.childDuration : nil)
        if suites.isEmpty {
            guard !rootIsCollection || suite.suiteCount > 0 || totals.values.allSatisfy({ $0 == 0 }) else {
                return parser.abortParsing()
            }
            result = totals
            duration = time
        } else {
            let index = suites.count - 1
            guard suites[index].add(totals) else { return parser.abortParsing() }
            suites[index].suiteCount += 1
            let sum = suites[index].childDuration.flatMap { previous in time.map { previous + $0 } }
            suites[index].childDuration = sum.flatMap { $0.isFinite ? $0 : nil }
        }
    }
}

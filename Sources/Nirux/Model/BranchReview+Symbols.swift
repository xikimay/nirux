import CryptoKit
import Foundation

// MARK: - Tests against code (section 5)

extension BranchReview {
    /// An identifier a Swift file declares (see `SwiftScanner`).
    struct Symbol: Equatable, Sendable {
        let name: String
        /// 1-based, in the file at the head.
        let line: Int
    }

    /// What a Swift code file declares on its added lines.
    enum SymbolScan: Equatable, Sendable {
        /// Each name once, at its first line.
        case read([Symbol])
        /// Unknown: its patch wasn't read, its added lines weren't all
        /// collected, the file at the head couldn't be read whole, or it no
        /// longer matches the patch (the agent edited it meanwhile).
        case unread
    }

    /// Lines added in tests against lines added in code, and the symbols
    /// the branch declares that no test mentions. A mention isn't
    /// coverage: the page says "mentions", never "tested".
    struct TestsAgainstCode: Equatable, Sendable {
        struct Unmentioned: Equatable, Sendable {
            let path: String
            let symbol: Symbol
        }

        /// Added lines of the Tests group's files, folded files aside.
        var testLines = 0
        /// Added lines of the Code group's files, folded files aside.
        var codeLines = 0
        /// The symbols the Swift code files declare, each name once per
        /// file.
        var declared = 0
        /// Those no file of the Tests group names as a whole word, by path
        /// then line.
        var unmentioned: [Unmentioned] = []
        /// Swift code files whose symbols are unknown (`SymbolScan.unread`),
        /// by path.
        var unscannedFiles: [String] = []
        /// Test files left out or cut short by the read limits while a
        /// symbol was still unmentioned: it may be mentioned there.
        var unreadTestFiles = 0
        /// git couldn't list the test files: every symbol reads as
        /// unmentioned.
        var testFilesUnlisted = false
    }

    /// The Code group's Swift files: the only ones whose symbols are read.
    static func isSwiftCode(_ path: String) -> Bool {
        path.hasSuffix(".swift") && PathGroup(path: path) == .code
    }

    /// Whether `file` may declare symbols the review lists: Swift code,
    /// not folded, not deleted. A file whose lines weren't read is then
    /// `SymbolScan.unread`.
    static func mayDeclareSymbols(_ file: FileChange) -> Bool {
        isSwiftCode(file.path) && file.fold == nil && file.status != .deleted
    }

    /// `symbols` for a file listed without its patch.
    static func unreadSymbols(of file: FileChange) -> SymbolScan? {
        mayDeclareSymbols(file) && (file.additions > 0 || file.isUntracked) ? .unread : nil
    }

    private static let maxScannedFileBytes = 2 << 20
    static let maxScannedBytes = 32 << 20

    /// The symbols declared on `added` lines of the file at `path`, as it
    /// is on disk. `.unread` when its lines weren't all collected, it is
    /// over `maxScannedFileBytes` or the rest of `budget`, or it no longer
    /// matches the patch.
    static func scanSymbols(at path: String, added: AddedLines?, budget: inout Int) -> SymbolScan {
        let limit = min(maxScannedFileBytes, budget)
        guard let added, limit > 0, let head = readPrefix(of: path, maxBytes: limit + 1), head.count <= limit
        else { return .unread }
        budget -= head.count
        var scanner = SwiftScanner()
        var digest = LineDigest()
        var ranges = added.ranges[...]
        var number = 0
        head.withUnsafeBytes { bytes in
            var start = 0
            while start < bytes.count {
                let end = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
                number += 1
                while let first = ranges.first, first.upperBound <= number { ranges.removeFirst() }
                let isAdded = ranges.first?.contains(number) == true
                let line = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
                if isAdded { digest.add(line) }
                scanner.feed(line, collecting: isAdded)
                start = end + 1
            }
        }
        guard digest.finalize() == added.digest else { return .unread }
        var seen: Set<String> = []
        return .read(scanner.symbols.filter { seen.insert($0.name).inserted })
    }

    /// The test and code lines, and the symbols no test mentions, of
    /// `files` as the snapshot read them.
    static func testsAgainstCode(of files: [FileChange], root: String, options: Options) -> TestsAgainstCode {
        var result = TestsAgainstCode()
        var declared: [TestsAgainstCode.Unmentioned] = []
        for file in files where file.fold == nil {
            switch PathGroup(path: file.path) {
            case .tests: result.testLines += file.additions
            case .code: result.codeLines += file.additions
            default: break
            }
            switch file.symbols {
            case .read(let symbols)?: declared += symbols.map { TestsAgainstCode.Unmentioned(path: file.path, symbol: $0) }
            case .unread?: result.unscannedFiles.append(file.path)
            case nil: break
            }
        }
        result.unscannedFiles.sort()
        result.declared = declared.count
        guard !declared.isEmpty else { return result }
        let mentions = mentions(of: Set(declared.map(\.symbol.name)), root: root, options: options)
        result.testFilesUnlisted = mentions == nil
        result.unreadTestFiles = mentions?.unread ?? 0
        result.unmentioned = declared
            .filter { mentions?.found.contains($0.symbol.name) != true }
            .sorted { ($0.path, $0.symbol.line) < ($1.path, $1.symbol.line) }
        return result
    }

    // MARK: Mentions

    /// What `PathGroup` takes for a test, as pathspecs: the listing is
    /// then checked against `PathGroup` itself.
    private static let testPathspecs = [
        ":(glob)**/Tests/**", ":(glob)**/*Tests.swift", ":(glob)**/*_test.*", ":(glob)**/*.test.*", ":(glob)**/*.spec.*"
    ]
    static let maxTestFiles = 4_000
    static let maxTestFileBytes = 1 << 20
    static let maxTestBytes = 32 << 20

    /// The `names` some test file holds as a whole word, and how many test
    /// files the limits left out or cut short while a name was still
    /// missing. The test files are those of the worktree, untracked ones
    /// included, Swift files first. Nil when git can't list them.
    static func mentions(
        of names: Set<String>, root: String, options: Options,
        maxFiles: Int = maxTestFiles, maxFileBytes: Int = maxTestFileBytes, maxBytes: Int = maxTestBytes
    ) -> (found: Set<String>, unread: Int)? {
        guard let listed = git(
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"] + testPathspecs,
            in: root, options: options, environment: ["GIT_LITERAL_PATHSPECS": "0"], maxOutputBytes: 16 << 20
        ), listed.status == 0 else { return nil }
        // An unmerged path is listed once per stage.
        let paths = Set(listed.stdout.split(separator: 0).map(Patch.decoded))
            .filter { PathGroup(path: $0) == .tests }
            .sorted { ($0.hasSuffix(".swift") ? 0 : 1, $0) < ($1.hasSuffix(".swift") ? 0 : 1, $1) }
        var missing = WordSet(names)
        var unread = 0
        var read = 0
        var budget = maxBytes
        for path in paths where !missing.isEmpty {
            let limit = min(maxFileBytes, budget)
            guard read < maxFiles, limit > 0 else {
                unread += 1
                continue
            }
            // Gone from the worktree, a symlink or a submodule: not a file
            // at the head.
            guard var data = readPrefix(of: root + "/" + path, maxBytes: limit + 1) else { continue }
            read += 1
            if data.count > limit {
                unread += 1
                // The word the limit cuts would read as a shorter one.
                data = data.prefix(limit)
                while let last = data.last, RiskRules.isIdentifier(last) { data.removeLast() }
            }
            budget -= data.count
            missing.removeWords(in: data)
        }
        return (names.subtracting(missing.names), unread)
    }

    /// Names looked for as whole words, by length: reading a file then
    /// allocates nothing.
    struct WordSet {
        private var byLength: [Int: [[UInt8]]] = [:]

        init(_ names: Set<String>) {
            for name in names { byLength[name.utf8.count, default: []].append(Array(name.utf8)) }
        }

        var isEmpty: Bool { byLength.isEmpty }
        var names: Set<String> { Set(byLength.values.joined().map { String(decoding: $0, as: UTF8.self) }) }

        /// Removes each name `text` holds as a whole word: not inside a
        /// longer identifier ("Codable" isn't in "MyCodableBox").
        mutating func removeWords(in text: Data) {
            text.withUnsafeBytes { bytes in
                var start = 0
                while start < bytes.count, !byLength.isEmpty {
                    guard RiskRules.isIdentifier(bytes[start]) else {
                        start += 1
                        continue
                    }
                    var end = start + 1
                    while end < bytes.count, RiskRules.isIdentifier(bytes[end]) { end += 1 }
                    let word = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
                    if var candidates = byLength[word.count],
                       let found = candidates.firstIndex(where: { $0.elementsEqual(word) }) {
                        candidates.remove(at: found)
                        byLength[word.count] = candidates.isEmpty ? nil : candidates
                    }
                    start = end
                }
            }
        }
    }
}

// MARK: - Added lines

extension BranchReview {
    /// The new side's numbers of a section's `+` lines, as ranges, and a
    /// digest of their bytes: the file at the head is checked against it
    /// before its declarations are read.
    struct AddedLines: Equatable, Sendable {
        var ranges: [Range<Int>] = []
        var digest = Data()
    }

    /// Collects `AddedLines` while a section is parsed, its memory
    /// bounded: past `maxRanges` runs of added lines, it gives up.
    struct AddedLineCollector {
        private let maxRanges: Int
        private var ranges: [Range<Int>] = []
        private var digest = LineDigest()
        private var overflowed = false

        init(maxRanges: Int = 100_000) {
            self.maxRanges = maxRanges
        }

        mutating func add(_ number: Int, _ content: Data) {
            guard !overflowed else { return }
            if let last = ranges.last, last.upperBound == number {
                ranges[ranges.count - 1] = last.lowerBound..<(number + 1)
            } else if ranges.count < maxRanges {
                ranges.append(number..<(number + 1))
            } else {
                overflowed = true
                return
            }
            content.withUnsafeBytes { digest.add($0) }
        }

        func finalize() -> AddedLines? {
            overflowed ? nil : AddedLines(ranges: ranges, digest: digest.finalize())
        }
    }

    /// Hashes lines without their final carriage return: on disk, a file
    /// may have the CRLF endings its attributes convert in the patch.
    struct LineDigest {
        private var hasher = SHA256()

        mutating func add(_ line: UnsafeRawBufferPointer) {
            var kept = line
            if kept.last == 0x0D { kept = UnsafeRawBufferPointer(rebasing: kept.dropLast()) }
            hasher.update(bufferPointer: kept)
            hasher.update(data: Data([UInt8(ascii: "\n")]))
        }

        func finalize() -> Data { Data(hasher.finalize()) }
    }
}

import CryptoKit
import Darwin
import Foundation

// MARK: - Tests against code (section 5)

extension BranchReview {
    /// An identifier a Swift file declares (see `SwiftScanner`).
    struct Symbol: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A class, struct, enum, protocol or actor.
            case type
            case function
            case variable
            case enumCase
            case typeAlias
        }

        let name: String
        /// 1-based, in the file as the worktree has it.
        let line: Int
        let kind: Kind
        /// The type it is a member of, or that its extension extends, as a
        /// dotted path (`Outer.Inner`); nil at the file's level.
        let container: String?
    }

    /// What a Swift code file declares on its added lines.
    enum SymbolScan: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            /// Its patch wasn't read (`Omission.notRead`).
            case patchNotRead
            /// Past `Options.maxScannedFileBytes`, or the rest of
            /// `maxScannedBytes`, or past 100,000 runs of added lines.
            case tooLarge
            /// The file no longer matches its patch: the agent edited it
            /// meanwhile. The next refresh reads it again.
            case changedSincePatch
            /// A brace, a multi-line string or a comment doesn't close:
            /// what follows it may have read wrong.
            case unbalanced
        }

        /// Each name once, at its first line.
        case read([Symbol])
        /// Unknown, and why.
        case unread(Reason)
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
        /// Added lines of the Code group's files, and of the scripts the
        /// Config group holds, folded files aside.
        var codeLines = 0
        /// The symbols the Swift code files declare, each name once per
        /// file.
        var declared = 0
        /// Those no test mentions, in the files' order, then by line.
        var unmentioned: [Unmentioned] = []
        /// Swift code files whose symbols are unknown (`SymbolScan.unread`),
        /// in the files' order.
        var unscannedFiles: [String] = []
        /// Test files left out, cut short or unreadable (a symlink, outside
        /// a sparse checkout) while a symbol was still unmentioned: it may
        /// be mentioned there. A binary fixture or a submodule isn't a
        /// test's text, and isn't counted.
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
    /// not folded. Those that add lines do (a deletion adds none); a file
    /// whose lines weren't read is then `SymbolScan.unread`.
    static func mayDeclareSymbols(_ file: FileChange) -> Bool {
        isSwiftCode(file.path) && file.fold == nil
    }

    /// `symbols` for a file listed without its patch; an untracked one
    /// has no line count.
    static func unreadSymbols(of file: FileChange) -> SymbolScan? {
        mayDeclareSymbols(file) && (file.additions > 0 || file.isUntracked) ? .unread(.patchNotRead) : nil
    }

    /// The symbols declared on `added` lines of the file at `path`, as it
    /// is on disk, but those its removed lines declared already (a value,
    /// a conformance or a visibility changed). Nil for a symlink, which
    /// declares nothing.
    static func scanSymbols(at path: String, added: AddedLines?, maxFileBytes: Int, budget: inout Int) -> SymbolScan? {
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return nil }
        let limit = min(maxFileBytes, budget)
        guard let added else { return .unread(.tooLarge) }
        guard let head = readPrefix(of: path, maxBytes: limit + 1) else { return .unread(.changedSincePatch) }
        guard head.count <= limit else { return .unread(.tooLarge) }
        budget -= head.count
        var scanner = SwiftScanner()
        var digest = LineDigest()
        var ranges = added.ranges[...]
        var number = 0
        forEachLine(of: head) { line in
            number += 1
            while let first = ranges.first, first.upperBound <= number { ranges.removeFirst() }
            let isAdded = ranges.first?.contains(number) == true
            if isAdded { digest.add(line) }
            scanner.feed(line, collecting: isAdded)
        }
        guard digest.finalize() == added.digest else { return .unread(.changedSincePatch) }
        guard scanner.isBalanced else { return .unread(.unbalanced) }
        var seen = added.removedNames
        return .read(scanner.symbols.filter { seen.insert($0.name).inserted })
    }

    /// Calls `body` with each line of `text`, without its newline.
    static func forEachLine(of text: Data, _ body: (UnsafeRawBufferPointer) -> Void) {
        text.withUnsafeBytes { bytes in
            var start = 0
            while start < bytes.count {
                let end = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
                body(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
                start = end + 1
            }
        }
    }

    /// The test and code lines, and the symbols no test mentions, of
    /// `files` as the snapshot read them (by path). `deleted`: the paths
    /// the worktree deleted, which aren't tests any more.
    static func testsAgainstCode(
        of files: [FileChange], root: String, deleted: Set<String>, options: Options
    ) -> TestsAgainstCode {
        var result = TestsAgainstCode()
        var declared: [TestsAgainstCode.Unmentioned] = []
        for file in files where file.fold == nil {
            switch PathGroup(path: file.path) {
            case .tests: result.testLines += file.additions
            case .code: result.codeLines += file.additions
            // A script is code its tests test.
            case .config where PathGroup.isInFolder("scripts", file.path): result.codeLines += file.additions
            default: break
            }
            switch file.symbols {
            case .read(let symbols)?: declared += symbols.map { TestsAgainstCode.Unmentioned(path: file.path, symbol: $0) }
            case .unread?: result.unscannedFiles.append(file.path)
            case nil: break
            }
        }
        result.declared = declared.count
        guard !declared.isEmpty else { return result }
        let mentions = mentions(of: Set(declared.map(\.symbol.name)), root: root, deleted: deleted, options: options)
        result.testFilesUnlisted = mentions == nil
        result.unreadTestFiles = mentions?.unread ?? 0
        var mentioned = declared.map { mentions?.found.contains($0.symbol.name) == true }
        // Tests name a type through its members: `.notRead` rather than
        // `Omission.notRead`. A type counts once a member the branch
        // declares in the same file does, nested types included.
        func key(_ path: String, _ type: String) -> String { path + "\0" + type }
        var mentionedContainers = Set(declared.indices.filter { mentioned[$0] }.compactMap { member in
            declared[member].symbol.container.map { key(declared[member].path, $0) }
        })
        var grew = true
        while grew {
            grew = false
            for index in declared.indices where !mentioned[index] {
                let symbol = declared[index].symbol
                let typePath = (symbol.container.map { $0 + "." } ?? "") + symbol.name
                guard mentionedContainers.contains(key(declared[index].path, typePath)) else { continue }
                mentioned[index] = true
                grew = true
                if let container = declared[index].symbol.container {
                    mentionedContainers.insert(key(declared[index].path, container))
                }
            }
        }
        result.unmentioned = declared.indices.filter { !mentioned[$0] }.map { declared[$0] }
        return result
    }

    // MARK: Mentions

    /// `PathGroup`'s rules for a test, as pathspecs.
    private static let testPathspecs = [
        ":(glob)**/*Tests/**", ":(glob)**/*Tests.swift", ":(glob)**/*_test.*", ":(glob)**/*.test.*", ":(glob)**/*.spec.*"
    ]

    struct Mentions: Equatable {
        /// The names some test file holds as a whole word.
        var found: Set<String>
        /// Test files the limits (`Options`) left out, cut short or
        /// couldn't read while a name was still missing.
        var unread: Int
    }

    /// The mentions of `names` in the worktree's test files, untracked ones
    /// included, Swift files first; in those, only code counts: a name in
    /// a comment or a string isn't a mention. Nil when git can't list them.
    static func mentions(of names: Set<String>, root: String, deleted: Set<String> = [], options: Options) -> Mentions? {
        guard let listed = git(
            ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"] + testPathspecs,
            in: root, options: options, environment: ["GIT_LITERAL_PATHSPECS": "0"], maxOutputBytes: 16 << 20
        ), listed.status == 0 else { return nil }
        let paths = listed.stdout.split(separator: 0).map(Patch.decoded)
            .sorted { ($0.hasSuffix(".swift") ? 0 : 1, $0) < ($1.hasSuffix(".swift") ? 0 : 1, $1) }
        var missing = WordSet(names)
        var unread = 0
        var read = 0
        var budget = options.maxTestBytesRead
        for path in paths where !missing.isEmpty {
            let limit = min(options.maxTestFileBytes, budget)
            // Past the budget, no file is opened at all.
            guard read < options.maxTestFilesRead, limit > 0 else {
                unread += 1
                continue
            }
            var info = stat()
            let isFolder = lstat(root + "/" + path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            // Git's test for binary: a NUL in the first 8,000 bytes. A
            // snapshot image or a fixture isn't a test's text, nor is a
            // submodule's folder.
            if isFolder || readPrefix(of: root + "/" + path, maxBytes: 8_000)?.contains(0) == true { continue }
            guard var data = readPrefix(of: root + "/" + path, maxBytes: limit + 1) else {
                // A symlink, a file outside a sparse checkout; one the
                // worktree deleted is no test.
                if !deleted.contains(path) { unread += 1 }
                continue
            }
            read += 1
            if data.count > limit {
                unread += 1
                // The word the limit cuts would read as a shorter one.
                data = data.prefix(limit)
                while let last = data.last, RiskRules.isIdentifier(last) { data.removeLast() }
            }
            budget -= data.count
            if path.hasSuffix(".swift") {
                var lexer = SwiftScanner()
                lexer.words = missing
                forEachLine(of: data) { lexer.feed($0, collecting: false) }
                missing = lexer.words ?? missing
            } else {
                missing.removeWords(in: data)
            }
        }
        return Mentions(found: names.subtracting(missing.names), unread: unread)
    }

    /// Names looked for as whole words, by a hash of their bytes: a word
    /// costs one lookup however many names there are, and allocates
    /// nothing.
    struct WordSet {
        private var byHash: [UInt64: [[UInt8]]] = [:]

        init(_ names: Set<String>) {
            for name in names { byHash[Self.hash(name.utf8), default: []].append(Array(name.utf8)) }
        }

        var isEmpty: Bool { byHash.isEmpty }
        var names: Set<String> { Set(byHash.values.joined().map { String(decoding: $0, as: UTF8.self) }) }

        /// Removes `word` if it is one of the names.
        mutating func remove(_ word: UnsafeRawBufferPointer) {
            let key = Self.hash(word)
            guard var candidates = byHash[key], let found = candidates.firstIndex(where: { $0.elementsEqual(word) })
            else { return }
            candidates.remove(at: found)
            byHash[key] = candidates.isEmpty ? nil : candidates
        }

        /// Removes each name `text` holds as a whole word: not inside a
        /// longer identifier ("Codable" isn't in "MyCodableBox").
        mutating func removeWords(in text: Data) {
            text.withUnsafeBytes { bytes in
                var start = 0
                while start < bytes.count, !isEmpty {
                    guard RiskRules.isIdentifier(bytes[start]) else {
                        start += 1
                        continue
                    }
                    var end = start + 1
                    while end < bytes.count, RiskRules.isIdentifier(bytes[end]) { end += 1 }
                    remove(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
                    start = end
                }
            }
        }

        /// FNV-1a.
        private static func hash(_ bytes: some Sequence<UInt8>) -> UInt64 {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            return hash
        }
    }
}

// MARK: - Added lines

extension BranchReview {
    /// What the first pass keeps of a Swift file's patch: the new side's
    /// numbers of its `+` lines, as ranges, and a digest of their bytes,
    /// which the file at the head is checked against; and the names its
    /// `-` lines declare, which aren't new.
    struct AddedLines: Equatable, Sendable {
        var ranges: [Range<Int>] = []
        var digest = Data()
        var removedNames: Set<String> = []
    }

    /// Collects `AddedLines` while a section is parsed, its memory
    /// bounded: past `maxRanges` runs of added lines, it gives up.
    struct AddedLineCollector {
        private let maxRanges: Int
        private var ranges: [Range<Int>] = []
        private var digest = LineDigest()
        private var removedNames: Set<String> = []
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

        /// A removed line, read alone: whatever it declares, at any depth
        /// and whatever its visibility, was there before the branch.
        mutating func addRemoved(_ content: Data) {
            var scanner = SwiftScanner()
            content.withUnsafeBytes { scanner.feed($0, collecting: true) }
            removedNames.formUnion(scanner.declarations.map(\.symbol.name))
        }

        func finalize() -> AddedLines? {
            overflowed ? nil : AddedLines(ranges: ranges, digest: digest.finalize(), removedNames: removedNames)
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

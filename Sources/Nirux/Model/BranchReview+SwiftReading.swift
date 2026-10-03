import Darwin
import Foundation

// MARK: - Swift files read in context (sections 2 and 5)

extension BranchReview {
    /// What a Swift file's patch says once both its sides are read in
    /// context: the old one through its removed lines and the lines both
    /// share, the new one through the file in the worktree. The first pass
    /// reads each line alone; this one knows which lines are in a
    /// multi-line string, in a comment, or in which function.
    struct SwiftReading: Equatable {
        /// The line rules its `+` and `-` lines match outside comments, by
        /// hunk index.
        var riskHits: Set<RiskHit> = []
        /// The `lifecycleFunctions` its changed lines are in, by hunk index.
        var lifecycleHunks: [String: Set<Int>] = [:]
        /// Each hunk reads the same before and after but for whitespace, a
        /// multi-line string's text kept whole (see `WhitespaceCheck`).
        var isWhitespaceOnly = false
        /// What its added lines declare outside function bodies, but the
        /// names its removed lines declared: a changed value, conformance,
        /// signature or visibility re-declares them. Each name once per
        /// type.
        var symbols: [Symbol] = []
    }

    /// A change inside one of these raises "launch" without naming it: the
    /// app delegate's launch and quit, and an `@main` type's entry point,
    /// `static func main` (decided by the user on 2026-10-03).
    static let lifecycleFunctions: Set<String> = [
        "applicationWillFinishLaunching", "applicationDidFinishLaunching", "applicationShouldTerminate",
        "applicationWillTerminate"
    ]

    static func isLifecycle(_ function: SwiftScanner.Function) -> Bool {
        lifecycleFunctions.contains(function.name) || (function.name == "main" && function.isStatic)
    }

    /// Reads `section`, one file's patch, against `head`, the file in the
    /// worktree; nil when the patch holds the whole file (an addition or a
    /// deletion). Fails when `head` no longer matches the patch, or when a
    /// brace, a multi-line string or a comment doesn't close on either
    /// side: what follows it would read wrong.
    static func readSwift(_ section: Data, head: Data?) -> Result<SwiftReading, SymbolScan.Reason> {
        guard let parsed = Patch.section(section, reading: Patch.Reading(keepsLines: true, whitespace: nil, findsRisks: false))
        else { return .failure(.changedSincePatch) }
        var walk = SideBySide(head: head)
        for (index, hunk) in parsed.hunks.enumerated() {
            // The lines both sides share before it; `+0,0` starts after its
            // line.
            guard walk.share(upTo: hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1) else {
                return .failure(.changedSincePatch)
            }
            for line in hunk.lines where line.kind != .noNewlineMarker {
                guard walk.take(line, in: index) else { return .failure(.changedSincePatch) }
            }
            walk.whitespace.endHunk()
        }
        _ = walk.share(upTo: walk.shared?.count ?? 0)
        guard walk.old.isBalanced, walk.new.isBalanced else { return .failure(.unbalanced) }
        var reading = walk.reading
        reading.isWhitespaceOnly = parsed.hunkCount > 0 && walk.whitespace.isWhitespaceOnly
        let removed = Set(walk.old.declarations.filter(\.isCollected).map(\.symbol.name))
        var seen: Set<String> = []
        reading.symbols = walk.new.symbols.filter { symbol in
            !removed.contains(symbol.name) && seen.insert((symbol.container ?? "") + "\0" + symbol.name).inserted
        }
        return .success(reading)
    }

    /// A patch's two sides, each through its scanner, line by line.
    private struct SideBySide {
        var old = SwiftScanner()
        var new = SwiftScanner()
        var reading = SwiftReading()
        var whitespace = WhitespaceCheck(mode: .ignoringIndentation)
        /// The file in the worktree, by line; nil when the patch holds it
        /// whole.
        let shared: [Data.SubSequence]?
        /// The next of its lines to read.
        private var next = 0

        init(head: Data?) {
            shared = head.map { head in
                var lines = head.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                if head.last == UInt8(ascii: "\n") { lines.removeLast() }
                return lines
            }
        }

        /// Feeds both sides the lines they share up to `end`, a line index;
        /// false when the file is too short for it.
        mutating func share(upTo end: Int) -> Bool {
            guard let shared else { return true }
            guard end >= next, end <= shared.count else { return false }
            while next < end {
                Array(shared[next]).withUnsafeBytes { bytes in
                    old.feed(bytes, collecting: false)
                    new.feed(bytes, collecting: false)
                }
                next += 1
            }
            return true
        }

        /// One of the hunk's lines; false when the file no longer has it.
        mutating func take(_ line: Line, in hunk: Int) -> Bool {
            let content = line.bytes ?? Data(line.text.utf8)
            switch line.kind {
            case .context:
                guard matches(content) else { return false }
                whitespace.add(.context, content, keepingOld: old.startsInStringText, keepingNew: new.startsInStringText)
                content.withUnsafeBytes { bytes in
                    old.feed(bytes, collecting: false)
                    new.feed(bytes, collecting: false)
                }
            case .added:
                guard matches(content) else { return false }
                whitespace.add(.added, content, keepingNew: new.startsInStringText)
                BranchReview.read(content, as: hunk, by: &new, into: &reading)
            case .removed:
                whitespace.add(.removed, content, keepingOld: old.startsInStringText)
                BranchReview.read(content, as: hunk, by: &old, into: &reading)
            case .noNewlineMarker:
                break
            }
            return true
        }

        /// Whether the file's next line is `content`, but for a final
        /// carriage return its attributes may convert.
        private mutating func matches(_ content: Data) -> Bool {
            guard let shared else { return true }
            guard next < shared.count else { return false }
            defer { next += 1 }
            return BranchReview.withoutCarriageReturn(shared[next]).elementsEqual(BranchReview.withoutCarriageReturn(content))
        }
    }

    /// A changed line, read by its side's scanner: the functions it is
    /// in, then the line rules its code matches.
    private static func read(_ content: Data, as hunk: Int, by scanner: inout SwiftScanner, into reading: inout SwiftReading) {
        for function in scanner.enclosingFunctions where isLifecycle(function) {
            reading.lifecycleHunks[function.name, default: []].insert(hunk)
        }
        content.withUnsafeBytes { scanner.feed($0, collecting: true, capturingCode: true) }
        RiskRules.forEachLineRule(matching: scanner.code) { reading.riskHits.insert(RiskHit(rule: $0, hunk: hunk)) }
    }

    private static func withoutCarriageReturn(_ line: some DataProtocol) -> Data {
        var kept = Data(line)
        if kept.last == 0x0D { kept.removeLast() }
        return kept
    }

    /// Reads each Swift file of `files` in context (`readSwift`): its line
    /// signals, whitespace fold and symbols then come from that reading.
    /// A file it can't read keeps the first pass's, and its symbols are
    /// unknown. `sections` are the file's in the patch; `namedFolds`, the
    /// files folded by name, which aren't read.
    static func readSwiftFiles(
        _ files: inout [FileChange], sections: [String: [Data]], namedFolds: [String: Fold], root: String, options: Options
    ) {
        var budget = options.maxScannedBytes
        for index in files.indices {
            let file = files[index]
            let wantsSymbols = mayDeclareSymbols(file) && file.additions > 0
            guard file.path.hasSuffix(".swift"), namedFolds[file.path] == nil, file.additions + file.deletions > 0,
                  let parts = sections[file.path], file.newMode != "120000"
            else { continue }
            // A type change: the added side holds the new file whole.
            let whole = parts.count > 1 || file.status == .added || file.status == .deleted
            guard let section = parts.last else { continue }
            let outcome: Result<SwiftReading, SymbolScan.Reason>
            switch whole ? .success(nil) : head(at: root + "/" + file.path, options: options, budget: &budget) {
            case .success(let head):
                if head == nil, section.count > min(options.maxScannedFileBytes, budget) {
                    outcome = .failure(.tooLarge)
                } else {
                    if head == nil { budget -= section.count }
                    outcome = readSwift(section, head: head)
                }
            case .failure(.symlink):
                // A link declares nothing.
                continue
            case .failure(.unread(let reason)):
                outcome = .failure(reason)
            }
            switch outcome {
            case .success(let reading):
                if PathGroup(path: file.path) != .docs {
                    files[index].signals = merged(RiskRules.signals(lineHits: Array(reading.riskHits)) + reading.lifecycleHunks.map {
                        RiskSignal(kind: .launch, reasons: ["inside \($0.key)"], hunks: $0.value.sorted(), byPath: false)
                    })
                }
                if file.fold == .whitespaceOnly, !reading.isWhitespaceOnly { files[index].fold = nil }
                if wantsSymbols { files[index].symbols = .read(reading.symbols) }
            case .failure(let reason):
                if wantsSymbols { files[index].symbols = .unread(reason) }
            }
        }
    }

    private enum HeadFailure: Error {
        case symlink
        case unread(SymbolScan.Reason)
    }

    /// The file in the worktree, within `Options.maxScannedFileBytes` and
    /// the rest of `budget`.
    private static func head(at path: String, options: Options, budget: inout Int) -> Result<Data?, HeadFailure> {
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return .failure(.symlink) }
        let limit = min(options.maxScannedFileBytes, budget)
        guard let head = readPrefix(of: path, maxBytes: limit + 1) else { return .failure(.unread(.changedSincePatch)) }
        guard head.count <= limit else { return .failure(.unread(.tooLarge)) }
        budget -= head.count
        return .success(head)
    }
}

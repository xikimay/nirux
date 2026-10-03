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
        /// The lifecycle functions (`isLifecycle`) its changed lines are
        /// in, by hunk index. A line of comments or blanks changes nothing.
        var lifecycleHunks: [String: Set<Int>] = [:]
        /// Each hunk reads the same before and after but for whitespace, a
        /// multi-line string's text read as Swift reads it (see
        /// `stringLine`).
        var isWhitespaceOnly = false
        /// What its added lines declare outside function bodies, but the
        /// names its removed lines declared: a changed value, conformance,
        /// signature or visibility re-declares them. Each name once per
        /// type.
        var symbols: [Symbol] = []
    }

    /// A change inside one of these raises "launch" without naming it: the
    /// app delegate's launch and quit, and an `@main` type's entry point
    /// (decided by the user on 2026-10-03).
    static let lifecycleFunctions: Set<String> = [
        "applicationWillFinishLaunching", "applicationDidFinishLaunching", "applicationShouldTerminate",
        "applicationWillTerminate"
    ]

    static func isLifecycle(_ function: SwiftScanner.Function) -> Bool {
        lifecycleFunctions.contains(function.name) || function.isEntryPoint
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
            walk.seen.append([])
            for line in hunk.lines where line.kind != .noNewlineMarker {
                guard walk.take(line, in: index) else { return .failure(.changedSincePatch) }
            }
        }
        _ = walk.share(upTo: walk.shared?.count ?? 0)
        guard walk.old.isBalanced, walk.new.isBalanced else { return .failure(.unbalanced) }
        var reading = walk.reading
        reading.isWhitespaceOnly = walk.isWhitespaceOnly
        let removed = Set(walk.old.declarations.filter(\.isCollected).map(\.symbol.name))
        var seen: Set<String> = []
        reading.symbols = walk.new.symbols.filter { symbol in
            !removed.contains(symbol.name) && seen.insert((symbol.container ?? "") + "\0" + symbol.name).inserted
        }
        return .success(reading)
    }

    /// A patch's two sides, each through its scanner, line by line.
    private struct SideBySide {
        /// A hunk's line, and where it is in a multi-line string on each
        /// side.
        struct Seen {
            let kind: Line.Kind
            let content: Data
            let old: Text
            let new: Text
        }

        /// The string whose text a line starts in, and whether it ends in a
        /// string's text (an interpolation may span lines between).
        struct Text {
            var startsIn: Int?
            var endsInText = false

            var isCode: Bool { startsIn == nil && !endsInText }
        }

        var old = SwiftScanner()
        var new = SwiftScanner()
        var reading = SwiftReading()
        /// By hunk: compared once every string's indentation is known.
        var seen: [[Seen]] = []
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
            guard end <= shared.count else { return false }
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
            var (oldText, newText) = (Text(startsIn: old.stringText), Text(startsIn: new.stringText))
            switch line.kind {
            case .context:
                guard matches(content) else { return false }
                content.withUnsafeBytes { bytes in
                    old.feed(bytes, collecting: false)
                    new.feed(bytes, collecting: false)
                }
            case .added:
                guard matches(content) else { return false }
                BranchReview.read(content, as: hunk, by: &new, into: &reading)
            case .removed:
                BranchReview.read(content, as: hunk, by: &old, into: &reading)
            case .noNewlineMarker:
                return true
            }
            oldText.endsInText = old.stringText != nil
            newText.endsInText = new.stringText != nil
            seen[seen.count - 1].append(Seen(kind: line.kind, content: content, old: oldText, new: newText))
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

        /// Each hunk reads the same before and after but for whitespace:
        /// a string's text as Swift reads it, the rest as code.
        var isWhitespaceOnly: Bool {
            var check = WhitespaceCheck(mode: .ignoringIndentation)
            for hunk in seen {
                for line in hunk {
                    let before = line.kind == .added ? nil : BranchReview.side(line.content, line.old, indents: old.stringIndents)
                    let after = line.kind == .removed ? nil : BranchReview.side(line.content, line.new, indents: new.stringIndents)
                    check.add(before: before, after: after)
                }
                check.endHunk()
            }
            return check.isWhitespaceOnly
        }
    }

    /// A line as one side compares it: code by its significant part, a
    /// line in a multi-line string as Swift reads it. Text a line starts
    /// in loses only the closing delimiter's indentation (a line of
    /// blanks reads as empty); text it ends in keeps its trailing spaces;
    /// its line ending is a newline.
    private static func side(_ content: Data, _ text: SideBySide.Text, indents: [Int: Data]) -> (content: Data, whole: Bool) {
        guard !text.isCode else { return (content, false) }
        var line = withoutCarriageReturn(content)
        if let id = text.startsIn {
            if let indent = indents[id], line.starts(with: indent) {
                line = line.dropFirst(indent.count)
            } else if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                line = Data()
            }
        } else {
            line = Data(line.drop { $0 == 0x20 || $0 == 0x09 })
        }
        if !text.endsInText {
            while let last = line.last, [0x20, 0x09, 0x0B, 0x0C].contains(last) { line.removeLast() }
        }
        return (line, true)
    }

    /// A changed line, read by its side's scanner: the functions it is in,
    /// unless it holds only comments and blanks, and the line rules its
    /// code matches. Its comments are blanked already: a string's line
    /// that reads like one still counts.
    private static func read(_ content: Data, as hunk: Int, by scanner: inout SwiftScanner, into reading: inout SwiftReading) {
        let functions = scanner.enclosingFunctions.filter(isLifecycle)
        let isText = scanner.stringText != nil
        content.withUnsafeBytes { scanner.feed($0, collecting: true, capturingCode: true) }
        if isText || scanner.code.contains(where: { ![0x20, 0x09, 0x0D].contains($0) }) {
            for function in functions { reading.lifecycleHunks[function.name, default: []].insert(hunk) }
        }
        RiskRules.forEachLineRule(matching: scanner.code, skippingCommentLines: false) {
            reading.riskHits.insert(RiskHit(rule: $0, hunk: hunk))
        }
    }

    private static func withoutCarriageReturn(_ line: some DataProtocol) -> Data {
        var kept = Data(line)
        if kept.last == 0x0D { kept.removeLast() }
        return kept
    }

    /// Reads each Swift file of `files` in context (`readSwift`), those
    /// that may declare symbols first, within `Options.maxScannedBytes`:
    /// its line signals, whitespace fold and symbols then come from that
    /// reading. A file it can't read keeps the first pass's, and its
    /// symbols are unknown. A type change (a symlink became the file) only
    /// gives its symbols: the reading doesn't number its first section's
    /// hunks. `sections` are each file's in the patch; `namedFolds`, the
    /// files folded by name, which aren't read.
    static func readSwiftFiles(
        _ files: inout [FileChange], sections: [String: [Data]], namedFolds: [String: Fold], root: String, options: Options
    ) {
        func wantsSymbols(_ file: FileChange) -> Bool { mayDeclareSymbols(file) && file.additions > 0 }
        var budget = options.maxScannedBytes
        let order = files.indices.filter { wantsSymbols(files[$0]) } + files.indices.filter { !wantsSymbols(files[$0]) }
        for index in order {
            let file = files[index]
            // A link (added, or modified as its `index` line says) declares
            // nothing.
            guard file.path.hasSuffix(".swift"), namedFolds[file.path] == nil, file.additions + file.deletions > 0,
                  file.newMode != "120000", let parts = sections[file.path], let section = parts.last,
                  Patch.header(section)?.indexMode != "120000"
            else { continue }
            let whole = file.status == .added || file.status == .deleted
            switch read(file, section: section, whole: whole, root: root, options: options, budget: &budget) {
            case .success(let reading):
                if parts.count == 1 {
                    if PathGroup(path: file.path) != .docs {
                        files[index].signals = merged(RiskRules.signals(lineHits: Array(reading.riskHits)) + reading.lifecycleHunks.map {
                            RiskSignal(kind: .launch, reasons: ["inside \($0.key)"], hunks: $0.value.sorted(), byPath: false)
                        })
                    }
                    // Stricter than the first pass's: it may only unfold.
                    if !reading.isWhitespaceOnly { files[index].fold = nil }
                }
                if wantsSymbols(files[index]) { files[index].symbols = .read(reading.symbols) }
            case .failure(let reason):
                files[index].unreadContext = reason
                if wantsSymbols(file) { files[index].symbols = .unread(reason) }
            }
        }
    }

    /// One file's `readSwift`: its patch within `Options.maxScannedFileBytes`
    /// (a huge removal is never read again line by line), and the file in
    /// the worktree, unless the patch holds it `whole`; what is read counts
    /// toward `budget`.
    private static func read(
        _ file: FileChange, section: Data, whole: Bool, root: String, options: Options, budget: inout Int
    ) -> Result<SwiftReading, SymbolScan.Reason> {
        let limit = min(options.maxScannedFileBytes, budget)
        guard section.count <= (whole ? limit : options.maxScannedFileBytes) else { return .failure(.tooLarge) }
        guard !whole else {
            budget -= section.count
            return readSwift(section, head: nil)
        }
        // Not read through a link: the patch shows a file.
        guard let head = readPrefix(of: root + "/" + file.path, maxBytes: limit + 1) else { return .failure(.changedSincePatch) }
        guard head.count <= limit else { return .failure(.tooLarge) }
        budget -= head.count
        return readSwift(section, head: head)
    }
}

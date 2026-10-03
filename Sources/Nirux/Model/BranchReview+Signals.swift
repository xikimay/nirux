import Darwin
import Foundation

// MARK: - Risk signals (section 5)

extension BranchReview {
    /// A line rule, by its index in `RiskRules.lineRules`, matched in a
    /// hunk.
    struct RiskHit: Hashable, Sendable {
        let rule: Int
        let hunk: Int
    }

    /// Deterministic rules on the paths and on the `+` and `-` lines, built
    /// in for Swift and macOS. A line rule matches anywhere in the line,
    /// comments and strings included.
    enum RiskRules {
        struct LineRule {
            let kind: RiskKind
            let label: String
            let patterns: [(bytes: [UInt8], set: ByteSet)]
            /// Whether a pattern that starts with a letter, a digit or "_"
            /// may follow one, and likewise at its end: "Codable" isn't
            /// found in "MyCodableBox", "SecItem" is in "SecItemAdd".
            let boundary: Boundary

            init(_ kind: RiskKind, _ label: String, _ patterns: [String]? = nil, _ boundary: Boundary = .word) {
                self.kind = kind
                self.label = label
                self.patterns = (patterns ?? [label]).map { (Array($0.utf8), ByteSet($0.utf8)) }
                self.boundary = boundary
            }
        }

        /// The byte values a line or a pattern holds: a pattern can't be
        /// in a line that lacks one of its bytes, which spares most
        /// searches.
        struct ByteSet {
            private var low: UInt64 = 0
            private var high: UInt64 = 0
            private var lowExtended: UInt64 = 0
            private var highExtended: UInt64 = 0

            init(_ bytes: some Sequence<UInt8>) {
                for byte in bytes {
                    let bit = UInt64(1) << UInt64(byte & 63)
                    switch byte >> 6 {
                    case 0: low |= bit
                    case 1: high |= bit
                    case 2: lowExtended |= bit
                    default: highExtended |= bit
                    }
                }
            }

            func isSubset(of other: ByteSet) -> Bool {
                low & ~other.low == 0 && high & ~other.high == 0
                    && lowExtended & ~other.lowExtended == 0 && highExtended & ~other.highExtended == 0
            }
        }

        enum Boundary {
            /// Not inside a longer identifier.
            case word
            /// Not after an identifier's start; anything may follow.
            case prefix
        }

        static let lineRules: [LineRule] = [
            LineRule(.persistence, "Codable"),
            LineRule(.persistence, "Decodable"),
            LineRule(.persistence, "Encodable"),
            LineRule(.persistence, "CodingKeys"),
            LineRule(.persistence, "decodeIfPresent"),
            LineRule(.persistence, "state.json"),
            LineRule(.persistence, "board.json"),

            LineRule(.security, "SecItem", nil, .prefix),
            LineRule(.security, "SecCode", nil, .prefix),
            LineRule(.security, "SecStaticCode", nil, .prefix),
            LineRule(.security, "nirux://", nil, .prefix),
            LineRule(.security, "NiruxURLRequest"),
            LineRule(.security, "HandoverFile"),
            LineRule(.security, "Telegram", nil, .prefix),
            LineRule(.security, "/tmp"),
            LineRule(.security, "Process arguments", ["Process(", "BoundedProcess", "posix_spawn", "executableURL", ".arguments"]),

            LineRule(.concurrency, "@MainActor"),
            LineRule(.concurrency, "nonisolated"),
            LineRule(.concurrency, "@Sendable"),
            LineRule(.concurrency, "@unchecked Sendable"),
            LineRule(.concurrency, "DispatchQueue"),
            LineRule(.concurrency, "DispatchSource", nil, .prefix),
            LineRule(.concurrency, "OperationQueue"),
            LineRule(.concurrency, "Task {", ["Task {", "Task{", "Task(", "Task.detached"], .prefix),
            LineRule(.concurrency, "MainActor.assumeIsolated"),
            LineRule(.concurrency, "RunLoop.main.perform"),

            LineRule(.launch, "applicationDidFinishLaunching"),
            LineRule(.launch, "applicationWillFinishLaunching"),
            LineRule(.launch, "applicationShouldTerminate"),
            LineRule(.launch, "applicationWillTerminate"),
            LineRule(.launch, "--hook"),
            LineRule(.launch, "NIRUX_*", ["NIRUX_"], .prefix),
            LineRule(.launch, "Info.plist"),
            LineRule(.launch, "Sparkle", ["Sparkle", "SPU"], .prefix),
            LineRule(.launch, "bundle.sh"),

            LineRule(.sideEffects, "IOKit", ["IOKit", "IOPM", "IOService", "IORegistry"], .prefix),
            LineRule(.sideEffects, "NSWorkspace"),
            LineRule(.sideEffects, "~/.claude", [".claude/", "\".claude\"", "~/.claude"]),
            LineRule(.sideEffects, "hooks", ["AgentHookInstaller"], .prefix),
            LineRule(
                .sideEffects, "notifications",
                ["UNUserNotificationCenter", "NSUserNotification", "DistributedNotificationCenter", "NiruxNotifier"],
                .prefix
            ),
            LineRule(.sideEffects, "process launch", ["Process(", "BoundedProcess", "posix_spawn", "openApplication", "launchctl"])
        ]

        /// Calls `body` with the index of each line rule `content` matches.
        static func forEachLineRule(matching content: Data, _ body: (Int) -> Void) {
            content.withUnsafeBytes { line in
                let present = ByteSet(line)
                for (index, rule) in lineRules.enumerated() where rule.patterns.contains(where: {
                    $0.set.isSubset(of: present) && find($0.bytes, in: line, boundary: rule.boundary)
                }) {
                    body(index)
                }
            }
        }

        private static func find(_ pattern: [UInt8], in line: UnsafeRawBufferPointer, boundary: Boundary) -> Bool {
            guard let base = line.baseAddress, line.count >= pattern.count else { return false }
            let checksStart = isIdentifier(pattern[0])
            let checksEnd = boundary == .word && isIdentifier(pattern[pattern.count - 1])
            return pattern.withUnsafeBytes { needle in
                var offset = 0
                while offset + needle.count <= line.count,
                      let found = memmem(base + offset, line.count - offset, needle.baseAddress, needle.count) {
                    let start = base.distance(to: UnsafeRawPointer(found))
                    let end = start + needle.count
                    if !(checksStart && start > 0 && isIdentifier(line[start - 1]))
                        && !(checksEnd && end < line.count && isIdentifier(line[end])) {
                        return true
                    }
                    offset = start + 1
                }
                return false
            }
        }

        /// ASCII letters, digits and "_", and any byte of a non-ASCII
        /// character: Swift identifiers may hold them.
        static func isIdentifier(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), 0x80...:
                return true
            default:
                return false
            }
        }

        /// One signal per kind the line rules raised, with its hunks.
        static func signals(lineHits: [RiskHit]) -> [RiskSignal] {
            var signals: [RiskSignal] = []
            for hit in lineHits {
                let rule = lineRules[hit.rule]
                signals.add(RiskSignal(kind: rule.kind, reasons: [rule.label], hunks: [hit.hunk], byPath: false))
            }
            return signals
        }

        struct PathRule: Sendable {
            let kind: RiskKind
            let label: String
            let matches: @Sendable (_ path: String, _ name: String) -> Bool
        }

        /// Manifests and lockfiles: what the build resolves.
        static let dependencyFiles: Set<String> = [
            "Package.swift", "Package.resolved", "Podfile", "Podfile.lock", "package.json", "package-lock.json",
            "pnpm-lock.yaml", "yarn.lock", "Cargo.toml", "Cargo.lock", "Gemfile", "Gemfile.lock", "go.mod", "go.sum"
        ]

        static let pathRules: [PathRule] = [
            PathRule(kind: .persistence, label: "Persistence*.swift") { _, name in
                name.hasPrefix("Persistence") && name.hasSuffix(".swift")
            },
            PathRule(kind: .persistence, label: "*Store.swift") { _, name in name.hasSuffix("Store.swift") },
            PathRule(kind: .security, label: "*.entitlements") { _, name in name.hasSuffix(".entitlements") },
            PathRule(kind: .launch, label: "Info.plist") { _, name in name == "Info.plist" },
            PathRule(kind: .launch, label: "bundle.sh") { _, name in name == "bundle.sh" },
            PathRule(kind: .ci, label: ".github/") { path, _ in path.hasPrefix(".github/") },
            PathRule(kind: .dependencies, label: "dependencies") { _, name in dependencyFiles.contains(name) }
        ]

        /// The path rules a file's path, or its path before a rename,
        /// matches; the reason is the file's name for dependencies.
        static func pathSignals(path: String, oldPath: String?) -> [RiskSignal] {
            var signals: [RiskSignal] = []
            for candidate in [path] + (oldPath.map { [$0] } ?? []) {
                let name = fileName(candidate)
                for rule in pathRules where rule.matches(candidate, name) {
                    let reason = rule.kind == .dependencies ? name : rule.label
                    signals.add(RiskSignal(kind: rule.kind, reasons: [reason], hunks: [], byPath: true))
                }
            }
            return signals
        }

        /// The path rules, then what the workflows name, added to signals
        /// read from the lines. A folded file keeps no line signal: a
        /// generated file can say anything, and a reindented line changes
        /// nothing.
        static func settle(_ file: inout FileChange) {
            if file.fold != nil { file.signals = [] }
            for signal in pathSignals(path: file.path, oldPath: file.oldPath) { file.signals.add(signal) }
        }
    }

    static func fileName(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }
}

extension [BranchReview.RiskSignal] {
    /// Merges `signal` into the one of its kind, keeping kinds in
    /// `RiskKind` order and reasons and hunks sorted, each once.
    mutating func add(_ signal: BranchReview.RiskSignal) {
        guard let index = firstIndex(where: { $0.kind == signal.kind }) else {
            let order = BranchReview.RiskKind.allCases
            let position = firstIndex { order.firstIndex(of: $0.kind)! > order.firstIndex(of: signal.kind)! } ?? endIndex
            insert(
                BranchReview.RiskSignal(
                    kind: signal.kind, reasons: Set(signal.reasons).sorted(),
                    hunks: Set(signal.hunks).sorted(), byPath: signal.byPath
                ),
                at: position
            )
            return
        }
        self[index].reasons = Set(self[index].reasons + signal.reasons).sorted()
        self[index].hunks = Set(self[index].hunks + signal.hunks).sorted()
        self[index].byPath = self[index].byPath || signal.byPath
    }
}

// MARK: - Scripts the workflows call

extension BranchReview {
    /// Raises CI on a file a workflow or an action names by its path
    /// (`./scripts/bundle.sh`), as the worktree has them.
    static func addWorkflowSignals(to files: inout [FileChange], root: String) {
        let named = workflowPaths(root: root)
        guard !named.isEmpty else { return }
        for index in files.indices {
            for path in [files[index].path] + (files[index].oldPath.map { [$0] } ?? []) {
                for workflow in (named[path] ?? []).sorted() {
                    files[index].signals.add(RiskSignal(kind: .ci, reasons: ["named in \(workflow)"], hunks: [], byPath: true))
                }
            }
        }
    }

    /// Reading is bounded: a repository's `.github` holds a handful of
    /// small files, but an action may vendor its node_modules.
    private static let maxWorkflowEntries = 2_000
    private static let maxWorkflowFiles = 200
    private static let maxWorkflowFileBytes = 256 << 10

    /// Each path the regular files under `.github/workflows` and
    /// `.github/actions` name, with the files that name it.
    static func workflowPaths(root: String) -> [String: Set<String>] {
        var named: [String: Set<String>] = [:]
        var filesRead = 0
        for folder in [".github/workflows", ".github/actions"] {
            guard let walk = FileManager.default.enumerator(atPath: root + "/" + folder) else { continue }
            for case let relative as String in walk.prefix(maxWorkflowEntries) where filesRead < maxWorkflowFiles {
                // Not a regular file (a folder, a symlink): nil.
                guard let data = readPrefix(of: root + "/" + folder + "/" + relative, maxBytes: maxWorkflowFileBytes)
                else { continue }
                filesRead += 1
                for path in pathTokens(in: data) { named[path, default: []].insert(folder + "/" + relative) }
            }
        }
        return named
    }

    /// The runs of path characters in `text`, from the top level:
    /// "./scripts/x.sh" and "$GITHUB_WORKSPACE/scripts/x.sh" both name
    /// "scripts/x.sh", "my-scripts/x.sh" doesn't.
    static func pathTokens(in text: Data) -> Set<String> {
        func isPathByte(_ byte: UInt8) -> Bool {
            RiskRules.isIdentifier(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "/")
        }
        var tokens: Set<String> = []
        for run in text.split(whereSeparator: { !isPathByte($0) }) {
            var token = Substring(Patch.decoded(Data(run)))
            // "$GITHUB_WORKSPACE/scripts": the variable is the folder.
            if run.startIndex > text.startIndex, text[run.startIndex - 1] == UInt8(ascii: "$"),
               let slash = token.firstIndex(of: "/") {
                token = token[slash...]
            }
            while let rest = token.hasPrefix("./") ? token.dropFirst(2) : token.hasPrefix("/") ? token.dropFirst() : nil {
                token = rest
            }
            while token.hasSuffix(".") { token = token.dropLast() }
            if !token.isEmpty { tokens.insert(String(token)) }
        }
        return tokens
    }

    /// The first `maxBytes` of a regular file, without following a symlink
    /// or waiting on a FIFO. Nil when it can't be read.
    static func readPrefix(of path: String, maxBytes: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data(count: maxBytes)
        let count = data.withUnsafeMutableBytes { buffer in
            var total = 0
            while total < maxBytes {
                let read = Darwin.read(descriptor, buffer.baseAddress! + total, maxBytes - total)
                guard read > 0 else { return read < 0 && total == 0 ? -1 : total }
                total += read
            }
            return total
        }
        guard count >= 0 else { return nil }
        data.count = count
        return data
    }
}

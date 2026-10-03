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
    /// in for Swift and macOS. A line rule matches anywhere in a line,
    /// strings and trailing comments included, but not in a line that is
    /// only a comment.
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
            LineRule(
                .security, "Process arguments",
                [
                    "Process(", "BoundedProcess", "posix_spawn", "executableURL", ".arguments =", ".arguments=",
                    ".arguments +=", ".arguments.append"
                ]
            ),

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
            LineRule(.sideEffects, "NSWorkspace", ["NSWorkspace", "openApplication"]),
            LineRule(.sideEffects, "~/.claude", [".claude/", "\".claude\"", "~/.claude"]),
            LineRule(.sideEffects, "~/.codex", [".codex/", "\".codex\"", "~/.codex"]),
            LineRule(.sideEffects, "hooks", ["AgentHookInstaller"], .prefix),
            LineRule(
                .sideEffects, "notifications",
                ["UNUserNotificationCenter", "NSUserNotification", "DistributedNotificationCenter", "NiruxNotifier"],
                .prefix
            ),
            LineRule(.sideEffects, "launchctl")
        ]

        /// Calls `body` with the index of each line rule `content` matches.
        static func forEachLineRule(matching content: Data, _ body: (Int) -> Void) {
            content.withUnsafeBytes { line in
                guard !isCommentOnly(line) else { return }
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

        /// A line that is only a comment: `//`, `/*` or `* ` in Swift and C,
        /// `# ` in scripts and YAML. Swift's `#if` has no space, and code
        /// may follow a comment's `*/`.
        static func isCommentOnly(_ line: UnsafeRawBufferPointer) -> Bool {
            guard let start = line.firstIndex(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") })
            else { return false }
            let next = start + 1 < line.count ? line[start + 1] : nil
            switch line[start] {
            case UInt8(ascii: "/") where next == UInt8(ascii: "*"): return endsAsComment(line, from: start + 2)
            case UInt8(ascii: "*") where next == UInt8(ascii: "/"): return endsAsComment(line, from: start)
            case UInt8(ascii: "/"): return next == UInt8(ascii: "/")
            case UInt8(ascii: "*"): return next == nil || next == UInt8(ascii: " ")
            case UInt8(ascii: "#"): return next == nil || next == UInt8(ascii: " ") || next == UInt8(ascii: "\t")
            default: return false
            }
        }

        /// Whether nothing but blanks follows the first `*/` from `start`,
        /// or none closes the comment on this line.
        private static func endsAsComment(_ line: UnsafeRawBufferPointer, from start: Int) -> Bool {
            var index = start
            while index + 1 < line.count, !(line[index] == UInt8(ascii: "*") && line[index + 1] == UInt8(ascii: "/")) {
                index += 1
            }
            guard index + 1 < line.count else { return true }
            return line[(index + 2)...].allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
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
            merged(lineHits.map {
                RiskSignal(kind: lineRules[$0.rule].kind, reasons: [lineRules[$0.rule].label], hunks: [$0.hunk], byPath: false)
            })
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

        /// A change to these files' bodies may name none of the line
        /// rules: `NiruxShellView+Persistence.swift` restores the state,
        /// `HandoverFile.swift` writes files.
        static let pathRules: [PathRule] = [
            PathRule(kind: .persistence, label: "*Persistence*") { _, name in name.contains("Persistence") },
            PathRule(kind: .persistence, label: "*Store.swift") { _, name in name.hasSuffix("Store.swift") },
            PathRule(kind: .security, label: "*.entitlements") { _, name in name.hasSuffix(".entitlements") },
            PathRule(kind: .security, label: "HandoverFile*") { _, name in name.hasPrefix("HandoverFile") },
            PathRule(kind: .security, label: "NiruxURLRequest*") { _, name in name.hasPrefix("NiruxURLRequest") },
            PathRule(kind: .security, label: "*+URLScheme*") { _, name in name.contains("+URLScheme") },
            PathRule(kind: .security, label: "Telegram*") { _, name in name.hasPrefix("Telegram") },
            PathRule(kind: .launch, label: "app delegate") { _, name in name == "NiruxApp.swift" || name == "AppDelegate.swift" },
            PathRule(kind: .launch, label: "Info.plist") { _, name in name == "Info.plist" },
            PathRule(kind: .launch, label: "bundle.sh") { _, name in name == "bundle.sh" },
            PathRule(kind: .ci, label: ".github/") { path, _ in path.hasPrefix(".github/") },
            PathRule(kind: .sideEffects, label: "hooks") { _, name in
                name.hasPrefix("AgentHookInstaller") || name.hasPrefix("AgentSkillsInstaller")
            },
            PathRule(kind: .dependencies, label: "dependencies") { _, name in dependencyFiles.contains(name) }
        ]

        /// The path rules a file's path, or its path before a rename,
        /// matches; the reason is the file's name for dependencies.
        static func pathSignals(path: String, oldPath: String?) -> [RiskSignal] {
            merged(([path] + (oldPath.map { [$0] } ?? [])).flatMap { candidate in
                let name = fileName(candidate)
                return pathRules.filter { $0.matches(candidate, name) }.map { rule in
                    RiskSignal(kind: rule.kind, reasons: [rule.kind == .dependencies ? name : rule.label], hunks: [], byPath: true)
                }
            })
        }

        /// The path rules added to the signals read from the lines. A
        /// folded file keeps no line signal: a generated file can say
        /// anything, and a reindented line changes nothing. A test ships
        /// nothing: it keeps only concurrency, which CI's Swift 6.1 checks
        /// more strictly than a local build.
        static func settle(_ file: inout FileChange) {
            let isTest = PathGroup(path: file.path) == .tests
            let fromLines = file.fold != nil ? [] : file.signals.filter { !isTest || $0.kind == .concurrency }
            file.signals = merged(fromLines + (isTest ? [] : pathSignals(path: file.path, oldPath: file.oldPath)))
        }
    }

    /// One signal per kind, in `RiskKind` order, with the reasons and
    /// hunks of `parts` sorted, each once.
    static func merged(_ parts: [RiskSignal]) -> [RiskSignal] {
        var reasons: [RiskKind: Set<String>] = [:]
        var hunks: [RiskKind: Set<Int>] = [:]
        var byPath: [RiskKind: Bool] = [:]
        for part in parts {
            reasons[part.kind, default: []].formUnion(part.reasons)
            hunks[part.kind, default: []].formUnion(part.hunks)
            byPath[part.kind] = byPath[part.kind] == true || part.byPath
        }
        return RiskKind.allCases.compactMap { kind in
            byPath[kind].map {
                RiskSignal(kind: kind, reasons: (reasons[kind] ?? []).sorted(), hunks: (hunks[kind] ?? []).sorted(), byPath: $0)
            }
        }
    }

    static func fileName(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }
}

// MARK: - Scripts the workflows call

extension BranchReview {
    /// Raises CI on a file a workflow or an action names by its path
    /// (`./scripts/bundle.sh`), as the worktree has them. Not on a doc,
    /// which a release-notes step may quote, nor a test.
    static func addWorkflowSignals(to files: inout [FileChange], root: String) {
        func paths(_ file: FileChange) -> [String] { [file.path] + (file.oldPath.map { [$0] } ?? []) }
        let candidates = files.indices.filter { ![.docs, .tests].contains(PathGroup(path: files[$0].path)) }
        guard !candidates.isEmpty else { return }
        let named = workflowNames(of: Set(candidates.flatMap { paths(files[$0]) }), root: root)
        for index in candidates {
            let workflows = Set(paths(files[index]).flatMap { named[$0] ?? [] })
            guard !workflows.isEmpty else { continue }
            files[index].signals = merged(files[index].signals + workflows.map {
                RiskSignal(kind: .ci, reasons: ["named in \($0)"], hunks: [], byPath: true)
            })
        }
    }

    private static let maxActionEntries = 2_000
    private static let maxWorkflowFiles = 200
    private static let maxWorkflowFileBytes = 256 << 10

    /// Each of `paths` a workflow or an action names, with the files that
    /// name it.
    static func workflowNames(of paths: Set<String>, root: String) -> [String: Set<String>] {
        var named: [String: Set<String>] = [:]
        for file in workflowFiles(root: root) {
            guard let data = readPrefix(of: root + "/" + file, maxBytes: maxWorkflowFileBytes) else { continue }
            for path in pathTokens(in: data) where paths.contains(path) { named[path, default: []].insert(file) }
        }
        return named
    }

    /// What GitHub reads: the YAML files at the top of `.github/workflows`,
    /// and the `action.yml` files below `.github/actions`, out of any
    /// `node_modules` an action vendors. A folder that is a symlink isn't
    /// followed.
    private static func workflowFiles(root: String) -> [String] {
        func isFolder(_ path: String) -> Bool {
            var info = stat()
            return lstat(root + "/" + path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        }
        guard isFolder(".github") else { return [] }
        var files: [String] = []
        if isFolder(".github/workflows"),
           let names = try? FileManager.default.contentsOfDirectory(atPath: root + "/.github/workflows") {
            files += names.filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }.sorted().map { ".github/workflows/" + $0 }
        }
        if isFolder(".github/actions"), let walk = FileManager.default.enumerator(atPath: root + "/.github/actions") {
            var entries = 0
            for case let relative as String in walk {
                entries += 1
                guard entries <= maxActionEntries else { break }
                switch fileName(relative) {
                case "node_modules": walk.skipDescendants()
                case "action.yml", "action.yaml": files.append(".github/actions/" + relative)
                default: break
                }
            }
        }
        return Array(files.prefix(maxWorkflowFiles))
    }

    /// The runs of path characters in `text` that hold a "/" or a ".",
    /// from the top level: "./scripts/x.sh",
    /// "$GITHUB_WORKSPACE/scripts/x.sh" and
    /// "${{ github.workspace }}/scripts/x.sh" all name "scripts/x.sh";
    /// "my-scripts/x.sh" doesn't, nor "test" in "swift test", nor a path
    /// below another variable or the home folder.
    static func pathTokens(in text: Data) -> Set<String> {
        func isPathByte(_ byte: UInt8) -> Bool {
            RiskRules.isIdentifier(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "/")
        }
        var tokens: Set<String> = []
        for run in text.split(whereSeparator: { !isPathByte($0) }) {
            var token = Substring(Patch.decoded(Data(run)))
            // "Run make." ends a sentence.
            while token.hasSuffix(".") { token = token.dropLast() }
            guard token.contains("/") || token.contains(".") else { continue }
            let before = text[text.startIndex..<run.startIndex]
            switch before.last {
            case UInt8(ascii: "$"):
                // The worktree's top level, as a variable.
                guard token.hasPrefix("GITHUB_WORKSPACE/") else { continue }
                token = token.dropFirst("GITHUB_WORKSPACE".count)
            case UInt8(ascii: "}"):
                let workspace = ["{{ github.workspace }}", "{{github.workspace}}", "{GITHUB_WORKSPACE}"].map { Data($0.utf8) }
                guard workspace.contains(where: { before.suffix($0.count).elementsEqual($0) }) else { continue }
            case UInt8(ascii: "~"):
                continue
            default:
                break
            }
            while let rest = token.hasPrefix("./") ? token.dropFirst(2) : token.hasPrefix("/") ? token.dropFirst() : nil {
                token = rest
            }
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
        // Sized by the file rather than the limit: thousands of small test
        // files are read in a row. One that grows meanwhile is read on.
        var data = Data(count: min(maxBytes, Int(clamping: info.st_size) + 1))
        var total = 0
        while total < maxBytes {
            if total == data.count { data.count = min(maxBytes, data.count * 2) }
            let capacity = data.count
            let read = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + total, capacity - total) }
            guard read > 0 else {
                if read < 0, total == 0 { return nil }
                break
            }
            total += read
        }
        data.count = total
        return data
    }
}

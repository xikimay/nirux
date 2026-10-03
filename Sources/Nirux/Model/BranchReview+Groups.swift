import Foundation

// MARK: - Groups without a model (sections 2 and 3)

extension BranchReview {
    /// A file's group by its path alone, as listed before Explain.
    enum PathGroup: String, CaseIterable, Equatable, Sendable {
        case code
        case tests
        case config
        case ci
        case docs

        /// The rules apply top to bottom, the first that matches wins, and
        /// Code is tried last: `Tests/README.md` is a test file.
        init(path: String) {
            let name = fileName(path)
            let lowercased = name.lowercased()
            if Self.isInFolder("Tests", path) || name.hasSuffix("Tests.swift")
                || ["_test.", ".test.", ".spec."].contains(where: name.contains) {
                self = .tests
            } else if name == "Package.swift" || lowercased.hasSuffix(".plist") || name.hasSuffix(".entitlements")
                || name == ".swiftlint.yml" || Self.isInFolder("scripts", path) {
                self = .config
            } else if path.hasPrefix(".github/workflows/") || path.hasPrefix(".github/actions/") {
                self = .ci
            } else if lowercased.hasSuffix(".md") || Self.isInFolder("docs", path) {
                self = .docs
            } else {
                self = .code
            }
        }

        /// Below a folder of that name, at any depth.
        private static func isInFolder(_ folder: String, _ path: String) -> Bool {
            path.hasPrefix(folder + "/") || path.contains("/" + folder + "/")
        }
    }

    struct FileGroup: Equatable, Sendable {
        enum Kind: Hashable, Sendable {
            /// What isn't committed yet, folded or not: at the top, so a
            /// build-rewritten lockfile shows before it is committed.
            case uncommitted
            case path(PathGroup)
            /// Collapsed, counted, never hidden.
            case folded(Fold)
        }

        let kind: Kind
        /// Added files first, then by lines changed, most first.
        let paths: [String]
    }

    /// The page's groups before Explain, in order, without the empty ones:
    /// what isn't committed, the path groups (Code first), then the folded
    /// groups.
    static func groups(of files: [FileChange]) -> [FileGroup] {
        var members: [FileGroup.Kind: [FileChange]] = [:]
        for file in files {
            let kind: FileGroup.Kind = file.isUncommitted
                ? .uncommitted : file.fold.map { .folded($0) } ?? .path(PathGroup(path: file.path))
            members[kind, default: []].append(file)
        }
        let order: [FileGroup.Kind] = [.uncommitted] + PathGroup.allCases.map { .path($0) } + Fold.allCases.map { .folded($0) }
        return order.compactMap { kind in
            members[kind].map { FileGroup(kind: kind, paths: $0.sorted(by: isListedBefore).map(\.path)) }
        }
    }

    private static func isListedBefore(_ first: FileChange, _ second: FileChange) -> Bool {
        if (first.status == .added) != (second.status == .added) { return first.status == .added }
        let (firstLines, secondLines) = (first.additions + first.deletions, second.additions + second.deletions)
        if firstLines != secondLines { return firstLines > secondLines }
        return first.path < second.path
    }
}

extension BranchReview.Snapshot {
    var groups: [BranchReview.FileGroup] { BranchReview.groups(of: files) }
}

// MARK: - Folded noise

extension BranchReview {
    static let lockfiles: Set<String> = [
        "Package.resolved", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Cargo.lock", "Gemfile.lock",
        "Podfile.lock", "go.sum"
    ]

    /// The folds a file's name shows before its patch is read: a lockfile,
    /// or a generated file by its name, its `linguist-generated` attribute
    /// or a marker in its first lines. They keep a file's patch out of the
    /// inline budget (a 10 MB bundle mustn't send the whole page on
    /// demand) and its lines out of the signals.
    struct NoiseRules {
        /// True when `.gitattributes` sets `linguist-generated`, false when
        /// it unsets it (`-linguist-generated`, `=false`): GitHub's way to
        /// say a file isn't generated whatever its name.
        let generatedAttribute: [String: Bool]

        /// Reads the attribute of `paths`, as the worktree's
        /// `.gitattributes` set it. A failed read leaves it out.
        /// `check-attr` takes its paths on the command line, which
        /// `BoundedProcess` keeps under 4,096 arguments: they go
        /// `pathsPerCheck` at a time.
        init(root: String, paths: [String], options: Options, pathsPerCheck: Int = 1_000) {
            var attribute: [String: Bool] = [:]
            for start in stride(from: 0, to: paths.count, by: pathsPerCheck) {
                let batch = paths[start..<min(start + pathsPerCheck, paths.count)]
                guard let output = git(["check-attr", "-z", "linguist-generated", "--"] + batch, in: root, options: options),
                      output.status == 0
                else { continue }
                // "path\0attribute\0value\0", for each path.
                let fields = output.stdout.split(separator: 0, omittingEmptySubsequences: false)
                for index in stride(from: 0, to: fields.count - 2, by: 3) {
                    switch Patch.decoded(fields[index + 2]) {
                    case "unspecified": break
                    case "unset", "false": attribute[Patch.decoded(fields[index])] = false
                    default: attribute[Patch.decoded(fields[index])] = true
                    }
                }
            }
            generatedAttribute = attribute
        }

        /// `firstLines` gives the file's start, for a marker; it is asked
        /// for only when the name and the attribute settle nothing.
        func fold(path: String, firstLines: () -> Data? = { nil }) -> Fold? {
            let name = fileName(path)
            if lockfiles.contains(name) { return .lockfile }
            if let generated = generatedAttribute[path] { return generated ? .generated : nil }
            if name.hasSuffix(".bundle.js") || name.hasSuffix(".min.js") { return .generated }
            return firstLines().map(hasGeneratedMarker) == true ? .generated : nil
        }
    }

    /// "@generated", or Go's "Code generated … DO NOT EDIT", in the first
    /// five lines.
    static func hasGeneratedMarker(_ start: Data) -> Bool {
        let lines = start.split(separator: UInt8(ascii: "\n"), maxSplits: 5, omittingEmptySubsequences: false).prefix(5)
        return lines.contains { line in
            let bytes = Array(line)
            if let range = firstRange(of: Array("@generated".utf8), in: bytes),
               !(range.lowerBound > 0 && RiskRules.isIdentifier(bytes[range.lowerBound - 1])),
               !(range.upperBound < bytes.count && RiskRules.isIdentifier(bytes[range.upperBound])) {
                return true
            }
            guard let code = firstRange(of: Array("Code generated ".utf8), in: bytes) else { return false }
            return firstRange(of: Array("DO NOT EDIT".utf8), in: Array(bytes[code.upperBound...])) != nil
        }
    }

    private static func firstRange(of needle: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count) where bytes[start..<(start + needle.count)].elementsEqual(needle) {
            return start..<(start + needle.count)
        }
        return nil
    }
}

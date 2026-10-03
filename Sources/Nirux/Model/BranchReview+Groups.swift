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
        /// Code is tried last: `Tests/README.md` is a test file. Besides
        /// the design's table, Config takes `.gitattributes`, which decides
        /// what is generated, and what `.github/` holds besides the
        /// workflows and actions (Dependabot, templates).
        init(path: String) {
            let name = fileName(path)
            let lowercased = name.lowercased()
            let isWorkflow = path.hasPrefix(".github/workflows/") || path.hasPrefix(".github/actions/")
            if Self.isInTestFolder(path) || name.hasSuffix("Tests.swift")
                || ["_test.", ".test.", ".spec."].contains(where: name.contains) {
                self = .tests
            } else if name == "Package.swift" || lowercased.hasSuffix(".plist") || name.hasSuffix(".entitlements")
                || name == ".swiftlint.yml" || name == ".gitattributes" || Self.isInFolder("scripts", path)
                || (path.hasPrefix(".github/") && !isWorkflow) {
                self = .config
            } else if isWorkflow {
                self = .ci
            } else if lowercased.hasSuffix(".md") || path.hasPrefix("docs/") {
                // A "docs" folder deeper down may hold code.
                self = .docs
            } else {
                self = .code
            }
        }

        /// Below a folder of that name, at any depth.
        static func isInFolder(_ folder: String, _ path: String) -> Bool {
            path.hasPrefix(folder + "/") || path.contains("/" + folder + "/")
        }

        /// Below a folder whose name ends in "Tests", at any depth:
        /// `Tests/`, and Xcode's `AppTests/` and `AppUITests/`.
        private static func isInTestFolder(_ path: String) -> Bool {
            path.split(separator: "/", omittingEmptySubsequences: false).dropLast().contains { $0.hasSuffix("Tests") }
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
        /// Added files first, then by lines changed, most first. What
        /// isn't committed refreshes while the agent works: added files
        /// first, then by path, so that a row doesn't move under the
        /// pointer.
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
            members[kind].map { files in
                let sorted = files.sorted { isListedBefore($0, $1, byLines: kind != .uncommitted) }
                return FileGroup(kind: kind, paths: sorted.map(\.path))
            }
        }
    }

    private static func isListedBefore(_ first: FileChange, _ second: FileChange, byLines: Bool) -> Bool {
        if (first.status == .added) != (second.status == .added) { return first.status == .added }
        let (firstLines, secondLines) = (first.additions + first.deletions, second.additions + second.deletions)
        if byLines, firstLines != secondLines { return firstLines > secondLines }
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
        /// `.gitattributes` set it, unless `ignoresAttributes`: the branch
        /// changes a `.gitattributes`, and mustn't fold its own files. A
        /// failed read leaves it out. `check-attr` takes its paths on the
        /// command line, which `BoundedProcess` keeps under 4,096
        /// arguments: they go `pathsPerCheck` at a time.
        init(root: String, paths: [String], ignoresAttributes: Bool = false, options: Options, pathsPerCheck: Int = 1_000) {
            var attribute: [String: Bool] = [:]
            for start in stride(from: 0, to: ignoresAttributes ? 0 : paths.count, by: pathsPerCheck) {
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
            if name.hasSuffix(".bundle.js") || name.hasSuffix(".min.js") || name.hasSuffix(".pb.swift") { return .generated }
            return firstLines().map(hasGeneratedMarker) == true ? .generated : nil
        }
    }

    /// Whether a change to `path` changes what `.gitattributes` says.
    static func changesAttributes(_ path: String) -> Bool {
        fileName(path) == ".gitattributes"
    }

    /// "@generated" outside quotes ("This file is automatically @generated
    /// by Cargo"), or opening a line or its comment, Go's "Code generated
    /// … DO NOT EDIT" or a Swift generator's header (`generatorHeaders`),
    /// in the first five lines. A script that writes the marker quotes it.
    static func hasGeneratedMarker(_ start: Data) -> Bool {
        let lines = start.split(separator: UInt8(ascii: "\n"), maxSplits: 5, omittingEmptySubsequences: false).prefix(5)
        return lines.contains { line in
            let bytes = Array(line)
            if let range = firstRange(of: Array("@generated".utf8), in: bytes),
               !bytes[..<range.lowerBound].contains(where: { [UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`")].contains($0) }),
               !(range.lowerBound > 0 && RiskRules.isIdentifier(bytes[range.lowerBound - 1])),
               !(range.upperBound < bytes.count && RiskRules.isIdentifier(bytes[range.upperBound])) {
                return true
            }
            let comment = bytes.drop { [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "/"), UInt8(ascii: "#"),
                                        UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: ";")].contains($0) }
            if generatorHeaders.contains(where: { comment.starts(with: $0) }) { return true }
            guard comment.starts(with: Array("Code generated ".utf8)) else { return false }
            return firstRange(of: Array("DO NOT EDIT".utf8), in: Array(comment)) != nil
        }
    }

    /// SwiftGen, Sourcery and SwiftProtobuf, whose files don't say
    /// "@generated".
    private static let generatorHeaders = [
        "Generated using SwiftGen", "Generated using Sourcery", "Generated by the Swift generator plugin"
    ].map { Array($0.utf8) }

    private static func firstRange(of needle: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count) where bytes[start..<(start + needle.count)].elementsEqual(needle) {
            return start..<(start + needle.count)
        }
        return nil
    }
}

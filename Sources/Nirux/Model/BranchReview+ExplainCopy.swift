import Darwin
import Foundation

// MARK: - What Explain keeps from the model (section 4.3)

extension BranchReview {
    /// Files and text Explain never sends: paths that look like a secret,
    /// and text holding a key, found by its shape (validated by the user on
    /// 2026-10-04: the design's plain markers hid code that talks about
    /// keys, and let other tokens through).
    enum Secrets {
        /// Immutable, so safe to share across threads, whether or not the
        /// SDK marks `NSRegularExpression` `Sendable` (macOS 15's may not).
        private struct Pattern: @unchecked Sendable {
            let expression: NSRegularExpression
        }

        /// No part of a pattern is a key: this file is copied and sent as
        /// any other. Every repeat is bounded: finding a key needs its
        /// first characters only, and an unbounded one over a long run of
        /// token characters stops ICU with an error.
        private static let keyPattern = Pattern(expression: try! NSRegularExpression(pattern: [
            #"-----BEGIN[A-Z ]{0,40}PRIVATE KEY"#,
            // "-----BEGIN" in base64: a key, or a certificate, inside a
            // config file (kubeconfig). The empty group keeps this line
            // from matching itself.
            #"LS0tLS1(?:)CRUdJTi"#,
            #"sk-ant-[A-Za-z0-9_-]{20}"#,
            #"sk-proj-[A-Za-z0-9_-]{20}"#,
            // OpenAI's keys, with or without a kind (sk-svcacct-,
            // sk-admin-), with a digit: not a slug like "sk-hynix-reports-…".
            #"\bsk-(?:[A-Za-z]{1,12}-)?(?=[A-Za-z_-]{0,39}[0-9])[A-Za-z0-9_-]{40}"#,
            #"\b[rs]k_live_[A-Za-z0-9]{16}"#,
            #"\bgh[pousr]_[A-Za-z0-9]{36}"#,
            #"github_pat_[A-Za-z0-9_]{22}"#,
            #"glpat-[A-Za-z0-9_-]{20}"#,
            #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
            #"\bAIza[0-9A-Za-z_-]{35}"#,
            #"\bxox[abprs]-[A-Za-z0-9-]{10}"#,
            #"\bnpm_[A-Za-z0-9]{36}"#
        ].joined(separator: "|")))

        /// A text the pattern can't be run over (ICU stopped) counts as
        /// holding a key.
        static func containsKey(_ text: String) -> Bool {
            var found = false
            keyPattern.expression.enumerateMatches(
                in: text, options: .reportCompletion, range: NSRange(text.startIndex..., in: text)
            ) { match, flags, stop in
                if match != nil || flags.contains(.internalError) {
                    found = true
                    stop.pointee = true
                }
            }
            return found
        }

        /// Folders whose files are secrets whatever their names, and names
        /// and extensions of files that hold one. Checked lowercased.
        private static let folders: Set<String> = [".ssh", ".gnupg", ".aws", ".docker", ".kube", "secrets", ".secrets"]
        private static let names: Set<String> = [
            ".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd", ".pgpass"
        ]
        private static let prefixes = [".env", "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", "authkey_"]
        private static let suffixes = [
            ".env", ".pem", ".p8", ".p12", ".pfx", ".key", ".jks", ".keystore", ".ppk", ".mobileprovision",
            ".tfvars", ".tfvars.json", ".tfstate", ".tfstate.backup"
        ]
        /// Code that handles credentials is reviewed like any code: the
        /// folder, "credentials" and "secret" rules don't apply to it, nor
        /// to a CI workflow.
        private static let codeExtensions: Set<String> = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py", "rb", "js", "jsx", "mjs", "cjs", "ts",
            "tsx", "java", "kt", "kts", "scala", "groovy", "gradle", "cs", "php", "dart", "ex", "exs", "lua", "pl",
            "sh", "bash", "zsh", "fish", "ps1", "tf", "hcl", "sql", "html", "erb", "css", "scss", "sass", "less",
            "vue", "svelte", "proto", "graphql", "md"
        ]

        /// By the file's name and folders, whatever their case: `.env*`,
        /// `prod.env`, keys and certificates with their private part
        /// (`*.pem`, `*.p8`, `*.p12`, `id_rsa*`…), tokens files (`.npmrc`,
        /// `.netrc`…), Terraform state and variables, and files under
        /// `.ssh/`, `.aws/`, `.kube/`, `secrets/`, `.config/gh/`; a file
        /// named `*credentials*` or `*secret*`, unless it is code.
        static func isSecretPath(_ path: String) -> Bool {
            let components = path.lowercased().split(separator: "/").map(String.init)
            guard let name = components.last else { return false }
            if names.contains(name) || prefixes.contains(where: name.hasPrefix) || suffixes.contains(where: name.hasSuffix) {
                return true
            }
            let folderPath = components.dropLast()
            if zip(folderPath, folderPath.dropFirst()).contains(where: { $0 == ".config" && $1 == "gh" }) { return true }
            let isWorkflow = path.lowercased().hasPrefix(".github/workflows/")
            let isCode = isWorkflow || (name.contains(".") && codeExtensions.contains(String(name.split(separator: ".").last ?? "")))
            return !isCode && (name.contains("credentials") || name.contains("secret") || folderPath.contains(where: folders.contains))
        }
    }

    /// A path as Explain's input and the page show it: control characters,
    /// line breaks, bidi controls and other invisible characters as their
    /// code point (`⟨U+202E⟩`), so a path can't fake a line of the input
    /// or hide its extension. A variation selector stays after an emoji.
    static func visible(_ text: String) -> String {
        var result = ""
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            let value = scalar.value
            let isVariationSelector = value == 0xFE0E || value == 0xFE0F
            let hidden = isVariationSelector
                ? !(previous?.properties.isEmoji ?? false)
                : scalar.properties.generalCategory == .control || scalar.properties.isDefaultIgnorableCodePoint
                    || value == 0x2028 || value == 0x2029 || (0xFFF9...0xFFFB).contains(value)
            if hidden {
                result += codePoint(scalar)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func codePoint(_ scalar: Unicode.Scalar) -> String {
        "\u{27E8}U+" + String(format: "%04X", scalar.value) + "\u{27E9}"
    }
}

// MARK: - Explain's copy of the branch (section 4.3)

extension BranchReview {
    /// The folder Explain's `claude -p` runs in: a fresh temporary copy of
    /// the text files git tracks, as the working tree has them (committed
    /// and staged files with their uncommitted edits, intent-to-add files
    /// included), and the untracked files the run sends when asked. Files
    /// are read from the working tree and written to the copy: nothing is
    /// written to the repository, its index or its object store. Not a
    /// `git worktree add`, which would show on the Project Board.
    ///
    /// A path is copied once, and only if it is a regular UTF-8 text file
    /// with one link, reached without a symlink: submodules, links, hard
    /// links, binaries and deleted files are left out. So are secrets
    /// (`Secrets`, and files renamed from a secret path), files whose edits
    /// git hides (assume-unchanged, skip-worktree) or turns into something
    /// else (a clean filter: git-crypt, git-lfs, redaction), and the
    /// branch's instructions for an agent (`CLAUDE.md`, `AGENTS.md`,
    /// `.claude/`), which must not reach the reviewer as project
    /// instructions.
    ///
    /// The copy holds a lock while it lives: `sweep` leaves it alone.
    final class ExplainCopy: Sendable {
        static let folderPrefix = "nirux-explain-"
        static let lockSuffix = ".lock"

        struct Limits: Sendable {
            /// Past this, a file isn't copied: the model reads text, and
            /// the key check reads the whole file.
            var maxFileBytes = 4 << 20
            /// Past this in all, files aren't copied, the branch's own
            /// files first.
            var maxTotalBytes = 1 << 30
        }

        /// A leftover folder without a lock this old belongs to no run.
        static let leftoverAge: TimeInterval = 30 * 60

        enum LeftOut: Error, Equatable, Sendable {
            /// Not in the working tree: a deletion the diff shows. Never in
            /// `leftOut`.
            case missing
            /// Not a regular file, a hard link, or reached through a symlink.
            case notRegularFile
            /// Binary, or not UTF-8.
            case notText
            case secretPath
            /// The file holds something shaped like a key.
            case key
            /// `CLAUDE.md`, `AGENTS.md` and their variants, or inside a
            /// `.claude` folder.
            case instructions
            /// Assume-unchanged or skip-worktree: git hides its edits.
            case hiddenFromGit
            /// A clean filter changes what git stores.
            case filtered
            /// Over `Limits.maxFileBytes`.
            case tooLarge
            /// Past `Limits.maxTotalBytes` in all.
            case overTotal
            /// A path that isn't UTF-8, or the read failed.
            case unreadable
            /// Couldn't be written: two paths differing only in case, or
            /// the disk is full.
            case notWritten
        }

        struct Omitted: Equatable, Sendable {
            let path: String
            let reason: LeftOut
        }

        let folder: URL
        /// The paths copied: the branch's files first, then as git lists
        /// them.
        let copied: [String]
        let leftOut: [Omitted]
        private let lock: URL
        private let lockDescriptor: Int32

        private init(folder: URL, copied: [String], leftOut: [Omitted], lock: URL, lockDescriptor: Int32) {
            self.folder = folder
            self.copied = copied
            self.leftOut = leftOut
            self.lock = lock
            self.lockDescriptor = lockDescriptor
        }

        deinit {
            close(lockDescriptor)
        }

        /// `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` (which Claude Code
        /// reads where there is no `CLAUDE.md`), `AGENTS.override.md`, or a
        /// path inside a `.claude` folder, whatever the case: APFS doesn't
        /// tell `claude.md` from `CLAUDE.md`.
        static func isInstructions(_ path: String) -> Bool {
            let components = path.lowercased().split(separator: "/").map(String.init)
            guard let name = components.last else { return false }
            return ["claude.md", "claude.local.md", "agents.md", "agents.override.md"].contains(name)
                || components.contains(".claude")
        }

        /// Copies the worktree of `snapshot` into a new folder in `parent`:
        /// the branch's files first, so the limit spends on them, and its
        /// untracked files when `includeUntracked` (the run sends their
        /// diffs). Nil when git can't list the files, the folder can't be
        /// made, or `cancellation` stopped it. Call it off the main thread,
        /// and `remove` the copy after the run.
        static func make(
            for snapshot: Snapshot,
            includeUntracked: Bool = false,
            options: Options = Options(),
            limits: Limits = Limits(),
            in parent: URL = FileManager.default.temporaryDirectory,
            cancellation: BoundedProcess.Cancellation? = nil
        ) -> ExplainCopy? {
            let root = snapshot.root
            guard let listed = git(["ls-files", "-z", "-v"], in: root, options: options), listed.status == 0 else { return nil }
            var tracked: [String] = []
            var leftOut: [Omitted] = []
            var seen = Set<String>()
            for entry in listed.stdout.split(separator: 0) where entry.count > 2 {
                // "H path": a lowercase tag is assume-unchanged, S is
                // skip-worktree.
                let tag = entry[entry.startIndex]
                guard let path = String(data: Data(entry.dropFirst(2)), encoding: .utf8) else {
                    leftOut.append(Omitted(path: String(decoding: entry.dropFirst(2), as: UTF8.self), reason: .unreadable))
                    continue
                }
                guard seen.insert(path).inserted else { continue }
                if tag == UInt8(ascii: "S") || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(tag) {
                    leftOut.append(Omitted(path: path, reason: .hiddenFromGit))
                } else {
                    tracked.append(path)
                }
            }
            let untracked = includeUntracked ? snapshot.files.filter(\.isUntracked).map(\.path) : []
            let filtered = filteredPaths(tracked + untracked, root: root, options: options)
            let secretRenames = Set(snapshot.files.filter { $0.oldPath.map(Secrets.isSecretPath) == true }.map(\.path))
            // The branch's files first, then the rest as git lists them.
            let changed = Set(snapshot.files.map(\.path))
            let ordered = tracked.filter(changed.contains) + untracked.filter { seen.insert($0).inserted }
                + tracked.filter { !changed.contains($0) }

            // Made and locked at once (`O_EXLOCK`), before the folder: a
            // sweep never sees the folder unlocked.
            let lock = parent.appendingPathComponent(folderPrefix + UUID().uuidString + lockSuffix)
            let lockDescriptor = open(lock.path, O_RDONLY | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockDescriptor >= 0 else { return nil }
            let folder = URL(fileURLWithPath: String(lock.path.dropLast(lockSuffix.count)), isDirectory: true)
            let rootDescriptor = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard rootDescriptor >= 0, mkdir(folder.path, 0o700) == 0 else {
                if rootDescriptor >= 0 { close(rootDescriptor) }
                unlink(lock.path)
                close(lockDescriptor)
                return nil
            }
            defer { close(rootDescriptor) }
            let copy = { (copied: [String]) in
                ExplainCopy(folder: folder, copied: copied, leftOut: leftOut, lock: lock, lockDescriptor: lockDescriptor)
            }

            var copied: [String] = []
            var total = 0
            for path in ordered {
                if cancellation?.isCancelled == true {
                    remove(copy(copied))
                    return nil
                }
                let reason: LeftOut? = autoreleasepool {
                    if isInstructions(path) { return .instructions }
                    if Secrets.isSecretPath(path) || secretRenames.contains(path) { return .secretPath }
                    if filtered.contains(path) { return .filtered }
                    switch read(path, from: rootDescriptor, limits: limits, budget: limits.maxTotalBytes - total) {
                    case .failure(let reason):
                        return reason
                    case .success(let (data, text, isExecutable)):
                        if Secrets.containsKey(text) { return .key }
                        guard write(data, to: folder.appendingPathComponent(path), executable: isExecutable) else {
                            return .notWritten
                        }
                        total += data.count
                        return nil
                    }
                }
                if reason == .missing {
                    continue
                } else if let reason {
                    leftOut.append(Omitted(path: path, reason: reason))
                } else {
                    copied.append(path)
                }
            }
            return copy(copied)
        }

        /// The paths a clean filter applies to (`filter` set in their git
        /// attributes): what git stores isn't what the working tree holds.
        private static func filteredPaths(_ paths: [String], root: String, options: Options) -> Set<String> {
            guard !paths.isEmpty else { return [] }
            let input = paths.reduce(into: Data()) { data, path in
                data.append(contentsOf: path.utf8)
                data.append(0)
            }
            guard let outcome = BoundedProcess.execute(
                executableURL: URL(fileURLWithPath: options.gitPath),
                arguments: ["check-attr", "-z", "--stdin", "filter"],
                currentDirectoryURL: URL(fileURLWithPath: root),
                environment: .inherited(adding: GitDetect.readOnlyEnvironment.merging(options.environment) { _, new in new }),
                standardInput: input,
                timeout: options.timeout
            ), outcome.stop == nil, outcome.terminationStatus == 0 else {
                // Unknown: every file counts as filtered, rather than copy
                // a decrypted one.
                return Set(paths)
            }
            // "path NUL filter NUL value NUL", for each path.
            let fields = outcome.standardOutput.split(separator: 0, omittingEmptySubsequences: false)
            var filtered = Set<String>()
            var index = 0
            while index + 2 < fields.count {
                let value = String(decoding: fields[index + 2], as: UTF8.self)
                if value != "unspecified", value != "unset" {
                    filtered.insert(String(decoding: fields[index], as: UTF8.self))
                }
                index += 3
            }
            return filtered
        }

        /// The file at `path` below the root, opened without following a
        /// symlink anywhere in `path` (`O_NOFOLLOW_ANY`) and without
        /// blocking on a FIFO, if it is a regular UTF-8 text file with one
        /// link, within the limits.
        private static func read(
            _ path: String, from rootDescriptor: Int32, limits: Limits, budget: Int
        ) -> Result<(Data, String, Bool), LeftOut> {
            let descriptor = openat(rootDescriptor, path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                switch errno {
                // Gone, or a folder on its path became a file.
                case ENOENT, ENOTDIR: return .failure(.missing)
                case EACCES, EPERM: return .failure(.unreadable)
                default: return .failure(.notRegularFile)
                }
            }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                return .failure(.notRegularFile)
            }
            let size = Int(info.st_size)
            guard size <= limits.maxFileBytes else { return .failure(.tooLarge) }
            guard size <= budget else { return .failure(.overTotal) }
            // One byte more than its size says whether it grew meanwhile.
            var data = Data(count: size + 1)
            var length = 0
            while length < data.count {
                let bytesRead = data.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress! + length, bytes.count - length)
                }
                if bytesRead > 0 {
                    length += bytesRead
                } else if bytesRead == 0 {
                    break
                } else if errno != EINTR {
                    return .failure(.unreadable)
                }
            }
            // It grew while it was read: an agent is writing it.
            guard length <= size else { return .failure(.unreadable) }
            data.count = length
            guard !data.prefix(8_000).contains(0), let text = String(data: data, encoding: .utf8) else {
                return .failure(.notText)
            }
            return .success((data, text, info.st_mode & 0o111 != 0))
        }

        private static func write(_ data: Data, to url: URL, executable: Bool) -> Bool {
            let folder = url.deletingLastPathComponent()
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
                return false
            }
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, executable ? 0o755 : 0o644)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + offset, $0.count - offset) }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }

        /// Deletes the folder and its lock file. The lock itself goes with
        /// the copy, once nothing holds it.
        static func remove(_ copy: ExplainCopy) {
            try? FileManager.default.removeItem(at: copy.folder)
            unlink(copy.lock.path)
        }

        /// Deletes copies left behind (Nirux quit or crashed during a run):
        /// at launch, and before a run. A copy whose lock is held is
        /// another run's, maybe another Nirux's (the installed app and a
        /// dev build share the temporary folder), and stays; one without a
        /// lock file goes only once it is `age` old.
        static func sweep(
            in parent: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = leftoverAge,
            now: Date = Date()
        ) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { return }
            for name in names where name.hasPrefix(folderPrefix) {
                let path = parent.appendingPathComponent(name).path
                if name.hasSuffix(lockSuffix) {
                    // A lock whose folder is gone: a run that stopped
                    // between the two.
                    let folder = String(path.dropLast(lockSuffix.count))
                    guard !FileManager.default.fileExists(atPath: folder) else { continue }
                    let descriptor = open(path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { continue }
                    unlink(path)
                    close(descriptor)
                    continue
                }
                // `attributesOfItem` doesn't follow a link: a link is never
                // a run's folder, and stays.
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      attributes[.type] as? FileAttributeType == .typeDirectory
                else { continue }
                let lockPath = path + lockSuffix
                let descriptor = open(lockPath, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if descriptor >= 0 {
                    try? FileManager.default.removeItem(atPath: path)
                    unlink(lockPath)
                    close(descriptor)
                } else if errno == ENOENT, let modified = attributes[.modificationDate] as? Date,
                          now.timeIntervalSince(modified) > age {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }
    }
}

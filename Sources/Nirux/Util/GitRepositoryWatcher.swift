import CoreServices
import Foundation

/// What a filesystem event means for a workspace's git context.
enum GitRepositoryChange: Int, Comparable, Sendable {
    /// A working-tree file changed: at most the dirty bit moved.
    case worktree
    /// HEAD, the index, the checked-out branch ref or the repository config
    /// changed: branch, head, dirty bit or upstream may all have moved.
    case metadata

    static func < (lhs: GitRepositoryChange, rhs: GitRepositoryChange) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// On-disk layout of a checkout: the working tree plus its private and
/// shared git directories (distinct for linked worktrees). Resolved by
/// reading `.git` directly, so watching a repository never spawns git.
struct GitRepositoryLayout: Equatable, Sendable {
    let worktreeRoot: String
    /// `$GIT_DIR`: HEAD and the index of this checkout live here.
    let gitDirectory: String?
    /// Refs, packed-refs and config shared by every worktree. Equal to
    /// `gitDirectory` for a plain checkout.
    let commonDirectory: String?

    init(worktreeRoot: String, gitDirectory: String?, commonDirectory: String?) {
        self.worktreeRoot = worktreeRoot
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
    }

    static func resolve(worktreeRoot: String) -> GitRepositoryLayout {
        let root = canonicalPath(worktreeRoot)
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else {
            return GitRepositoryLayout(worktreeRoot: root, gitDirectory: nil, commonDirectory: nil)
        }
        if isDirectory.boolValue {
            return GitRepositoryLayout(worktreeRoot: root, gitDirectory: dotGit, commonDirectory: dotGit)
        }
        // Linked worktree or submodule: `.git` is a "gitdir: <path>" file,
        // and a linked worktree's git dir names the shared one in `commondir`.
        guard let gitDirectory = referencedPath(in: dotGit, prefix: "gitdir:", relativeTo: root) else {
            return GitRepositoryLayout(worktreeRoot: root, gitDirectory: nil, commonDirectory: nil)
        }
        let commonDirectory = referencedPath(
            in: (gitDirectory as NSString).appendingPathComponent("commondir"),
            prefix: nil,
            relativeTo: gitDirectory
        ) ?? gitDirectory
        return GitRepositoryLayout(
            worktreeRoot: root,
            gitDirectory: gitDirectory,
            commonDirectory: commonDirectory
        )
    }

    /// Roots FSEvents must watch. A git directory nested in the working
    /// tree (plain checkout) or in the common directory (linked worktree)
    /// is already covered by that recursive watch.
    var watchedPaths: [String] {
        var paths = [worktreeRoot]
        for directory in [commonDirectory, gitDirectory].compactMap({ $0 })
        where !paths.contains(where: { Self.relativePath(directory, in: $0) != nil }) {
            paths.append(directory)
        }
        return paths
    }

    /// Classify one event path. `nil` means the event cannot change this
    /// checkout's git context (object writes, reflogs, other worktrees'
    /// HEAD/index, other branches' refs, lock files).
    func classify(_ path: String, branch: String?) -> GitRepositoryChange? {
        if let gitDirectory, let entry = Self.relativePath(path, in: gitDirectory) {
            let isShared = gitDirectory == commonDirectory
            return Self.classifyGitEntry(entry, branch: branch, ownsCheckout: true, ownsSharedState: isShared)
        }
        if let commonDirectory, let entry = Self.relativePath(path, in: commonDirectory) {
            return Self.classifyGitEntry(entry, branch: branch, ownsCheckout: false, ownsSharedState: true)
        }
        return .worktree
    }

    private static func classifyGitEntry(
        _ entry: String,
        branch: String?,
        ownsCheckout: Bool,
        ownsSharedState: Bool
    ) -> GitRepositoryChange? {
        if entry.isEmpty { return .metadata }
        if entry.hasSuffix(".lock") { return nil }
        let components = entry.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first else { return .metadata }
        switch first {
        case "objects", "logs", "hooks", "lfs", "modules", "worktrees",
             "FETCH_HEAD", "ORIG_HEAD", "COMMIT_EDITMSG", "gc.log", "gc.pid":
            return nil
        case "refs":
            guard ownsSharedState else { return nil }
            guard components.count > 2, components[1] == "heads" else {
                // A bare `refs` or `refs/heads` directory event may hide a
                // branch update; tags, remotes and notes never matter.
                return components.count == 1 || (components.count == 2 && components[1] == "heads")
                    ? .metadata : nil
            }
            guard let branch else { return .metadata }
            return components.dropFirst(2).joined(separator: "/") == branch ? .metadata : nil
        case "packed-refs", "config", "info":
            return ownsSharedState ? .metadata : nil
        default:
            // HEAD, index, config.worktree, rebase/merge state: private to
            // the checkout that owns this git dir.
            return ownsCheckout ? .metadata : nil
        }
    }

    /// realpath(3), not `resolvingSymlinksInPath`: Foundation strips the
    /// `/private` prefix that FSEvents reports (`/tmp` → `/private/tmp`).
    static func canonicalPath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = realpath(standardized, nil) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Path of `path` relative to `directory`, or nil when it lies outside.
    static func relativePath(_ path: String, in directory: String) -> String? {
        guard path.hasPrefix(directory) else { return nil }
        let remainder = path.dropFirst(directory.count)
        if remainder.isEmpty { return "" }
        guard remainder.hasPrefix("/") else { return nil }
        return String(remainder.dropFirst())
    }

    private static func referencedPath(in file: String, prefix: String?, relativeTo base: String) -> String? {
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let line = contents.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let value: Substring
        if let prefix {
            guard line.hasPrefix(prefix) else { return nil }
            value = line.dropFirst(prefix.count)
        } else {
            value = Substring(line)
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let absolute = trimmed.hasPrefix("/") ? trimmed : (base as NSString).appendingPathComponent(trimmed)
        return canonicalPath(absolute)
    }
}

/// FSEvents stream over one repository layout. Batches are classified on
/// the main queue and forwarded as the strongest change they contain.
@MainActor
final class GitRepositoryWatcher {
    let layout: GitRepositoryLayout
    var branch: String?
    private let onChange: @MainActor (GitRepositoryChange) -> Void
    private var stream: FSEventStreamRef?

    /// Rescans, dropped events and a moved/unmounted root all mean "assume
    /// anything changed".
    private static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
    )

    init?(
        layout: GitRepositoryLayout,
        branch: String?,
        latency: CFTimeInterval = 0.3,
        onChange: @escaping @MainActor (GitRepositoryChange) -> Void
    ) {
        self.layout = layout
        self.branch = branch
        self.onChange = onChange

        // The stream retains the watcher through the context callbacks, so
        // a late callback can never reach a freed object; stop() releases it.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<GitRepositoryWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<GitRepositoryWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, eventPaths, eventFlags, _ in
                guard let info else { return }
                let watcher = Unmanaged<GitRepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                    .takeUnretainedValue() as? [String] ?? []
                let flags = Array(UnsafeBufferPointer(start: eventFlags, count: count))
                MainActor.assumeIsolated {
                    watcher.handle(paths: paths, flags: flags)
                }
            },
            &context,
            layout.watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    static func change(
        for path: String,
        flags: FSEventStreamEventFlags,
        layout: GitRepositoryLayout,
        branch: String?
    ) -> GitRepositoryChange? {
        if flags & rescanFlags != 0 { return .metadata }
        return layout.classify(path, branch: branch)
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard stream != nil else { return }
        var strongest: GitRepositoryChange?
        for (path, flag) in zip(paths, flags) {
            guard let change = Self.change(for: path, flags: flag, layout: layout, branch: branch) else {
                continue
            }
            strongest = max(strongest ?? change, change)
            if strongest == .metadata { break }
        }
        if let strongest { onChange(strongest) }
    }
}

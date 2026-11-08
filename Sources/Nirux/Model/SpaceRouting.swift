import Foundation

/// A folder as routing compares it with anchors (see SpaceAnchor).
struct FolderIdentity: Equatable, Sendable {
    /// The folder, with symlinks resolved.
    let path: String
    /// Its repository's common git dir, resolved: the same for the main
    /// checkout and every linked worktree. Nil outside a repository, or
    /// when git didn't answer in time.
    let commonDir: String?
    /// The top of the checkout holding `path`, resolved; set with
    /// `commonDir`.
    let topLevel: String?

    /// The anchor of this folder's repository, else of the folder itself.
    var anchor: SpaceAnchor {
        commonDir.map { SpaceAnchor.repository(commonDir: $0, topLevel: topLevel) } ?? .folder(path)
    }

    /// How long routing waits for git: a new workspace mustn't wait on a
    /// slow disk or a huge repository (it then routes as if the folder
    /// were in none).
    static let routingTimeout: TimeInterval = 0.3

    /// Runs git (`rev-parse`, no network): call it off the main thread. Nil
    /// when the folder doesn't exist.
    static func identify(_ folder: String, timeout: TimeInterval) -> FolderIdentity? {
        guard let path = folder.realPath, NiruxURLRequest.directoryExists(path) else { return nil }
        let paths = GitWorktree.absoluteGitPaths(["--git-common-dir", "--show-toplevel"], in: path, timeout: timeout)
        guard let commonDir = paths?[0].realPath, let topLevel = paths?[1].realPath else {
            return FolderIdentity(path: path, commonDir: nil, topLevel: nil)
        }
        return FolderIdentity(path: path, commonDir: commonDir, topLevel: topLevel)
    }
}

/// Which space a new workspace joins (docs/spaces.md, "Routing"), decided
/// once, before it is created, so that its first agent starts with the
/// space's env. After that only the user moves it.
enum SpaceRouting {
    enum Reason: Equatable, Sendable {
        /// Its folder is in a repository or folder a space has.
        case anchor
        /// It joins its parent's current space (a worktree or a Mission
        /// child).
        case parent
        /// The space the user started it from.
        case startedFrom
        /// Nothing else applies: a request from outside Nirux, or one the
        /// user confirmed without a launch ID.
        case general
    }

    struct Decision: Equatable, Sendable {
        let spaceID: String
        let reason: Reason
    }

    /// In this order: the most specific anchor holding the folder, the
    /// parent's current space, the space the user started it from, then the
    /// default space. A space id that no longer exists (a deleted space, a
    /// shell's stale NIRUX_PROFILE_ID) is skipped.
    static func route(
        identity: FolderIdentity?,
        parentSpaceID: String?,
        startedFromSpaceID: String?,
        spaces: [WorkspaceProfile]
    ) -> Decision {
        if let identity, let spaceID = anchoringSpace(of: identity, in: spaces) {
            return Decision(spaceID: spaceID, reason: .anchor)
        }
        let known = Set(spaces.map(\.id))
        if let parentSpaceID, known.contains(parentSpaceID) {
            return Decision(spaceID: parentSpaceID, reason: .parent)
        }
        if let startedFromSpaceID, known.contains(startedFromSpaceID) {
            return Decision(spaceID: startedFromSpaceID, reason: .startedFrom)
        }
        return Decision(spaceID: WorkspaceProfile.defaultID, reason: .general)
    }

    /// The space whose anchor holds the folder most closely. A repository
    /// counts as deep as the top of the checkout the folder is in, a folder
    /// anchor as its own path; on a tie the folder wins. So a folder anchor
    /// inside a repository beats the repository, and a repository beats a
    /// folder anchor holding the whole checkout.
    static func anchoringSpace(of identity: FolderIdentity, in spaces: [WorkspaceProfile]) -> String? {
        var best: (spaceID: String, depth: Int, isFolder: Bool)?
        for space in spaces {
            for anchor in space.anchors {
                let depth: Int
                let isFolder: Bool
                switch anchor.kind {
                case .gitRepository(let commonDir):
                    guard let found = identity.commonDir, found == commonDir else { continue }
                    depth = componentCount(identity.topLevel ?? identity.path)
                    isFolder = false
                case .folder(let path):
                    guard contains(path, identity.path) else { continue }
                    depth = componentCount(path)
                    isFolder = true
                case .unknown:
                    continue
                }
                if let current = best, current.depth > depth || (current.depth == depth && (current.isFolder || !isFolder)) {
                    continue
                }
                best = (space.id, depth, isFolder)
            }
        }
        return best?.spaceID
    }

    /// `folder` is `path` or one of its parents, comparing whole components:
    /// `/a/web` holds `/a/web/src`, not `/a/web2`.
    static func contains(_ folder: String, _ path: String) -> Bool {
        let parent = folder.count > 1 && folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        if parent == "/" { return path.hasPrefix("/") }
        return path == parent || path.hasPrefix(parent + "/")
    }

    private static func componentCount(_ path: String) -> Int {
        path.split(separator: "/").count
    }
}

import Foundation

/// Where a space's work lives (docs/design/spaces.md, "Spaces and anchors"): a git
/// repository, known by its common git dir so that the main checkout and
/// every linked worktree match, or a plain folder. A repository or a folder
/// belongs to one space at most, and one anchor of a space is its default:
/// a plain new workspace of the space opens there.
struct SpaceAnchor: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `git rev-parse --path-format=absolute --git-common-dir`, with
        /// symlinks resolved.
        case gitRepository(commonDir: String)
        /// A folder, with symlinks resolved. It holds what is inside it,
        /// compared by whole path components.
        case folder(path: String)
        /// A kind written by a newer Nirux: written back as read, never
        /// matched, never shown.
        case unknown(JSONValue)
    }

    var kind: Kind
    /// The main checkout's folder name, or the folder's.
    var name: String
    var isDefault: Bool

    init(kind: Kind, name: String, isDefault: Bool = false) {
        self.kind = kind
        self.name = name
        self.isDefault = isDefault
    }

    /// The same repository or folder, whatever its name; nil for an unknown
    /// kind, which is never matched.
    var key: String? {
        switch kind {
        case .gitRepository(let commonDir): return "git:" + commonDir
        case .folder(let path): return "folder:" + path
        case .unknown: return nil
        }
    }

    var isKnown: Bool { key != nil }

    /// Where a plain workspace of the space opens: the folder, or the
    /// repository's main checkout, the folder holding its `.git`. Nil for a
    /// bare repository or a separate git dir (no main checkout to find
    /// without git), and for an unknown kind.
    var folder: String? {
        switch kind {
        case .folder(let path):
            return path
        case .gitRepository(let commonDir):
            let url = URL(fileURLWithPath: commonDir)
            guard url.lastPathComponent == ".git" else { return nil }
            let parent = url.deletingLastPathComponent().path
            return parent.isEmpty ? nil : parent
        case .unknown:
            return nil
        }
    }

    /// The anchor of the repository with this common git dir, named after
    /// its main checkout, or `topLevel`'s folder when there is none.
    static func repository(commonDir: String, topLevel: String?) -> SpaceAnchor {
        var anchor = SpaceAnchor(kind: .gitRepository(commonDir: commonDir), name: "")
        let folder = anchor.folder ?? topLevel ?? commonDir
        anchor.name = URL(fileURLWithPath: folder).lastPathComponent
        return anchor
    }

    static func folder(_ path: String) -> SpaceAnchor {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return SpaceAnchor(kind: .folder(path: path), name: name.isEmpty ? path : name)
    }
}

// MARK: - Storage

/// Written as `{"kind": "gitRepository", "commonDir": …, "name": …,
/// "isDefault": …}` or `{"kind": "folder", "path": …, …}`. Reading is
/// lenient: whatever this build can't read as one of those (another kind,
/// a missing path) is kept as read and written back unchanged.
extension SpaceAnchor: Codable {
    /// The keys of each kind this build knows. Others mean a newer build
    /// added fields: the file is then read-only (see ProjectStore).
    static let knownKeys: [String: Set<String>] = [
        "gitRepository": ["kind", "commonDir", "name", "isDefault"],
        "folder": ["kind", "path", "name", "isDefault"]
    ]

    private enum CodingKeys: String, CodingKey {
        case kind, commonDir, path, name, isDefault
    }

    init(from decoder: Decoder) throws {
        self.init(raw: try JSONValue(from: decoder))
    }

    init(raw: JSONValue) {
        let object = raw.objectValue ?? [:]
        let isDefault: Bool
        if case .bool(let value)? = object["isDefault"] { isDefault = value } else { isDefault = false }
        let storedName = object["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        switch (object["kind"]?.stringValue, object["commonDir"]?.stringValue, object["path"]?.stringValue) {
        case ("gitRepository", let commonDir?, _) where commonDir.hasPrefix("/"):
            self = .repository(commonDir: commonDir, topLevel: nil)
        case ("folder", _, let path?) where path.hasPrefix("/"):
            self = .folder(path)
        default:
            self.init(kind: .unknown(raw), name: storedName ?? "", isDefault: isDefault)
            return
        }
        if let storedName { name = storedName }
        self.isDefault = isDefault
    }

    func encode(to encoder: Encoder) throws {
        if case .unknown(let raw) = kind { return try raw.encode(to: encoder) }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .gitRepository(let commonDir):
            try container.encode("gitRepository", forKey: .kind)
            try container.encode(commonDir, forKey: .commonDir)
        case .folder(let path):
            try container.encode("folder", forKey: .kind)
            try container.encode(path, forKey: .path)
        case .unknown:
            break
        }
        try container.encode(name, forKey: .name)
        try container.encode(isDefault, forKey: .isDefault)
    }

    /// A stored anchor of a kind this build knows that carries keys it
    /// doesn't: rewriting it would drop them.
    static func hasUnknownKeys(_ object: [String: Any]) -> Bool {
        guard let kind = object["kind"] as? String, let known = knownKeys[kind] else { return false }
        return !Set(object.keys).isSubset(of: known)
    }
}

// MARK: - A space's anchors

extension Array where Element == SpaceAnchor {
    /// The default anchor: the one marked so, else the first known one.
    var defaultAnchor: SpaceAnchor? {
        first { $0.isKnown && $0.isDefault } ?? first(where: \.isKnown)
    }

    /// Each repository or folder once, and exactly one default among the
    /// known anchors when there are any. Unknown kinds are left as read.
    func normalizedAnchors() -> [SpaceAnchor] {
        var seen = Set<String>()
        var result = filter { anchor in anchor.key.map { seen.insert($0).inserted } ?? true }
        let defaultKey = result.defaultAnchor?.key
        for index in result.indices where result[index].isKnown {
            result[index].isDefault = result[index].key == defaultKey
        }
        return result
    }
}

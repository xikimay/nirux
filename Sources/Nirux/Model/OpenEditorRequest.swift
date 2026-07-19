import Foundation

/// Single source of truth for "too big for Monaco" — the interactive open
/// path warns at this size, the URL open path refuses outright.
enum EditorFileLimits {
    static let maxEditableBytes: UInt64 = 5_000_000
}

/// Validated payload of a `nirux://open-editor` URL. URL handlers are
/// callable by any app on the system, so parsing is strict: the path must
/// be absolute and point at an existing, readable, text-like regular file,
/// and line numbers are clamped to a sane range. The path is never handed
/// to a shell. Validation does blocking I/O (stat + prefix read) — call it
/// off the main actor; a hostile path on a dead network mount can stall
/// for the full mount timeout.
struct OpenEditorRequest: Equatable, Sendable {
    let file: String
    let line: Int?
    let endLine: Int?
    let workspaceID: String?

    /// Upper bound for line numbers — far above any real file, low enough
    /// to reject garbage like Int.max from a hostile caller.
    static let maxLine = 10_000_000

    /// URL-triggered opens are non-interactive (no large-file confirmation
    /// dialog), so refuse outright what EditorColumn would ask about.
    static let maxFileBytes = EditorFileLimits.maxEditableBytes

    /// `canonicalize` maps the lexically-cleaned path to the spelling used
    /// as tab identity; `isOpenableFile` gates on the filesystem. Both
    /// injectable so parse tests stay hermetic.
    init?(
        queryItems: [URLQueryItem]?,
        canonicalize: (String) -> String = OpenEditorRequest.canonicalPath,
        isOpenableFile: (String) -> Bool = OpenEditorRequest.fileExistsOnDisk
    ) {
        func value(_ name: String) -> String? {
            queryItems?.first(where: { $0.name == name })?.value
        }
        guard let rawPath = value("file"), rawPath.hasPrefix("/") else { return nil }
        let path = canonicalize(Self.resolveDotSegments(rawPath))
        guard path.hasPrefix("/"), isOpenableFile(path) else { return nil }
        file = path

        func lineValue(_ name: String) -> Int? {
            guard let parsed = value(name).flatMap(Int.init) else { return nil }
            return (1...Self.maxLine).contains(parsed) ? parsed : nil
        }
        let start = lineValue("line")
        let end = lineValue("endLine")
        // A range needs a start; an inverted range is treated as reversed
        // rather than dropped so an agent that swaps the two still works.
        switch (start, end) {
        case let (first?, last?) where last < first:
            line = last
            endLine = first
        case (nil, _):
            line = nil
            endLine = nil
        default:
            line = start
            endLine = end
        }

        let workspace = value("workspace")
        workspaceID = (workspace?.isEmpty == false) ? workspace : nil
    }

    /// Lexically resolve "." / ".." segments and collapse duplicate or
    /// trailing slashes.
    private static func resolveDotSegments(_ path: String) -> String {
        var parts: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(String(component))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolve symlinks so tab identity matches the spelling terminal
    /// file-links tend to deliver (/tmp/x and /private/tmp/x are the same
    /// inode; two spellings would open two divergent buffers whose saves
    /// silently overwrite each other).
    static func canonicalPath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }

    /// Regular, size-capped, text-like files only:
    /// - a FIFO or device node (reachable directly or via symlink) would
    ///   hang or flood the read in EditorColumn, so require .typeRegular
    ///   on the fully resolved path (attributesOfItem doesn't follow the
    ///   final symlink);
    /// - binaries pass the type/size gates but fail EditorColumn's decode,
    ///   which for a non-interactive open would silently leave an empty
    ///   editor column behind — sniff the prefix for NUL bytes (UTF-16
    ///   BOMs excepted) and refuse them up front.
    static func fileExistsOnDisk(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? UInt64,
              size <= maxFileBytes
        else { return false }
        guard let handle = FileHandle(forReadingAtPath: resolved) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 8192)) ?? Data()
        if prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0xFE, 0xFF]) { return true }
        return !prefix.contains(0)
    }
}

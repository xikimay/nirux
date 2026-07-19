import Foundation

/// Validated payload of a `nirux://open-editor` URL. URL handlers are
/// callable by any app on the system, so parsing is strict: the path must
/// be absolute and point at an existing regular file, and line numbers are
/// clamped to a sane range. The path is never handed to a shell.
struct OpenEditorRequest: Equatable {
    let file: String
    let line: Int?
    let endLine: Int?
    let workspaceID: String?

    /// Upper bound for line numbers — far above any real file, low enough
    /// to reject garbage like Int.max from a hostile caller.
    static let maxLine = 10_000_000

    /// URL-triggered opens are non-interactive (no large-file confirmation
    /// dialog), so refuse outright what EditorColumn would ask about —
    /// mirrors EditorColumn.largeFileWarningBytes.
    static let maxFileBytes: UInt64 = 5_000_000

    /// `isOpenableFile` must return true only for paths that exist and are
    /// regular files (not directories). Injectable for tests.
    init?(
        queryItems: [URLQueryItem]?,
        isOpenableFile: (String) -> Bool = OpenEditorRequest.fileExistsOnDisk
    ) {
        func value(_ name: String) -> String? {
            queryItems?.first(where: { $0.name == name })?.value
        }
        guard let rawPath = value("file"), rawPath.hasPrefix("/") else { return nil }
        let path = Self.resolveDotSegments(rawPath)
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
    /// trailing slashes. Deliberately NOT standardizingPath: that strips a
    /// "/private" prefix, so a file already open under its /private/tmp
    /// spelling (terminal links) would get a second divergent tab for the
    /// same inode under /tmp.
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

    /// Regular files only, capped in size: a FIFO or device node (reachable
    /// directly or via symlink) would hang or flood the synchronous
    /// main-thread read in EditorColumn — attributesOfItem doesn't follow
    /// the final symlink, so resolve the whole path first.
    static func fileExistsOnDisk(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? UInt64
        else { return false }
        return size <= maxFileBytes
    }
}

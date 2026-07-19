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
        let path = (rawPath as NSString).standardizingPath
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

    private static func fileExistsOnDisk(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

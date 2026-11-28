import Foundation

/// An editor of the user's own that opens a file at a line and column through
/// its URL scheme, with no command-line tool to install: Zed, Cursor, VS Code.
struct ExternalEditor: Equatable, Sendable {
    let name: String
    let bundleID: String
    let scheme: String

    static let all = [
        ExternalEditor(name: "Zed", bundleID: "dev.zed.Zed", scheme: "zed"),
        ExternalEditor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", scheme: "cursor"),
        ExternalEditor(name: "VS Code", bundleID: "com.microsoft.VSCode", scheme: "vscode")
    ]

    static func withBundleID(_ bundleID: String?) -> ExternalEditor? {
        all.first { $0.bundleID == bundleID }
    }

    /// `path` (absolute), at `line` and `column` (1-based) when given: all
    /// three read `<scheme>://file<path>:<line>:<column>`.
    func url(path: String, line: Int? = nil, column: Int? = nil) -> URL? {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let position = line.map { ":\($0)" + (column.map { ":\($0)" } ?? "") } ?? ""
        return URL(string: "\(scheme)://file\(encoded)\(position)")
    }
}

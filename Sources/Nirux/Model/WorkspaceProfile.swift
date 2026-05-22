import Foundation

struct WorkspaceProfile: Codable, Equatable {
    static let defaultID = "default"
    static let defaultProfile = WorkspaceProfile(id: defaultID, name: "main", colorHex: "#7AA2F7")

    private static let palette = [
        "#7AA2F7", "#9ECE6A", "#E0AF68", "#F7768E",
        "#BB9AF7", "#2AC3DE", "#FF9E64", "#73DACA"
    ]

    var id: String
    var name: String
    var colorHex: String

    static func colorHex(for index: Int) -> String {
        palette[index % palette.count]
    }
}

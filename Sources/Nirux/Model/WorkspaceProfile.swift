import Foundation

struct WorkspaceProfile: Codable, Equatable {
    static let defaultID = "default"
    static let defaultProfile = WorkspaceProfile(id: defaultID, name: "main", colorHex: "#7AA2F7")

    /// Space colors, in the order new spaces take them.
    static let palette: [(name: String, hex: String)] = [
        ("Blue", "#7AA2F7"), ("Green", "#9ECE6A"), ("Yellow", "#E0AF68"), ("Red", "#F7768E"),
        ("Purple", "#BB9AF7"), ("Cyan", "#2AC3DE"), ("Orange", "#FF9E64"), ("Teal", "#73DACA")
    ]

    var id: String
    var name: String
    var colorHex: String

    static func colorHex(for index: Int) -> String {
        palette[index % palette.count].hex
    }
}

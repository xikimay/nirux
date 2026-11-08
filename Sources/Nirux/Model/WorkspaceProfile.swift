import Foundation

struct WorkspaceProfile: Codable, Equatable {
    static let defaultID = "default"
    /// General, the space that can't be deleted (docs/spaces.md).
    static let defaultProfile = WorkspaceProfile(id: defaultID, name: "General", colorHex: "#7AA2F7")
    /// The default space's name before November 2026.
    static let legacyDefaultName = "main"

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

    /// The spaces read at launch, the default one renamed "General" while it
    /// still has its old built-in name. A name the user chose stays, and so
    /// does "main" when another space is already called General.
    static func renamingLegacyDefault(_ profiles: [WorkspaceProfile]) -> [WorkspaceProfile] {
        let generalName = defaultProfile.name
        guard let index = profiles.firstIndex(where: { $0.id == defaultID }),
              profiles[index].name == legacyDefaultName,
              !profiles.contains(where: {
                  $0.id != defaultID && $0.name.caseInsensitiveCompare(generalName) == .orderedSame
              })
        else { return profiles }
        var renamed = profiles
        renamed[index].name = generalName
        return renamed
    }
}

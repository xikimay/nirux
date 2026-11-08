import Foundation

/// A space (docs/spaces.md). `profile` is its name in the code and in what
/// is persisted.
struct WorkspaceProfile: Equatable {
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
    /// Its repositories and folders (see SpaceAnchor). Empty for most
    /// spaces, and always for the default space.
    var anchors: [SpaceAnchor] = []

    static func colorHex(for index: Int) -> String {
        palette[index % palette.count].hex
    }

    /// Where a plain new workspace of the space opens, when it has one.
    var defaultFolder: String? { anchors.defaultAnchor?.folder }
}

/// `anchors` is written only when there are some, so `state.json`'s mirror
/// and a `projects.json` without anchors stay what older builds wrote.
extension WorkspaceProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, anchors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        // Lenient: anchors this build can't read never cost the space.
        anchors = (try? container.decodeIfPresent([SpaceAnchor].self, forKey: .anchors)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(colorHex, forKey: .colorHex)
        if !anchors.isEmpty { try container.encode(anchors, forKey: .anchors) }
    }
}

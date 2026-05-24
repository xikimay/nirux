import Foundation

enum NiruxShortcuts {
    static let newTerminalKey = "t"
    static let newWorkspaceKey = "n"

    static let newTerminalDisplay = commandDisplay(newTerminalKey)
    static let newWorkspaceDisplay = commandDisplay(newWorkspaceKey)

    private static func commandDisplay(_ key: String) -> String {
        "\u{2318}\(key.uppercased())"
    }
}

import AppKit

extension CodingAgent {
    /// Its desktop app's icon, when the app is installed.
    @MainActor var appIcon: NSImage? { Self.appIcons[self] }

    @MainActor private static let appIcons: [CodingAgent: NSImage] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { agent in
            agent.appBundleID
                .flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
                .map { (agent, NSWorkspace.shared.icon(forFile: $0.path)) }
        }
    )
}

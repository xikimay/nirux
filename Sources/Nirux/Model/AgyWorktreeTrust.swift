import Foundation

enum AgyWorktreeTrust {
    /// Git records the link in both directions. A folder's own .git file alone
    /// cannot establish that it belongs to a trusted checkout.
    static func settings(for directory: String, home: String) -> String? {
        guard let folder = directory.realPath, let root = AgentSessionRecord.checkoutRoot(containing: folder) else { return nil }
        let layout = GitRepositoryLayout.resolve(worktreeRoot: root)
        guard let gitDir = layout.gitDirectory, let commonDir = layout.commonDirectory else { return nil }
        let registration = URL(fileURLWithPath: gitDir, isDirectory: true)
        let worktrees = registration.deletingLastPathComponent()
        let common = worktrees.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees", common.path == commonDir, common.lastPathComponent == ".git",
              let pointer = try? String(contentsOf: registration.appendingPathComponent("gitdir"), encoding: .utf8)
        else { return nil }
        let backlink = URL(fileURLWithPath: pointer.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: registration)
        guard backlink.standardizedFileURL.path == root + "/.git" else { return nil }

        struct Settings: Decodable { let trustedWorkspaces: [String] }
        let file = URL(fileURLWithPath: home).appendingPathComponent(".gemini/antigravity-cli/settings.json")
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data),
              settings.trustedWorkspaces.contains(common.deletingLastPathComponent().path),
              let session = try? JSONEncoder().encode(["trustedWorkspaces": [folder]]) else { return nil }
        return String(decoding: session, as: UTF8.self)
    }
}

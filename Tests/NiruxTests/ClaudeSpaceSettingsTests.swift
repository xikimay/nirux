import XCTest
@testable import Nirux

/// The settings a space hands its Claude Code sessions with `--settings`
/// (Space Settings › Safety).
final class ClaudeSpaceSettingsTests: XCTestCase {
    private let app = ClaudeSpaceSettings.Repository(path: "/Users/me/Projects/app", remotes: ["github.com/acme/app"])

    /// The rules, pinned. On Claude Code 2.1.326 they refused each of these
    /// lines, which ran once the rules were gone: `cd x && git reset --hard`,
    /// `git status --short; git reset --hard HEAD`, `(cd x && git reset -q
    /// --hard)`, `echo $(git reset --hard)`, `git push --force origin main`,
    /// `git push origin main --force`, `git push -f`, `true && git push
    /// --force-with-lease`, `git checkout -- .`, `echo go | git restore .`,
    /// `git clean -fd`, `git clean -dn`, `git clean --force`, `git worktree
    /// remove ../elsewhere`, `cat .env`, `cat ~/.ssh/…`, and the Read tool on
    /// `.env`; `git status`, `git clean -n` and `git log` still ran.
    func testTheDefaultFileTrustsTheRepositoriesAndRefusesWhatCantBeUndone() throws {
        let file = try XCTUnwrap(ClaudeSpaceSettings.file(SpaceDefaults(), repositories: [app]))
        XCTAssertEqual(file.autoMode?.environment, [
            "$defaults",
            "**Trusted repo**: github.com/acme/app, checked out at /Users/me/Projects/app, and its worktrees"
        ])
        XCTAssertEqual(file.permissions?.deny, [
            "Read(**/.env)", "Read(**/.env.*)", "Edit(**/.env)", "Edit(**/.env.*)",
            "Read(~/.ssh/**)", "Edit(~/.ssh/**)",
            "Bash(git push --force*)", "Bash(git push -f*)", "Bash(git push * --force*)", "Bash(git push * -f*)",
            "Bash(git reset --hard*)", "Bash(git reset * --hard*)",
            "Bash(git checkout -- .*)", "Bash(git restore .*)",
            "Bash(git clean -f*)", "Bash(git clean -d*)", "Bash(git clean -x*)", "Bash(git clean --force*)",
            "Bash(git worktree remove*)"
        ])
        XCTAssertNil(file.sandbox, "the user's own sandbox setting holds")

        // The names Claude Code reads.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["autoMode", "permissions"])
        XCTAssertNotNil((json["autoMode"] as? [String: Any])?["environment"] as? [String])
        XCTAssertNotNil((json["permissions"] as? [String: Any])?["deny"] as? [String])
    }

    func testEachPartHasItsOwnSwitch() throws {
        var defaults = SpaceDefaults()
        defaults.set(.trustRepositories, on: false)
        defaults.set(.denyIrreversible, on: false)
        XCTAssertNil(ClaudeSpaceSettings.file(defaults, repositories: [app]))

        defaults.set(.sandbox, on: true)
        let sandboxed = ClaudeSpaceSettings.File(sandbox: .init(enabled: true))
        XCTAssertEqual(ClaudeSpaceSettings.file(defaults, repositories: [app]), sandboxed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sandboxed)) as? [String: Any])
        XCTAssertEqual((json["sandbox"] as? [String: Any])?["enabled"] as? Bool, true)

        XCTAssertNil(ClaudeSpaceSettings.file(SpaceDefaults(), repositories: [])?.autoMode, "no repository, nothing to trust")
        let local = ClaudeSpaceSettings.Repository(path: "/tmp/notes", remotes: [])
        XCTAssertEqual(
            ClaudeSpaceSettings.environmentEntry(local), "**Trusted repo**: the local repository at /tmp/notes, and its worktrees"
        )
    }

    /// A switch at its default writes nothing; the others round-trip and
    /// leave the file writable.
    func testTheSwitchesAreStoredInDefaultsJSON() throws {
        var defaults = SpaceDefaults()
        defaults.set(.denyIrreversible, on: false)
        defaults.set(.sandbox, on: true)
        defaults.set(.trustRepositories, on: true)
        XCTAssertEqual(defaults.claudeDeniesIrreversible, false)
        XCTAssertEqual(defaults.claudeSandbox, true)
        XCTAssertNil(defaults.claudeTrustsRepositories)

        let loaded = SpaceDefaultsStore.decode(try JSONEncoder().encode(defaults))
        XCTAssertEqual(loaded.status, .loaded)
        XCTAssertEqual(loaded.defaults, defaults)

        let odd = SpaceDefaultsStore.decode(Data(#"{"schemaVersion": 1, "claudeSandbox": "yes"}"#.utf8))
        XCTAssertEqual(odd.status, .readOnly(.unknownSettings(["claudeSandbox"])))
        XCTAssertFalse(odd.defaults.isOn(.sandbox))
    }

    /// `host/owner/name` only: a URL may carry a token.
    func testRemotesNameTheRepositoryNeverTheURL() {
        let config = """
        [core]
        \turl = https://github.com/core/ignored.git
        [remote "origin"]
        \turl = https://x-access-token:SECRET@github.com/Acme/App.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "upstream"]
        \turl = "git@github.com:upstream/app.git"
        [remote "mirror"]
        \turl = ssh://git@github.com/acme/app
        [remote "local"]
        \turl = /Users/me/backup/app.git
        [submodule "vendor"]
        \turl = https://github.com/vendor/lib.git
        """
        XCTAssertEqual(ClaudeSpaceSettings.remotes(gitConfig: config), ["github.com/acme/app", "github.com/upstream/app"])
    }

    /// The file a launch names is rewritten each time; switched off, it
    /// holds `{}` for the commands that still name it.
    func testPrepareWritesTheFileAndEmptiesItWhenNothingIsOn() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-claude-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let gitDir = state.appendingPathComponent("app/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n\turl = git@github.com:acme/app.git\n".utf8).write(to: gitDir.appendingPathComponent("config"))
        let anchors = [SpaceAnchor.repository(commonDir: gitDir.path, topLevel: nil), SpaceAnchor.folder("/tmp")]

        let path = try XCTUnwrap(ClaudeSpaceSettings.prepare(spaceID: "S1", defaults: SpaceDefaults(), anchors: anchors, stateDirectory: state))
        XCTAssertEqual(path, state.appendingPathComponent("projects/S1/claude-settings.json").path)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual((written["autoMode"] as? [String: Any])?["environment"] as? [String], [
            "$defaults", "**Trusted repo**: github.com/acme/app, checked out at \(gitDir.deletingLastPathComponent().path), and its worktrees"
        ])

        var off = SpaceDefaults()
        off.set(.trustRepositories, on: false)
        off.set(.denyIrreversible, on: false)
        XCTAssertNil(ClaudeSpaceSettings.prepare(spaceID: "S1", defaults: off, anchors: anchors, stateDirectory: state))
        let emptied = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        XCTAssertEqual(emptied?.isEmpty, true)
        XCTAssertNil(ClaudeSpaceSettings.prepare(spaceID: "S2", defaults: off, anchors: anchors, stateDirectory: state))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("projects/S2").path))
    }

    @MainActor
    func testTheLaunchNamesTheFile() {
        XCTAssertEqual(
            NiruxShellView.claudeCommand(mode: .default, settingsFile: "/state/projects/S1/claude-settings.json", niruxExecutable: nil),
            "command claude '--settings=/state/projects/S1/claude-settings.json'"
        )
    }
}

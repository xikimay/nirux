import XCTest
@testable import Nirux

/// The settings a space hands its Claude Code sessions with `--settings`
/// (Space Settings › Safety).
final class ClaudeSpaceSettingsTests: XCTestCase {
    private let app = ClaudeSpaceSettings.Repository(path: "/Users/me/Projects/app", remotes: ["github.com/acme/app"])

    /// The rules, pinned. On Claude Code 2.1.326 they refused each of these
    /// lines, which ran once the rules were gone: `git -C x reset --hard`,
    /// `git reset -q --hard`, `cd x && git reset --hard`, `git --no-pager
    /// push --force origin main`, `git push origin main --force`, `git push
    /// --force-with-lease`, `git -c core.x=y push -f`, `git push origin
    /// +main`, `git checkout .`, `git checkout -- ./`, `git checkout HEAD --
    /// .`, `git restore -- .`, `git restore --worktree .`, `git -C x restore
    /// .`, `git restore --staged .`, `git clean -qfd`, `git clean -e keep
    /// -fd`, `git -C x clean --force`, `git clean -n`, `git -C . worktree
    /// remove ../elsewhere`, `cat x/../.env`. These still ran: `git commit -m
    /// "clean up the docs"`, `git push --follow-tags`, `git push origin
    /// feature-foo`, `git restore .gitignore`, `git restore --staged a.txt`,
    /// `git checkout -- a.txt`, `git checkout -b feat/x`, `git status`.
    func testTheDefaultFileTrustsTheRepositoriesAndRefusesWhatCantBeUndone() throws {
        let file = try XCTUnwrap(ClaudeSpaceSettings.file(SpaceDefaults(), repositories: [app]))
        XCTAssertEqual(file.autoMode?.environment, [
            "$defaults",
            "**Trusted repo**: github.com/acme/app, checked out at /Users/me/Projects/app, and its worktrees"
        ])
        XCTAssertEqual(file.permissions?.deny, [
            "Read(**/.env)", "Read(**/.env.*)", "Edit(**/.env)", "Edit(**/.env.*)",
            "Read(~/.ssh/**)", "Edit(~/.ssh/**)",
            "Bash(git *push --force*)", "Bash(git *push -f*)",
            "Bash(git *push * --force*)", "Bash(git *push * -f*)", "Bash(git *push * +*)",
            "Bash(git *reset *--hard*)", "Bash(git *clean -*)", "Bash(git *worktree remove*)",
            "Bash(git *checkout *.)", "Bash(git *checkout *./)", "Bash(git *restore *.)", "Bash(git *restore *./)"
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

    /// Claude Code joins the user's `autoMode.environment` with ours and puts
    /// its own entries at the first "$defaults": a user list without one
    /// replaced them on purpose.
    func testClaudeCodesOwnEntriesStayAsTheUserLeftThem() {
        let ours = ClaudeSpaceSettings.environmentEntry(app)
        for user: [String]? in [nil, []] {
            XCTAssertEqual(ClaudeSpaceSettings.file(SpaceDefaults(), repositories: [app], userEnvironment: user)?.autoMode?.environment, ["$defaults", ours])
        }
        for user in [["**Trusted repo**: mine"], ["$defaults", "**Trusted repo**: mine"]] {
            XCTAssertEqual(ClaudeSpaceSettings.file(SpaceDefaults(), repositories: [app], userEnvironment: user)?.autoMode?.environment, [ours])
        }
        XCTAssertEqual(ClaudeSpaceSettings.userEnvironment(["autoMode": ["environment": ["a"]]]), ["a"])
        XCTAssertNil(ClaudeSpaceSettings.userEnvironment(["permissions": [:]]))
    }

    /// A defaults.json, or a trust switch, Nirux can't read trusts nothing,
    /// and so does a save that replaces it; the deny rules stay.
    func testWhatNiruxCantReadTrustsNothing() throws {
        for text in ["{ not json", #"{"schemaVersion": 1, "claudeTrustsRepositories": "no"}"#] {
            let loaded = SpaceDefaultsStore.decode(Data(text.utf8))
            XCTAssertFalse(loaded.defaults.isOn(.trustRepositories), text)
            XCTAssertTrue(loaded.defaults.isOn(.denyIrreversible), text)
        }
        XCTAssertTrue(SpaceDefaultsStore.decode(Data(#"{"schemaVersion": 1, "later": 1}"#.utf8)).defaults.isOn(.trustRepositories))

        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-unread-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let store = try XCTUnwrap(SpaceDefaultsStore(spaceID: "S1", stateDirectory: state))
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertFalse(store.load().defaults.isOn(.trustRepositories), "not a regular file")
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

    /// Only `origin`, as `host/owner/name`: a fork's upstream isn't the
    /// user's, and a URL may carry a token.
    func testOnlyOriginIsTrustedNeverItsURL() {
        let config = """
        [core]
        \turl = https://github.com/core/ignored.git
        [remote "upstream"]
        \turl = git@github.com:upstream/app.git
        [Remote "origin"]
        \turl = https://x-access-token:SECRET@github.com/Acme/App.git # mine
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [submodule "vendor"]
        \turl = https://github.com/vendor/lib.git
        """
        XCTAssertEqual(ClaudeSpaceSettings.origin(gitConfig: config), "github.com/acme/app")
        XCTAssertEqual(ClaudeSpaceSettings.origin(gitConfig: "[remote \"origin\"]\n\turl = \"git@github.com:a/b.git\""), "github.com/a/b")
        XCTAssertNil(ClaudeSpaceSettings.origin(gitConfig: "[remote \"origin\"]\n\turl = file:///Users/me/backup/app.git"))
        XCTAssertNil(ClaudeSpaceSettings.origin(gitConfig: "[remote \"origin\"]\n\turl = /Users/me/backup/app.git"))
        XCTAssertNil(ClaudeSpaceSettings.origin(gitConfig: "[remote \"upstream\"]\n\turl = git@github.com:a/b.git"))
    }

    /// The file a launch names is rewritten when it changes; switched off, it
    /// holds `{}` for the commands that still name it.
    func testPrepareWritesTheFileAndEmptiesItWhenNothingIsOn() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-claude-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let gitDir = state.appendingPathComponent("app/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n\turl = git@github.com:acme/app.git\n".utf8).write(to: gitDir.appendingPathComponent("config"))
        let anchors = [SpaceAnchor.repository(commonDir: gitDir.path, topLevel: nil), SpaceAnchor.folder("/tmp")]

        let path = try XCTUnwrap(ClaudeSpaceSettings.prepare(
            spaceID: "S1", defaults: SpaceDefaults(), anchors: anchors, userEnvironment: nil, stateDirectory: state
        ))
        XCTAssertEqual(path, state.appendingPathComponent("projects/S1/claude-settings.json").path)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual((written["autoMode"] as? [String: Any])?["environment"] as? [String], [
            "$defaults", "**Trusted repo**: github.com/acme/app, checked out at \(gitDir.deletingLastPathComponent().path), and its worktrees"
        ])
        // The same content leaves the file as it is.
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: path)
        _ = ClaudeSpaceSettings.prepare(spaceID: "S1", defaults: SpaceDefaults(), anchors: anchors, userEnvironment: nil, stateDirectory: state)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date, past)

        var off = SpaceDefaults()
        off.set(.trustRepositories, on: false)
        off.set(.denyIrreversible, on: false)
        XCTAssertNil(ClaudeSpaceSettings.prepare(spaceID: "S1", defaults: off, anchors: anchors, userEnvironment: nil, stateDirectory: state))
        let emptied = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        XCTAssertEqual(emptied?.isEmpty, true)
        XCTAssertNil(ClaudeSpaceSettings.prepare(spaceID: "S2", defaults: off, anchors: anchors, userEnvironment: nil, stateDirectory: state))
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

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
    /// Then refused: `cat ../outside/.env`, `cat /abs/outside/.env.local` and
    /// the Read tool on an outside `.env` (the rules without `//` let them
    /// through), `git stash drop`, `git stash clear`, `git -C x stash drop`,
    /// `git checkout -f main`, `git checkout --force main`, `git switch -f
    /// main`, `git switch --force main`, `git switch --discard-changes main`,
    /// `git push --delete origin x`, `git push origin --delete x`, `git push
    /// -d origin x`, `git push origin -d x`, `git push --mirror`, `git push
    /// origin --mirror`. Still ran: `cat ../outside/notes.txt`, `git stash
    /// list`, `git switch main`, `git push --dry-run`, `git checkout -b
    /// feat-fix`, `git push origin feature-d`.
    func testTheDefaultFileTrustsTheRepositoriesAndRefusesWhatCantBeUndone() throws {
        let file = try XCTUnwrap(ClaudeSpaceSettings.file(SpaceDefaults(), repositories: [app]))
        XCTAssertEqual(file.autoMode?.environment, [
            "$defaults",
            "**Trusted repo**: github.com/acme/app, checked out at /Users/me/Projects/app, and its worktrees"
        ])
        XCTAssertEqual(file.permissions?.deny, [
            "Read(//**/.env)", "Read(//**/.env.*)", "Edit(//**/.env)", "Edit(//**/.env.*)",
            "Read(~/.ssh/**)", "Edit(~/.ssh/**)",
            "Bash(git *push --force*)", "Bash(git *push -f*)",
            "Bash(git *push * --force*)", "Bash(git *push * -f*)", "Bash(git *push * +*)",
            "Bash(git *push --delete*)", "Bash(git *push * --delete*)", "Bash(git *push -d *)", "Bash(git *push * -d *)",
            "Bash(git *push --mirror*)", "Bash(git *push * --mirror*)",
            "Bash(git *reset *--hard*)", "Bash(git *clean -*)", "Bash(git *worktree remove*)",
            "Bash(git *checkout *.)", "Bash(git *checkout *./)", "Bash(git *checkout -f*)", "Bash(git *checkout --force*)",
            "Bash(git *switch -f*)", "Bash(git *switch --force*)", "Bash(git *switch --discard-changes*)",
            "Bash(git *restore *.)", "Bash(git *restore *./)", "Bash(git *stash drop*)", "Bash(git *stash clear*)"
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

    /// A defaults.json, or a switch, Nirux can't read takes each switch's
    /// safe side, and so does a save that replaces it.
    func testWhatNiruxCantReadTakesTheSafeSide() throws {
        let unreadable = SpaceDefaultsStore.decode(Data("{ not json".utf8)).defaults
        XCTAssertFalse(unreadable.isOn(.trustRepositories))
        XCTAssertTrue(unreadable.isOn(.denyIrreversible))
        XCTAssertTrue(unreadable.isOn(.sandbox), "a sandbox the user may have turned on")
        XCTAssertFalse(unreadable.leadStartsTasksWithoutAsking)
        let garbledSwitches = SpaceDefaultsStore.decode(Data(
            #"{"schemaVersion": 1, "claudeTrustsRepositories": "no", "claudeSandbox": 0, "claudeDeniesIrreversible": "x", "leadStartsTasks": 1}"#.utf8
        )).defaults
        XCTAssertFalse(garbledSwitches.isOn(.trustRepositories))
        XCTAssertTrue(garbledSwitches.isOn(.sandbox))
        XCTAssertTrue(garbledSwitches.isOn(.denyIrreversible))
        XCTAssertFalse(garbledSwitches.leadStartsTasksWithoutAsking)
        XCTAssertTrue(SpaceDefaultsStore.decode(Data(#"{"schemaVersion": 1, "later": 1}"#.utf8)).defaults.isOn(.trustRepositories))
        let newer = SpaceDefaultsStore.decode(Data(#"{"schemaVersion": 2, "claudeTrustsRepositories": {"mode": "off"}}"#.utf8))
        XCTAssertEqual(newer.status, .readOnly(.newerSchema(2)))
        XCTAssertFalse(newer.defaults.isOn(.trustRepositories), "a newer build's switch Nirux can't read")
        let garbled = SpaceDefaultsStore.decode(Data(#"{"schemaVersion": 1, "claudeTrustsRepositories": "no"}"#.utf8))
        XCTAssertEqual(garbled.status, .readOnly(.unknownSettings(["claudeTrustsRepositories"])), "never rewritten")

        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-unread-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let store = try XCTUnwrap(SpaceDefaultsStore(spaceID: "S1", stateDirectory: state))
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertFalse(store.load().defaults.isOn(.trustRepositories), "not a regular file")
        XCTAssertTrue(store.load().defaults.isOn(.sandbox), "not a regular file")
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
    }

    /// Exactly where `origin` pushes: the whole path, its `pushurl`s when
    /// set, never another remote, a token or a local path.
    func testTheTrustedRepositoryIsWhereOriginPushes() {
        let config = """
        [core]
        \turl = https://github.com/core/ignored.git
        [remote "upstream"]
        \turl = git@github.com:upstream/app.git
        [remote "Origin"]
        \turl = git@github.com:look/alike.git
        [REMOTE "origin"]
        \turl = https://x-access-token:SECRET@GitLab.com/Group/Sub/App.git # mine
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [submodule "vendor"]
        \turl = https://github.com/vendor/lib.git
        """
        XCTAssertEqual(ClaudeSpaceSettings.originPushTargets(gitConfig: config), ["gitlab.com/Group/Sub/App"])
        let pushes = "[remote \"origin\"]\n\turl = git@github.com:acme/app.git\n\tpushUrl = \"ssh://git@code.acme.dev:2222/team/app.git\"\n\tpushurl = git@github.com:acme/app.git"
        XCTAssertEqual(ClaudeSpaceSettings.originPushTargets(gitConfig: pushes), ["code.acme.dev:2222/team/app", "github.com/acme/app"])
        XCTAssertEqual(ClaudeSpaceSettings.originPushTargets(gitConfig: "[remote \"origin\"]\n\turl = file:///Users/me/backup/app.git"), [])
        XCTAssertEqual(ClaudeSpaceSettings.originPushTargets(gitConfig: "[remote \"origin\"]\n\turl = /Users/me/backup/app.git"), [])
        XCTAssertEqual(ClaudeSpaceSettings.originPushTargets(gitConfig: "[remote \"upstream\"]\n\turl = git@github.com:a/b.git"), [])
    }

    /// The file a launch names is rewritten when it changes; with nothing
    /// on, a new launch passes none, and the file holds `{}` for the launch
    /// lines that still name it (a column's restart replays its line).
    func testPrepareWritesTheFileAndEmptiesItWhenNothingIsOn() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-claude-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let gitDir = state.appendingPathComponent("app/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n\turl = git@github.com:acme/app.git\n".utf8).write(to: gitDir.appendingPathComponent("config"))
        let anchors = [SpaceAnchor.repository(commonDir: gitDir.path, topLevel: nil), SpaceAnchor.folder("/tmp")]

        let path = try XCTUnwrap(try ClaudeSpaceSettings.prepare(
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
        _ = try ClaudeSpaceSettings.prepare(spaceID: "S1", defaults: SpaceDefaults(), anchors: anchors, userEnvironment: nil, stateDirectory: state)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date, past)

        var off = SpaceDefaults()
        off.set(.trustRepositories, on: false)
        off.set(.denyIrreversible, on: false)
        XCTAssertNil(try ClaudeSpaceSettings.prepare(spaceID: "S1", defaults: off, anchors: anchors, userEnvironment: nil, stateDirectory: state))
        let emptied = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        XCTAssertEqual(emptied?.isEmpty, true, "a replayed launch line still finds its file")
        XCTAssertNil(try ClaudeSpaceSettings.prepare(spaceID: "S2", defaults: off, anchors: anchors, userEnvironment: nil, stateDirectory: state))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("projects/S2").path))

        // A file Nirux can't write says so: the launch would lose the rules.
        try FileManager.default.createDirectory(at: state.appendingPathComponent("projects/S3/claude-settings.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ClaudeSpaceSettings.prepare(spaceID: "S3", defaults: SpaceDefaults(), anchors: [], userEnvironment: nil, stateDirectory: state))
    }

    @MainActor
    func testTheLaunchNamesTheFile() {
        XCTAssertEqual(
            NiruxShellView.claudeCommand(mode: .default, settingsFile: "/state/projects/S1/claude-settings.json", niruxExecutable: nil),
            "command claude '--settings=/state/projects/S1/claude-settings.json'"
        )
    }

    /// The Mission waiter (MissionWaitHook) goes in for a Claude Code that
    /// runs it in the background, from where Nirux runs, even when the space
    /// hands nothing else.
    @MainActor
    func testTheMissionWaiterRunsAtEachSessionStartAndTurnEndOfARecentClaude() throws {
        let mailbox = URL(fileURLWithPath: "/state dir/mission-mailbox", isDirectory: true)
        let proven = MissionWaitHook.claudeVersion
        XCTAssertNil(MissionWaitHook.claudeHooks(executable: "/Applications/Nirux.app/Contents/MacOS/Nirux", enabled: true, version: nil, mailbox: mailbox))
        XCTAssertNil(
            MissionWaitHook.claudeHooks(executable: "/Applications/Nirux.app/Contents/MacOS/Nirux", enabled: false, version: proven, mailbox: mailbox),
            "the pilot off in Settings"
        )
        XCTAssertNil(MissionWaitHook.claudeHooks(
            executable: "/Applications/Nirux.app/Contents/MacOS/Nirux", enabled: true,
            version: ClaudeCodeVersion(major: proven.major, minor: proven.minor, patch: proven.patch - 1), mailbox: mailbox
        ))
        XCTAssertNil(MissionWaitHook.claudeHooks(executable: nil, enabled: true, version: proven, mailbox: mailbox))
        func detected() -> ClaudeCodeVersion? {
            XCTFail("no detection without Nirux's binary or with the pilot off")
            return proven
        }
        XCTAssertNil(MissionWaitHook.claudeHooks(executable: nil, enabled: true, version: detected(), mailbox: mailbox))
        XCTAssertNil(MissionWaitHook.claudeHooks(executable: "/Applications/Nirux.app/Contents/MacOS/Nirux", enabled: false, version: detected(), mailbox: mailbox))
        let hooks = try XCTUnwrap(MissionWaitHook.claudeHooks(
            executable: "/Applications/Nirux.app/Contents/MacOS/Nirux", enabled: true, version: proven, mailbox: mailbox
        ))
        XCTAssertEqual(Set(hooks.keys), ["SessionStart", "Stop"])
        let waiter = try XCTUnwrap(hooks["Stop"]?.first?.hooks.first)
        XCTAssertEqual(hooks["SessionStart"]?.first?.hooks, [waiter])
        XCTAssertEqual(waiter.asyncRewake, true)
        XCTAssertEqual(waiter.timeout, MissionWaitHook.timeout)
        XCTAssertEqual(
            waiter.command,
            #"if [ -n "$NIRUX_AGENT_UUID" ] && [ -x '/Applications/Nirux.app/Contents/MacOS/Nirux' ]; then "#
                + #"exec '/Applications/Nirux.app/Contents/MacOS/Nirux' --hook mission-wait '/state dir/mission-mailbox'; "#
                + "else /bin/cat >/dev/null; fi"
        )

        var off = SpaceDefaults()
        for part in ClaudeSpaceSettings.Part.allCases { off.set(part, on: false) }
        XCTAssertNil(ClaudeSpaceSettings.file(off, repositories: [app]))
        let file = try XCTUnwrap(ClaudeSpaceSettings.file(off, repositories: [app], hooks: hooks))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["hooks"])
        let stop = try XCTUnwrap(((json["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(stop.first?["type"] as? String, "command")
        XCTAssertEqual(stop.first?["asyncRewake"] as? Bool, true)
        XCTAssertEqual(stop.first?["rewakeSummary"] as? String, MissionWaitHook.summary)
        XCTAssertEqual(stop.first?["rewakeMessage"] as? String, MissionWaitHook.preamble)
    }
}

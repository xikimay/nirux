import AppKit
import XCTest
@testable import Nirux

@MainActor
final class AgyResumeTests: XCTestCase {
    private static let uuidA = "5f0c8a52-6a0e-4d7c-9f0e-2b1f6d1c9a11"
    private static let uuidB = "0b7e3c1d-2a44-4f5e-8c6b-7d9e0f1a2b3c"
    private static let uuidSub = "9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"

    private func agyProcess(_ arguments: [String], pid: pid_t = 42, startedAt: TimeInterval = 10) -> ForegroundProcess {
        ForegroundProcess(instance: ProcessInstance(pid: pid, startedAt: startedAt), name: "agy", arguments: arguments)
    }

    // MARK: - Command generation

    func testAgyCommandHandlesSessionPickerAndFreshTargets() {
        XCTAssertEqual(
            NiruxShellView.agyCommand(resume: .session(Self.uuidA), mode: .auto),
            "command agy --conversation '\(Self.uuidA)' --mode auto"
        )
        XCTAssertEqual(
            NiruxShellView.agyCommand(resume: .picker, mode: .auto),
            "command agy --continue --mode auto"
        )
        XCTAssertEqual(
            NiruxShellView.agyCommand(resume: .picker, mode: .default),
            "command agy --continue"
        )
        XCTAssertEqual(
            NiruxShellView.agyCommand(resume: .picker, mode: .plan, model: "gemini-pro"),
            "command agy --continue --mode plan --model 'gemini-pro'"
        )
        let fresh = NiruxShellView.agyCommand(resume: nil, mode: .auto, handoverPrompt: "Read handover")
        XCTAssertEqual(fresh, "command agy --mode auto -i 'Read handover'")
        XCTAssertFalse(fresh.contains("--continue"))
        XCTAssertFalse(fresh.contains("--conversation"))
    }

    // MARK: - Restore targeting & duplicate --continue guard

    func testAgyRestoreTargetGuardsDuplicateContinuePerCwd() throws {
        var claimedIDs = Set<String>()
        var claimedCwds = Set<String>()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-agy-restore-\(UUID().uuidString)")
        let repoA = root.appendingPathComponent("repo-a")
        let repoB = root.appendingPathComponent("repo-b")
        let linkToA = root.appendingPathComponent("repo-a-link")
        try FileManager.default.createDirectory(at: repoA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkToA, withDestinationURL: repoA)
        defer { try? FileManager.default.removeItem(at: root) }

        // First un-ID'd column in repoA gets --continue (.picker); duplicates (same path, trailing slash, symlink) start fresh.
        XCTAssertEqual(
            NiruxShellView.agyRestoreTarget(
                sessionID: nil, cwd: repoA.path, claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            ),
            .picker
        )
        XCTAssertNil(
            NiruxShellView.agyRestoreTarget(
                sessionID: nil, cwd: repoA.path, claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            )
        )
        XCTAssertNil(
            NiruxShellView.agyRestoreTarget(
                sessionID: "", cwd: repoA.path + "/", claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            )
        )
        XCTAssertNil(
            NiruxShellView.agyRestoreTarget(
                sessionID: "not-a-uuid", cwd: linkToA.path, claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            )
        )

        // Exact UUID in repoA still resumes explicitly, once only; duplicate exact UUID starts fresh (never --continue).
        XCTAssertEqual(
            NiruxShellView.agyRestoreTarget(
                sessionID: Self.uuidA, cwd: repoA.path, claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            ),
            .session(Self.uuidA)
        )
        XCTAssertNil(
            NiruxShellView.agyRestoreTarget(
                sessionID: Self.uuidA, cwd: repoA.path, claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            )
        )

        // A different cwd independently claims --continue once, even after an exact session ID was claimed there.
        XCTAssertEqual(
            NiruxShellView.agyRestoreTarget(
                sessionID: Self.uuidB, cwd: repoB.path, claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            ),
            .session(Self.uuidB)
        )
        XCTAssertEqual(
            NiruxShellView.agyRestoreTarget(
                sessionID: nil, cwd: repoB.path, claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            ),
            .picker
        )
        XCTAssertNil(
            NiruxShellView.agyRestoreTarget(
                sessionID: nil, cwd: repoB.path, claimedSessionIDs: &claimedIDs, claimedContinueCwds: &claimedCwds
            )
        )
    }

    func testAgyOpeningElsewhereFallsBackToFreshNotContinue() {
        let launch = AgentLaunch.agy(resume: .session(Self.uuidA), mode: .auto, model: "m1")
        XCTAssertEqual(
            launch.openingElsewhere(["agy", "--conversation", Self.uuidA]),
            .agy(resume: nil, mode: .auto, model: "m1")
        )
        XCTAssertEqual(
            launch.openingElsewhere(["agy", "--conversation", Self.uuidB]),
            launch
        )
    }

    // MARK: - persistedAgySessionID capture & retention

    func testPersistedAgySessionIDPreservesDeferredPreparedAndProcessArgs() {
        _ = NSApplication.shared
        // 1. Deferred restored column preserves its exact session ID before lazy resume.
        let deferred = ColumnState(
            cwd: "/tmp",
            deferredAgent: DeferredAgentLaunch(
                launch: .agy(resume: .session(Self.uuidA), mode: .auto),
                title: nil,
                lastStatus: nil
            )
        )
        XCTAssertEqual(deferred.persistedAgySessionID(foregroundProcess: nil), Self.uuidA)

        let deferredContinue = ColumnState(
            cwd: "/tmp",
            deferredAgent: DeferredAgentLaunch(
                launch: .agy(resume: .picker, mode: .auto),
                title: nil,
                lastStatus: nil
            )
        )
        XCTAssertNil(deferredContinue.persistedAgySessionID(foregroundProcess: nil))

        // 2. Prepared resume matches both `--conversation <uuid>` and `--conversation=<uuid>` and retains binding.
        let prepared = ColumnState(cwd: "/tmp")
        prepared.prepareAgyResume(sessionID: Self.uuidA)
        let resumed = agyProcess(["agy", "--conversation", Self.uuidA, "--mode", "auto"], pid: 100)
        XCTAssertEqual(prepared.persistedAgySessionID(foregroundProcess: resumed), Self.uuidA)
        let resumedNoArgs = agyProcess([], pid: 100)
        XCTAssertEqual(
            prepared.persistedAgySessionID(foregroundProcess: resumedNoArgs),
            Self.uuidA,
            "retains bound ID across subsequent saves even if argv read is empty"
        )

        let preparedEquals = ColumnState(cwd: "/tmp")
        preparedEquals.prepareAgyResume(sessionID: Self.uuidB)
        let resumedEquals = agyProcess(["agy", "--conversation=\(Self.uuidB)"], pid: 101)
        XCTAssertEqual(preparedEquals.persistedAgySessionID(foregroundProcess: resumedEquals), Self.uuidB)
        XCTAssertEqual(preparedEquals.boundAgySessionID(of: resumedEquals.instance), Self.uuidB)

        // 3. Manual `--conversation <uuid>` / `--conversation=<uuid>` without prepareAgyResume or hooks.
        let manual = ColumnState(cwd: "/tmp")
        let manualSpace = agyProcess(["agy", "--mode", "auto", "--conversation", Self.uuidA], pid: 102)
        XCTAssertEqual(manual.persistedAgySessionID(foregroundProcess: manualSpace), Self.uuidA)
        XCTAssertEqual(manual.persistedAgySessionID(foregroundProcess: agyProcess([], pid: 102)), Self.uuidA)

        let manualEqCol = ColumnState(cwd: "/tmp")
        let manualEq = agyProcess(["agy", "--conversation=\(Self.uuidB)"], pid: 103)
        XCTAssertEqual(manualEqCol.persistedAgySessionID(foregroundProcess: manualEq), Self.uuidB)

        // Invalid UUID, after `--`, headless `-p`, or non-agy process are rejected.
        let strict = ColumnState(cwd: "/tmp")
        XCTAssertNil(strict.persistedAgySessionID(foregroundProcess: agyProcess(["agy", "--conversation", "not-a-uuid"], pid: 104)))
        XCTAssertNil(strict.persistedAgySessionID(foregroundProcess: agyProcess(["agy", "--", "--conversation", Self.uuidA], pid: 105)))
        XCTAssertNil(strict.persistedAgySessionID(foregroundProcess: agyProcess(["agy", "-p", "--conversation", Self.uuidA], pid: 106)))
        let other = ForegroundProcess(
            instance: ProcessInstance(pid: 107, startedAt: 10),
            name: "zsh",
            arguments: ["zsh", "--conversation", Self.uuidA]
        )
        XCTAssertNil(strict.persistedAgySessionID(foregroundProcess: other))
    }

    // MARK: - Hook tracking for --continue, /resume, and subagents

    func testAgyTrackerCapturesContinueAndResumeViaStopWithoutSubagentHijack() {
        // Fresh agy -> SessionStart binds main -> subagent SessionStart & Stop ignored -> /resume Stop updates main.
        var tracker = ForegroundSessionTracker.agy
        let fresh = agyProcess(["agy", "--mode", "auto"], pid: 201)
        XCTAssertTrue(tracker.capture(
            sessionID: Self.uuidA, eventName: .sessionStart, emitterBelongsToForegroundJob: true, foregroundProcess: fresh
        ))
        XCTAssertFalse(tracker.capture(
            sessionID: Self.uuidSub, eventName: .sessionStart, emitterBelongsToForegroundJob: true, foregroundProcess: fresh
        ))
        XCTAssertFalse(tracker.capture(
            sessionID: Self.uuidSub, eventName: .stop, emitterBelongsToForegroundJob: true, foregroundProcess: fresh
        ))
        XCTAssertEqual(tracker.sessionID(for: fresh), Self.uuidA)
        // User ran /resume to uuidB (no SessionStart fires; Stop carries uuidB).
        XCTAssertTrue(tracker.capture(
            sessionID: Self.uuidB, eventName: .stop, emitterBelongsToForegroundJob: true, foregroundProcess: fresh
        ))
        XCTAssertEqual(tracker.sessionID(for: fresh), Self.uuidB)
        XCTAssertFalse(tracker.capture(
            sessionID: Self.uuidB, eventName: .stop, emitterBelongsToForegroundJob: true, foregroundProcess: fresh
        ))

        // Continued agy (`--continue` / `-c`) ignores subagent SessionStart & Stop, then binds main on Stop.
        XCTAssertTrue(AgyLaunch.hasContinueFlag(["agy", "--continue"]))
        XCTAssertTrue(AgyLaunch.hasContinueFlag(["agy", "-c"]))
        XCTAssertTrue(AgyLaunch.hasContinueFlag(["agy", "-c", "--mode", "auto"]))
        XCTAssertFalse(AgyLaunch.hasContinueFlag(["agy", "-c", "sleep 600; :"]))
        XCTAssertFalse(AgyLaunch.hasContinueFlag(["agy", "-i", "--continue"]))
        XCTAssertFalse(AgyLaunch.hasContinueFlag(["agy", "--", "--continue"]))
        for flag in ["--continue", "-c"] {
            var continuedTracker = ForegroundSessionTracker.agy
            let continued = agyProcess(["agy", flag, "--mode", "auto"], pid: 202)
            XCTAssertFalse(continuedTracker.capture(
                sessionID: Self.uuidSub, eventName: .sessionStart, emitterBelongsToForegroundJob: true, foregroundProcess: continued
            ))
            XCTAssertFalse(continuedTracker.capture(
                sessionID: Self.uuidSub, eventName: .stop, emitterBelongsToForegroundJob: true, foregroundProcess: continued
            ))
            XCTAssertNil(continuedTracker.sessionID(for: continued))
            XCTAssertTrue(continuedTracker.capture(
                sessionID: Self.uuidA, eventName: .stop, emitterBelongsToForegroundJob: true, foregroundProcess: continued
            ))
            XCTAssertEqual(continuedTracker.sessionID(for: continued), Self.uuidA)
        }

        // Launched with `--conversation <uuidA>`: subagent SessionStart binds uuidA and suppresses subagent Stop,
        // while a later `/resume` Stop updates to uuidB.
        var resumedTracker = ForegroundSessionTracker.agy
        let resumed = agyProcess(["agy", "--conversation", Self.uuidA], pid: 203)
        XCTAssertTrue(resumedTracker.capture(
            sessionID: Self.uuidSub, eventName: .sessionStart, emitterBelongsToForegroundJob: true, foregroundProcess: resumed
        ))
        XCTAssertEqual(resumedTracker.sessionID(for: resumed), Self.uuidA)
        XCTAssertFalse(resumedTracker.capture(
            sessionID: Self.uuidSub, eventName: .stop, emitterBelongsToForegroundJob: true, foregroundProcess: resumed
        ))
        XCTAssertEqual(resumedTracker.sessionID(for: resumed), Self.uuidA)
        XCTAssertTrue(resumedTracker.capture(
            sessionID: Self.uuidB, eventName: .stop, emitterBelongsToForegroundJob: true, foregroundProcess: resumed
        ))
        XCTAssertEqual(resumedTracker.sessionID(for: resumed), Self.uuidB)
    }

    // MARK: - End-to-end restore & fresh launch flow

    private static func persistedAgyColumn(
        cwd: String,
        width: Double = 1,
        mode: AgyLaunchMode? = .auto,
        sessionID: String? = nil
    ) -> PersistedColumn {
        PersistedColumn(
            widthPreset: width, cwd: cwd, columnType: .agy, webViewURL: nil,
            claudeLaunchMode: nil, codexLaunchMode: nil, agyLaunchMode: mode, agySessionID: sessionID
        )
    }

    func testRestorePreservesDeferredAgySessionAndDeduplicatesContinueAcrossShell() throws {
        try UIFlowHarness.run { harness in
            let shell = harness.shell
            let otherRepo = harness.root + "/other-repo"
            try FileManager.default.createDirectory(atPath: otherRepo, withIntermediateDirectories: true)

            let state = PersistedState(
                workspaces: [
                    PersistedWorkspace(
                        id: "ws-unid", title: "UnID", cwd: harness.repo,
                        columns: [
                            Self.persistedAgyColumn(cwd: harness.repo, width: 0.5, mode: .auto),
                            Self.persistedAgyColumn(cwd: harness.repo, width: 0.5, mode: .auto)
                        ],
                        focusedColumnIndex: 0
                    ),
                    PersistedWorkspace(
                        id: "ws-exact", title: "Exact", cwd: harness.repo,
                        columns: [Self.persistedAgyColumn(cwd: harness.repo, mode: .plan, sessionID: Self.uuidA)],
                        focusedColumnIndex: 0
                    ),
                    PersistedWorkspace(
                        id: "ws-other", title: "Other", cwd: otherRepo,
                        columns: [Self.persistedAgyColumn(cwd: otherRepo, mode: .default)],
                        focusedColumnIndex: 0
                    )
                ],
                activeWorkspaceIndex: 0
            )
            XCTAssertTrue(Persistence.save(state))
            shell.restoreState()

            let wsUnid = try XCTUnwrap(shell.workspaces.first { $0.id == "ws-unid" })
            let wsExact = try XCTUnwrap(shell.workspaces.first { $0.id == "ws-exact" })
            let wsOther = try XCTUnwrap(shell.workspaces.first { $0.id == "ws-other" })
            XCTAssertEqual(wsUnid.columns[0].deferredAgent?.launch, .agy(resume: .picker, mode: .auto))
            XCTAssertEqual(wsUnid.columns[1].deferredAgent?.launch, .agy(resume: nil, mode: .auto))
            XCTAssertEqual(wsExact.columns[0].deferredAgent?.launch, .agy(resume: .session(Self.uuidA), mode: .plan))
            XCTAssertEqual(wsOther.columns[0].deferredAgent?.launch, .agy(resume: .picker, mode: .default))

            // Saving before lazy resume preserves the exact agySessionID on the deferred column.
            let savedExact = try XCTUnwrap(shell.persistedState().workspaces.first { $0.id == "ws-exact" }?.columns.first)
            XCTAssertEqual(savedExact.agySessionID, Self.uuidA)

            // Resuming all launches `--continue` once per cwd, `--conversation <uuid>` for exact, and fresh for duplicate.
            let beforeResume = harness.restoredAgentLaunches.count
            XCTAssertTrue(shell.resumeAllDeferredAgents())
            let resumedCommands = Array(harness.restoredAgentLaunches.dropFirst(beforeResume))
            XCTAssertEqual(resumedCommands.count, 4)
            XCTAssertTrue(resumedCommands[0].hasPrefix("command agy --continue --mode auto"), resumedCommands[0])
            XCTAssertTrue(resumedCommands[1].hasPrefix("command agy --mode auto"), resumedCommands[1])
            XCTAssertFalse(resumedCommands[1].contains("--continue"), resumedCommands[1])
            XCTAssertFalse(resumedCommands[1].contains("--conversation"), resumedCommands[1])
            XCTAssertTrue(resumedCommands[2].hasPrefix("command agy --conversation '\(Self.uuidA)' --mode plan"), resumedCommands[2])
            XCTAssertTrue(resumedCommands[3].hasPrefix("command agy --continue"), resumedCommands[3])

            // Fresh openAgent(.agy) never passes --continue or --conversation.
            let beforeOpen = harness.agentLaunches.count
            shell.openAgent(.agy)
            XCTAssertEqual(harness.agentLaunches.count, beforeOpen + 1)
            let freshCmd = try XCTUnwrap(harness.agentLaunches.last)
            XCTAssertTrue(freshCmd.hasPrefix("command agy "), freshCmd)
            XCTAssertFalse(freshCmd.contains("--continue"), freshCmd)
            XCTAssertFalse(freshCmd.contains("--conversation"), freshCmd)
        }
    }
}

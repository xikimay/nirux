import AppKit

// MARK: - CI failure triage: flaky or real (docs/ci-failure-triage.md)

/// A CI failure notification, which waits for the triage's verdict when
/// one is on its way.
struct CIFailureBanner: Equatable, Sendable {
    let workspaceID: String
    let workspaceTitle: String
    let pullRequest: Int
    let checkNames: [String]
    /// `CITriage.signature` of the red checks it reports.
    let signature: String
}

/// What the shell keeps for the triage: whether it is on, what Nirux
/// remembers of earlier runs, the triages on their way and the
/// notifications waiting for them.
@MainActor
final class CITriageCenter {
    /// Off until the app turns it on (`NiruxApp.applyCITriage`): a shell
    /// made by a test reaches neither GitHub nor a model.
    var isEnabled = false
    /// How long a notification waits for a verdict before it goes out
    /// without one: the log's download and the model take 5 to 10 s.
    var notificationHold: TimeInterval = 20
    /// Where the store is kept; tests point it elsewhere.
    var storeURL: URL = CITriageStore.url
    /// Read when first needed.
    private var loadedStore: CITriageStore?
    /// By workspace: the red checks (`CITriage.signature`) being triaged.
    var inFlight: [String: String] = [:]
    /// By workspace: the notification waiting for that triage.
    var heldBanners: [String: CIFailureBanner] = [:]

    var store: CITriageStore {
        get {
            if let loadedStore { return loadedStore }
            let store = CITriageStore.load(from: storeURL)
            loadedStore = store
            return store
        }
        set {
            guard newValue != loadedStore else { return }
            loadedStore = newValue
            newValue.save(to: storeURL)
        }
    }
}

extension NiruxShellView {
    /// The option, from Settings › Notifications. Off: no pull request
    /// says "likely flaky" any more.
    func setCITriage(enabled: Bool) {
        guard ciTriageCenter.isEnabled != enabled else { return }
        ciTriageCenter.isEnabled = enabled
        guard !enabled else { return }
        for workspace in workspaces { workspace.ciTriage = nil }
        updateSidebar()
    }

    /// After each pull request read, before its red checks are reported:
    /// learns from the runs that pass now, then gives the red checks their
    /// verdict, from what Nirux remembers of their runs or by reading
    /// them (in the background: the sidebar is refreshed when it comes).
    /// Every red check, news or not: a pull request already red at launch
    /// reads "likely flaky" too.
    func triageRedChecks(in workspace: WorkspaceState) {
        let center = ciTriageCenter
        guard center.isEnabled, let pullRequest = workspace.prInfo else { return }
        let now = Date().timeIntervalSince1970
        var store = center.store
        if store.learn(fromPassedRunsOf: CIFailure.ownRunResults(pullRequest), now: now) { center.store = store }
        let red = CIFailure.redChecks(pullRequest)
        guard !red.isEmpty else { return }
        let signature = CITriage.signature(of: red)
        guard workspace.ciTriage?.signature != signature, center.inFlight[workspace.id] != signature else { return }
        // A red check that isn't a run of this repository can't be read:
        // the failure stays one like any other.
        guard let byRun = CIFailure.redChecksByRun(pullRequest) else {
            workspace.ciTriage = (signature, .unsure)
            return
        }
        var known: [CITriage.Verdict] = []
        var unread: [(request: CITriageInvestigation.Request, signature: String)] = []
        var isModelAllowed: Bool?
        for (run, checks) in byRun {
            let runSignature = CITriage.signature(of: checks)
            let record = store.record(of: run)
            if let record, record.signature == runSignature {
                known.append(record.shown)
                continue
            }
            let allowed = isModelAllowed ?? isCITriageModelAllowed(in: workspace)
            isModelAllowed = allowed
            unread.append((CITriageInvestigation.Request(
                run: run, pullRequest: pullRequest.number,
                repositoryRoot: workspace.gitContext?.identity.repositoryRoot, isModelAllowed: allowed,
                // An earlier attempt of the same run, failed too.
                previousAttemptTests: Set((record?.tests ?? []) + (record?.earlierTests ?? [])),
                knownFlaky: store.knownFlaky(in: run.repository, now: now)
            ), runSignature))
        }
        guard !unread.isEmpty else {
            workspace.ciTriage = (signature, CITriage.combine(known))
            return
        }
        let workspaceID = workspace.id
        center.inFlight[workspaceID] = signature
        let investigate = sideEffects.investigateCIFailure
        Task { @MainActor [weak self, weak workspace] in
            var outcomes: [CITriageInvestigation.Outcome] = []
            for item in unread { outcomes.append(await investigate(item.request)) }
            guard let self else { return }
            guard let workspace else {
                // Closed meanwhile: nothing waits for this verdict.
                if self.ciTriageCenter.inFlight[workspaceID] == signature { self.ciTriageCenter.inFlight[workspaceID] = nil }
                self.ciTriageCenter.heldBanners[workspaceID] = nil
                return
            }
            self.finishCITriage(of: workspace, signature: signature, known: known, read: zip(unread, outcomes).map {
                ($0.0.request.run, $0.0.signature, $0.1)
            })
        }
    }

    /// The runs were read. When the pull request's red checks are still
    /// the ones triaged, what the runs said is shown and remembered; a
    /// verdict on a failure the pull request has moved on from (a rerun, a
    /// push) is dropped, so that it never replaces what a later triage
    /// kept.
    private func finishCITriage(
        of workspace: WorkspaceState, signature: String, known: [CITriage.Verdict],
        read: [(run: CIFailure.Run, signature: String, outcome: CITriageInvestigation.Outcome)]
    ) {
        let center = ciTriageCenter
        if center.inFlight[workspace.id] == signature { center.inFlight[workspace.id] = nil }
        let isCurrent = center.isEnabled
            && workspace.prInfo.map { CITriage.signature(of: CIFailure.redChecks($0)) } == signature
        if isCurrent {
            var store = center.store
            let now = Date().timeIntervalSince1970
            // Not a run `gh` couldn't read: that may pass, and a relaunch
            // asks again.
            for item in read where item.outcome.wasRead {
                store.keep(CITriageStore.RunRecord(
                    signature: item.signature, tests: item.outcome.tests, verdict: item.outcome.verdict, triagedAt: now
                ), of: item.run)
            }
            center.store = store
            workspace.ciTriage = (signature, CITriage.combine(known + read.map(\.outcome.verdict)))
        }
        if let banner = center.heldBanners[workspace.id], banner.signature == signature {
            center.heldBanners[workspace.id] = nil
            sideEffects.notifyCIFailure(banner, isCurrent ? workspace.ciFlakyReason : nil)
        }
        if isCurrent { updateSidebar() }
    }

    /// Posts a CI failure's notification: at once, with what the triage
    /// already said, or once the triage on its way has a verdict, or after
    /// `notificationHold` without one.
    func postCIFailureBanner(_ banner: CIFailureBanner, for workspace: WorkspaceState) {
        let center = ciTriageCenter
        guard center.isEnabled, center.inFlight[workspace.id] == banner.signature else {
            sideEffects.notifyCIFailure(banner, workspace.ciFlakyReason)
            return
        }
        center.heldBanners[workspace.id] = banner
        DispatchQueue.main.asyncAfter(deadline: .now() + center.notificationHold) { [weak self] in
            guard let self, self.ciTriageCenter.heldBanners[banner.workspaceID] == banner else { return }
            self.ciTriageCenter.heldBanners[banner.workspaceID] = nil
            self.sideEffects.notifyCIFailure(banner, nil)
        }
    }

    /// Whether a model may read this workspace's failure: one of its
    /// columns runs a `claude` that said it is on the login Nirux's own
    /// `claude -p` uses, and none runs one that said it is elsewhere (see
    /// `AgentHookEvent.onNiruxAccount`). A workspace without such an agent
    /// (a shell, Codex, a `claude` on an API key or a cloud provider) gets
    /// the rules only: its project's code never went to that account.
    func isCITriageModelAllowed(in workspace: WorkspaceState) -> Bool {
        let snapshot = ProcessSnapshot()
        var allowed = false
        for column in workspace.columns {
            switch column.isClaudeOnNiruxAccount(foregroundProcess: column.pty?.foregroundProcess(snapshot: snapshot)) {
            case true?: allowed = true
            case false?: return false
            case nil: break
            }
        }
        return allowed
    }
}

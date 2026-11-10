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
    /// How long after a run that couldn't be read, or a model that gave no
    /// answer, the failure is read again, once: `gh` signed back in, a
    /// model's rest over, the agent started.
    var retryDelay: TimeInterval = 5 * 60
    /// Where the store is kept; tests point it elsewhere.
    var storeURL: URL = CITriageStore.url
    private var loaded: (store: CITriageStore, modified: Date?)?
    /// By workspace: the red checks (`CITriage.signature`) being triaged.
    var inFlight: [String: String] = [:]
    /// By workspace: the notification waiting for that triage.
    var heldBanners: [String: CIFailureBanner] = [:]
    /// By workspace: the red checks already read a second time.
    var retried: [String: String] = [:]

    /// What the file holds: read again when it changed on disk, since a
    /// second Nirux on the same state directory writes it too.
    var store: CITriageStore {
        let modified = Self.modificationDate(of: storeURL)
        if let loaded, loaded.modified == modified { return loaded.store }
        let store = CITriageStore.load(from: storeURL)
        loaded = (store, modified)
        return store
    }

    /// Changes the store as the file has it now, and writes it when the
    /// change changed anything.
    func updateStore(_ change: (inout CITriageStore) -> Void) {
        let before = store
        var after = before
        change(&after)
        guard after != before else { return }
        after.save(to: storeURL)
        loaded = (after, Self.modificationDate(of: storeURL))
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

extension NiruxShellView {
    /// The option, from Settings › Notifications. Off: no pull request
    /// says "likely flaky" any more, and nothing more is read (a run
    /// being read is dropped before anything goes to the model).
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
        center.updateStore { _ = $0.learn(fromPassedRunsOf: CIFailure.ownRunResults(pullRequest), now: now) }
        let red = CIFailure.redChecks(pullRequest)
        guard !red.isEmpty else { return }
        let signature = CITriage.signature(of: red)
        let workspaceID = workspace.id
        guard center.inFlight[workspaceID] != signature else { return }
        if let current = workspace.ciTriage, current.signature == signature {
            // Said already; or an answer is owed, and it is time to ask
            // again (once).
            guard let retryAt = current.retryAt, now >= retryAt else { return }
            center.retried[workspaceID] = signature
        }
        // A red check that isn't a run of this repository can't be read:
        // the failure stays one like any other.
        guard let byRun = CIFailure.redChecksByRun(pullRequest) else {
            workspace.ciTriage = (signature, .unsure, nil)
            return
        }
        let store = center.store
        var known: [CITriage.Verdict] = []
        var unread: [(request: CITriageInvestigation.Request, signature: String, redChecks: [String])] = []
        var isModelAllowed: Bool?
        for (run, checks) in byRun {
            let runSignature = CITriage.signature(of: checks)
            if let record = store.record(of: run), record.signature == runSignature, record.isFinal {
                known.append(record.shown)
                continue
            }
            let allowed = isModelAllowed ?? isCITriageModelAllowed(in: workspace)
            isModelAllowed = allowed
            unread.append((CITriageInvestigation.Request(
                run: run, pullRequest: pullRequest.number,
                repositoryRoot: workspace.gitContext?.identity.repositoryRoot, isModelAllowed: allowed,
                knownFlaky: store.knownFlaky(in: run.repository, now: now)
            ), runSignature, checks.map(\.name)))
        }
        guard !unread.isEmpty else {
            workspace.ciTriage = (signature, CITriage.combine(known), nil)
            return
        }
        center.inFlight[workspaceID] = signature
        let investigate = sideEffects.investigateCIFailure
        Task { @MainActor [weak self, weak workspace] in
            var outcomes: [CITriageInvestigation.Outcome] = []
            for item in unread {
                // Turned off meanwhile: nothing more is read.
                guard self?.ciTriageCenter.isEnabled == true else { break }
                outcomes.append(await investigate(item.request) { [weak self] in
                    await MainActor.run { self?.ciTriageCenter.isEnabled == true }
                })
            }
            guard let self else { return }
            let center = self.ciTriageCenter
            if center.inFlight[workspaceID] == signature { center.inFlight[workspaceID] = nil }
            guard let workspace else {
                // Closed meanwhile: nothing waits for this verdict.
                center.heldBanners[workspaceID] = nil
                center.retried[workspaceID] = nil
                return
            }
            let read = outcomes.count == unread.count ? zip(unread, outcomes).map { ($0.0.request.run, $0.0.signature, $0.0.redChecks, $0.1) } : nil
            self.finishCITriage(of: workspace, signature: signature, known: known, read: read)
        }
    }

    /// The runs were read (`read` is nil when the option went off on the
    /// way). When the pull request's red checks are still the ones
    /// triaged, what the runs said is shown and remembered; a verdict on a
    /// failure the pull request has moved on from (a rerun, a push) is
    /// dropped, so that it never replaces what a later triage kept. A run
    /// that couldn't be read, or an answer the model still owes, is asked
    /// for once more after `retryDelay`.
    private func finishCITriage(
        of workspace: WorkspaceState, signature: String, known: [CITriage.Verdict],
        read: [(run: CIFailure.Run, signature: String, redChecks: [String], outcome: CITriageInvestigation.Outcome)]?
    ) {
        let center = ciTriageCenter
        let isCurrent = center.isEnabled && read != nil
            && workspace.prInfo.map { CITriage.signature(of: CIFailure.redChecks($0)) } == signature
        if isCurrent, let read {
            let now = Date().timeIntervalSince1970
            center.updateStore { store in
                // Not a run `gh` couldn't read: there is nothing to keep.
                for item in read where item.outcome.wasRead {
                    store.keep(CITriageStore.RunRecord(
                        signature: item.signature, redChecks: item.redChecks, tests: item.outcome.tests,
                        verdict: item.outcome.verdict, isUnanswered: item.outcome.isUnanswered, triagedAt: now
                    ), of: item.run)
                }
            }
            let isOwed = read.contains { $0.outcome.isUnanswered || !$0.outcome.wasRead }
            let retryAt = isOwed && center.retried[workspace.id] != signature ? now + center.retryDelay : nil
            workspace.ciTriage = (signature, CITriage.combine(known + read.map(\.outcome.verdict)), retryAt)
        }
        if let banner = center.heldBanners[workspace.id], banner.signature == signature {
            center.heldBanners[workspace.id] = nil
            sideEffects.notifyCIFailure(banner, isCurrent ? workspace.ciFlakyReason : nil)
        }
        if isCurrent { updateSidebar() }
    }

    /// Posts a CI failure's notification: at once, with what the triage
    /// already said, or once the triage on its way has a verdict, or after
    /// `notificationHold` without one. One waits at a time: a second
    /// failure sends the first's on its way as it is.
    func postCIFailureBanner(_ banner: CIFailureBanner, for workspace: WorkspaceState) {
        let center = ciTriageCenter
        if let waiting = center.heldBanners[workspace.id], waiting != banner {
            center.heldBanners[workspace.id] = nil
            sideEffects.notifyCIFailure(waiting, nil)
        }
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

    /// Whether a model may read this workspace's failure: in the pull
    /// request's repository, one of its columns runs a `claude` that said
    /// it is on the login Nirux's own `claude -p` uses, and none runs one
    /// that said it is elsewhere (see `AgentHookEvent.onNiruxAccount`). A
    /// `claude` working in another folder says nothing of this
    /// repository. Without such an agent (a shell, Codex, a `claude` on an
    /// API key or a cloud provider, one that hasn't said yet) the
    /// workspace gets the rules only: its project's code never went to
    /// that account.
    func isCITriageModelAllowed(in workspace: WorkspaceState) -> Bool {
        guard let root = workspace.gitContext?.identity.repositoryRoot else { return false }
        let snapshot = ProcessSnapshot()
        var allowed = false
        for column in workspace.columns {
            let foreground = column.pty?.foregroundProcess(snapshot: snapshot)
            switch column.isClaudeOnNiruxAccount(foregroundProcess: foreground, inRepository: root) {
            case true?: allowed = true
            case false?: return false
            case nil: break
            }
        }
        return allowed
    }
}

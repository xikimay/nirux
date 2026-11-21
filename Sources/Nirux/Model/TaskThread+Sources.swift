import Foundation

extension TaskThread {
    /// The thread as it reads, in time order: an open task's joins what the
    /// files say of it now; a closed task's (`sources` nil) is its file
    /// alone, frozen when it closed. An event read twice (a hook replayed, a
    /// round both recorded and joined, a task closed twice) counts once, and
    /// so does a status line that repeats the one before.
    static func thread(recorded: [Event], joining sources: Sources?) -> [Event] {
        ordered(recorded + (sources.map(events(from:)) ?? []))
    }

    /// What a closing task appends: what the files say of it, then the
    /// close, which names its pull requests (their history comes after).
    static func frozen(_ sources: Sources, closedAt: TimeInterval, pullRequests: Set<String>) -> [Event] {
        let named = pullRequests.isEmpty ? nil : pullRequests.sorted().joined(separator: "\n")
        return events(from: sources) + [Event(time: closedAt, kind: .closed, text: named)]
    }

    /// What the files Nirux keeps already say of one task (`load`).
    struct Sources: Sendable {
        /// Those whose child is the task.
        var missions: [Mission] = []
        var reviewRuns: [ReviewPass: ReviewRun] = [:]
        var findings: [ReviewFindings.Entry] = []
        /// By pull request URL.
        var followUps: [String: PRFollowUp.Entry] = [:]
        var triage: [CITriageStore.RunRecord] = []
        /// Added to the brief, their evidence citing one of the task's pull requests.
        var rules: [RuleProposal] = []
    }

    static func events(from sources: Sources) -> [Event] {
        let reviews = sources.reviewRuns.map { pass, run in
            Event(time: run.at, kind: .review, detail: pass.rawValue, ref: run.head)
        }
        let findings = sources.findings.map { entry in
            Event(
                time: entry.time, kind: .findings, by: .lead, text: entry.findings.map(\.text).joined(separator: "\n"),
                detail: entry.findings.map(\.kind).joined(separator: ", "), number: entry.round
            )
        }
        let rules = sources.rules.compactMap { proposal in
            proposal.addedAt.map { Event(time: $0, kind: .rule, by: .user, text: proposal.addedRule ?? proposal.rule, note: proposal.evidence) }
        }
        return sources.missions.flatMap(events(of:)) + reviews + findings
            + sources.followUps.flatMap { followUpEvents($1, url: $0) } + sources.triage.map(event(of:)) + rules
    }

    /// A pull request's follow-up rounds, as its task's thread keeps them.
    static func followUpEvents(_ entry: PRFollowUp.Entry, url: String) -> [Event] {
        entry.rounds.map { Event(time: $0.typedAt, kind: .followUp, by: .nirux, detail: $0.kind.rawValue, number: $0.items.count, ref: url) }
    }

    /// A triaged failure, as its task's thread keeps it.
    static func event(of record: CITriageStore.RunRecord) -> Event {
        Event(
            time: record.triagedAt, kind: .ciFailure, text: record.redChecks.joined(separator: ", "), note: record.reason,
            detail: record.verdict, number: record.pullRequest
        )
    }

    private static func events(of mission: Mission) -> [Event] {
        let parent: Author = mission.reportsToLead == true || mission.oneWay == true ? .lead : .parentTask
        return mission.events.flatMap { event -> [Event] in
            switch event.kind {
            case .question:
                let asked = Event(
                    time: event.timestamp, kind: .question, by: .agent, text: event.message, note: event.recommendation,
                    detail: event.questionKind?.rawValue, ref: event.id
                )
                guard let handedAt = event.handedToUserAt else { return [asked] }
                return [asked, Event(time: handedAt, kind: .handedToUser, by: parent, text: event.handedToUserBecause, ref: event.id)]
            case .response:
                let by: Author = event.answeredByUser == true ? .user : parent
                let accepted = event.acceptedRecommendation == true ? "accepted" : nil
                return [Event(time: event.timestamp, kind: .answer, by: by, text: event.message, detail: accepted, ref: event.inReplyTo)]
            case .instruction:
                let by: Author = event.leadSender != nil ? .lead : parent
                let expired = event.expiredAt != nil ? "expired" : nil
                return [Event(time: event.timestamp, kind: .tell, by: by, text: event.message, detail: expired, ref: event.id)]
            case .completed:
                return [Event(time: event.timestamp, kind: .result, by: .agent, text: event.message, ref: event.id)]
            case .acknowledged:
                return []
            }
        }
    }

    /// The pull request numbers an evidence cites: "#395, #417".
    static func citedPullRequests(_ evidence: String) -> Set<Int> {
        Set(evidence.split(separator: "#", omittingEmptySubsequences: false).dropFirst().compactMap { after in
            Int(after.prefix { $0.isASCII && $0.isNumber })
        })
    }

    /// A rule cites a pull request by its URL, or by its number alone in a
    /// space of one repository, where the number can't be another's.
    static func cites(_ proposal: RuleProposal, any urls: Set<String>, isSingleRepository: Bool) -> Bool {
        if urls.contains(where: {
            proposal.evidence.range(of: NSRegularExpression.escapedPattern(for: $0) + "(?![0-9])", options: .regularExpression) != nil
        }) { return true }
        guard isSingleRepository else { return false }
        let numbers = Set(urls.compactMap { CIFailure.pullRequest(url: $0)?.number })
        return !citedPullRequests(proposal.evidence).isDisjoint(with: numbers)
    }
}

extension TaskThread.Sources {
    /// Reads the files, by the task's workspace id, then by its pull
    /// requests' URLs: the Lead's findings in every space (the task may have
    /// moved), the rules of its own. Its Missions and review runs come from
    /// the app, which holds them.
    static func load(
        workspaceID: String, missions: [Mission], reviewRuns: [ReviewPass: ReviewRun], pullRequestURLs: Set<String>,
        spaceID: String, spaceIDs: [String], isSingleRepository: Bool, stateDirectory: URL
    ) -> Self {
        let triage = CITriageStore.load(from: stateDirectory.appendingPathComponent(CITriageStore.fileName))
        let followUps = PRFollowUpStore.load(from: stateDirectory.appendingPathComponent(PRFollowUpStore.fileName)).pullRequests
        return Self(
            missions: missions.filter { $0.childWorkspaceID == workspaceID },
            reviewRuns: reviewRuns,
            findings: spaceIDs.flatMap { ReviewFindings.lines.load(spaceID: $0, stateDirectory: stateDirectory) }
                .filter { $0.workspace == workspaceID },
            followUps: followUps.filter { pullRequestURLs.contains($0.key) },
            triage: pullRequestURLs.compactMap(CIFailure.pullRequest(url:)).flatMap { repository, number in
                (triage.repositories[repository.lowercased()]?.runs.values).map { $0.filter { $0.pullRequest == number } } ?? []
            },
            rules: (RuleProposalStore(spaceID: spaceID, stateDirectory: stateDirectory)?.load().proposals ?? []).filter { proposal in
                proposal.addedAt != nil && TaskThread.cites(proposal, any: pullRequestURLs, isSingleRepository: isSingleRepository)
            }
        )
    }
}

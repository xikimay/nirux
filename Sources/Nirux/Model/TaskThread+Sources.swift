import Foundation

extension TaskThread {
    /// What the files Nirux keeps already say of one task, read by its
    /// workspace id, then by its pull requests' URLs (`load`).
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
        let followUps = sources.followUps.flatMap { url, entry in
            entry.rounds.map { Event(time: $0.typedAt, kind: .followUp, by: .nirux, detail: $0.kind.rawValue, number: $0.items.count, ref: url) }
        }
        let triage = sources.triage.map { record in
            Event(
                time: record.triagedAt, kind: .ciFailure, text: record.redChecks.joined(separator: ", "), note: record.reason,
                detail: record.verdict, number: record.pullRequest
            )
        }
        let rules = sources.rules.compactMap { proposal in
            proposal.addedAt.map { Event(time: $0, kind: .rule, by: .user, text: proposal.addedRule ?? proposal.rule, note: proposal.evidence) }
        }
        return sources.missions.flatMap(events(of:)) + reviews + findings + followUps + triage + rules
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
}

extension TaskThread.Sources {
    /// Reads the files; the task's Missions, review runs and pull requests
    /// come from the app, which holds them.
    static func load(
        workspaceID: String, spaceID: String, missions: [Mission], reviewRuns: [ReviewPass: ReviewRun], pullRequestURLs: Set<String>
    ) -> Self {
        let pullRequests = pullRequestURLs.compactMap(CIFailure.pullRequest(url:))
        let numbers = Set(pullRequests.map(\.number))
        let triage = CITriageStore.load()
        let followUps = PRFollowUpStore.load().pullRequests
        return Self(
            missions: missions.filter { $0.childWorkspaceID == workspaceID },
            reviewRuns: reviewRuns,
            findings: ReviewFindings.lines.load(spaceID: spaceID).filter { $0.workspace == workspaceID },
            followUps: followUps.filter { pullRequestURLs.contains($0.key) },
            triage: pullRequests.flatMap { repository, number in
                (triage.repositories[repository.lowercased()]?.runs.values).map { $0.filter { $0.pullRequest == number } } ?? []
            },
            rules: (RuleProposalStore(spaceID: spaceID)?.load().proposals ?? []).filter { proposal in
                proposal.addedAt != nil && !TaskThread.citedPullRequests(proposal.evidence).isDisjoint(with: numbers)
            }
        )
    }
}

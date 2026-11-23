import Foundation

extension MergeQueue {
    enum Cadence: String, CaseIterable, Codable, Equatable, Sendable {
        case standard, batchPostMerge, expressDisjoint

        var toolArgument: String {
            switch self {
            case .standard: "standard"
            case .batchPostMerge: "batch_post_merge"
            case .expressDisjoint: "express_disjoint"
            }
        }

        var title: String {
            switch self {
            case .standard: "Standard"
            case .batchPostMerge: "Batch post-merge"
            case .expressDisjoint: "Express disjoint"
            }
        }
    }

    static func strictCandidateRefusal(
        for candidates: [ConfirmationReading.Candidate], settings: BoardConfig.QueueSettings, requireDisjoint: Bool
    ) -> String? {
        if requireDisjoint && candidates.count < 2 { return "Express needs at least two pull requests." }
        var owners: [String: Int] = [:]
        for candidate in candidates {
            let number = candidate.number
            guard let pr = candidate.pullRequest, pr.mergeable == "MERGEABLE" else {
                return "GitHub hasn’t confirmed that #\(number) is mergeable."
            }
            guard let checks = candidate.checks else { return "The checks for #\(number) are unknown." }
            if let reason = judge(checks, required: settings.requiredChecks).expressRefusal(number: number) { return reason }
            guard let details = candidate.details, details.head == pr.headOid, details.baseBranch == settings.baseBranch else {
                return "The changed files for the confirmed head of #\(number) are unknown."
            }
            guard !details.hasMoreFiles, details.files.count <= PullRequestDetails.maxFiles else {
                return "#\(number) changes more than \(PullRequestDetails.maxFiles) files."
            }
            guard details.allPathsKnown else { return "GitHub didn’t identify every changed path for #\(number)." }
            for path in details.files {
                let key = path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    .precomposedStringWithCanonicalMapping
                if key.hasPrefix(".github/workflows/") { return "#\(number) changes \(path)." }
                guard requireDisjoint else { continue }
                if let owner = owners[key], owner != number { return "PR #\(owner) and #\(number) both touch \(path)." }
                owners[key] = number
            }
        }
        return nil
    }
}

extension MergeQueue.ChecksVerdict {
    func expressRefusal(number: Int) -> String? {
        if !allRequiredGreen { return "Required checks for #\(number) aren’t all green." }
        if !otherFailures.isEmpty { return "Red checks for #\(number): \(otherFailures.joined(separator: ", "))." }
        return nil
    }
}

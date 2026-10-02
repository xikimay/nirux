import Foundation

/// A review pass the sidebar tracks per workspace (docs/review-badges.md).
enum ReviewPass: String, Codable, CaseIterable {
    case codeReview, premortem, codeStyleReview, adversarial

    var badge: String {
        switch self {
        case .codeReview: "CR"
        case .premortem: "PM"
        case .codeStyleReview: "CS"
        case .adversarial: "ADV"
        }
    }

    var displayName: String {
        switch self {
        case .codeReview: "Code review"
        case .premortem: "Premortem"
        case .codeStyleReview: "Code style review"
        case .adversarial: "Adversarial review"
        }
    }

    /// The passes a submitted prompt runs: the `/command` it starts with,
    /// and an adversarial review when it says "advers…" anywhere, however
    /// the rest of the word is spelled. Only the result leaves the hook
    /// receiver, never the prompt.
    static func passes(inPrompt prompt: String) -> [ReviewPass]? {
        var passes: [ReviewPass] = []
        let trimmed = prompt.drop { $0.isWhitespace }
        if trimmed.hasPrefix("/"),
           let pass = command(String(trimmed.dropFirst().prefix { !$0.isWhitespace })) {
            passes.append(pass)
        }
        if mentionsAdversarial(prompt) {
            passes.append(.adversarial)
        }
        return passes.isEmpty ? nil : passes
    }

    /// The pass a skill (Claude's `Skill` tool) runs.
    static func passes(inSkill skill: String) -> [ReviewPass]? {
        if let pass = command(skill) { return [pass] }
        return mentionsAdversarial(skill) ? [.adversarial] : nil
    }

    private static func mentionsAdversarial(_ text: String) -> Bool {
        text.range(of: "advers", options: .caseInsensitive) != nil
    }

    /// By the command's own name, the last `:` segment: a plugin's
    /// `plugin:code-review` counts.
    private static func command(_ name: String) -> ReviewPass? {
        switch name.split(separator: ":").last?.lowercased() {
        case "code-review": .codeReview
        case "premortem": .premortem
        case "code-style-review": .codeStyleReview
        default: nil
        }
    }
}

/// A pass's latest run in a workspace: its HEAD when the pass started.
struct ReviewRun: Codable, Hashable {
    let head: String
    let at: TimeInterval
}

/// What a workspace card shows: each pass's latest run, read against the
/// current HEAD. A run is fresh only on that HEAD.
struct ReviewBadges: Hashable {
    let runs: [ReviewPass: ReviewRun]
    let head: String?

    func isFresh(_ pass: ReviewPass) -> Bool {
        guard let head, let run = runs[pass] else { return false }
        return run.head == head
    }
}

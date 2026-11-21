import Foundation

extension TaskThread {
    struct Timeline: Sendable {
        enum Stage: String, CaseIterable, Sendable {
            case request = "Request", plan = "Plan", code = "Code", review = "Review", checks = "Checks", merged = "Merged"
        }

        struct Line: Sendable {
            var label: String
            var text: String
            var time: TimeInterval?
            var needsUser = false
        }

        struct Section: Sendable {
            let stage: Stage
            let entries: [Line]
        }

        let current: [Line]
        let sections: [Section]

        init(events: [Event], context: Context) {
            let questions = TaskThread.questions(in: events)
            let readableAnswers = Set(questions.filter { $0.asked.detail != "access" }.compactMap(\.asked.ref))
            var current: [Line] = []
            for (label, value, kind) in [("Status", context.status, Kind.status), ("Next", context.next, .nextStep),
                                         ("Blocker", context.blocker, .blocker)] {
                if let text = value ?? events.last(where: { $0.kind == kind })?.text, !text.isEmpty {
                    current.append(Line(label: label, text: Self.words(text)))
                }
            }
            for question in questions where question.isOpen {
                let needsUser = question.handoff != nil || question.asked.recipient == .user
                let owner = (question.asked.recipient ?? .parentTask).rawValue
                let label = needsUser ? "Needs you" : "Waiting on \(owner)"
                let text = [question.asked.text, question.asked.note].compactMap { $0 }.map(Self.words).joined(separator: "\n")
                current.append(Line(label: label, text: text, time: question.asked.time, needsUser: needsUser))
            }
            self.current = current

            var groups: [Stage: [Line]] = [:]
            var stage = Stage.plan
            for event in events {
                switch event.kind {
                case .commit, .pullRequest: stage = .code
                case .review, .prReview, .findings: stage = .review
                case .checkRun, .checks, .ciFailure: stage = .checks
                case .followUp:
                    switch event.detail {
                    case "ci": stage = .checks
                    case "conflict": stage = .code
                    default: stage = .review
                    }
                case .merged: stage = .merged
                default: break
                }
                let destination: Stage = event.kind == .request ? .request : stage
                groups[destination, default: []].append(Self.line(event, readableAnswers: readableAnswers))
            }
            sections = Stage.allCases.compactMap { stage in groups[stage].map { Section(stage: stage, entries: $0) } }
        }

        private static func words(_ text: String) -> String {
            TranscriptLastMessage.withholdingSecrets(text).text
        }

        private static func line(_ event: Event, readableAnswers: Set<String>) -> Line {
            let label: String
            switch event.kind {
            case .request: label = "Request"
            case .goal: label = "Goal"
            case .status: label = "Status"
            case .nextStep: label = "Next step"
            case .blocker: label = "Blocker"
            case .turnEnd: label = "Turn ended"
            case .closed: label = "Task closed"
            case .followUp: label = "Follow-up"
            case .ciFailure: label = "CI failure"
            case .question: label = "Question"
            case .answer: label = "Answer"
            case .tell: label = "Instruction"
            case .result: label = "Result"
            case .handedToUser: label = "Handed to you"
            case .questionRetired: label = "Question retired"
            case .review: label = "Review"
            case .findings: label = "Findings"
            case .rule: label = "Rule added"
            case .pullRequest: label = "PR opened"
            case .commit: label = "Commit"
            case .prReview: label = "PR review"
            case .checkRun: label = "Check"
            case .checks: label = "Checks"
            case .merged: label = "Merged"
            case .prClosed: label = "PR closed"
            default: label = event.kind.rawValue
            }
            var details = [event.by?.rawValue]
            if let number = event.number {
                switch event.kind {
                case .followUp: details.append("\(number) items")
                case .findings: details.append("Round \(number)")
                default: details.append("#\(number)")
                }
            }
            if event.kind != .closed { details.append(event.detail) }
            if [.commit, .review, .pullRequest].contains(event.kind) { details.append(event.ref) }
            let hidden = event.kind == .answer && (event.ref.map(readableAnswers.contains) != true)
            details += hidden ? ["Answer withheld"] : [event.text, event.note]
            return Line(label: label, text: details.compactMap { $0 }.map(words).joined(separator: " · "), time: event.time)
        }
    }
}

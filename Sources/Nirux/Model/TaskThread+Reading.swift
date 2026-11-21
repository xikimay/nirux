import Foundation

extension TaskThread {
    struct Question {
        let asked: Event
        let handoff: Event?
        let answer: Event?
        let retiredAt: TimeInterval?

        var isOpen: Bool { answer == nil && retiredAt == nil }
    }

    /// Read backwards so each question finds its own Mission's next completion, even after a tell reopened it.
    static func questions(in ordered: [Event]) -> [Question] {
        var answers: [String: Event] = [:]
        var handoffs: [String: Event] = [:]
        var completions: [String: TimeInterval] = [:]
        var close: TimeInterval?
        var questions: [Question] = []
        for event in ordered.reversed() {
            switch event.kind {
            case .closed: close = event.time
            case .result: completions[event.missionID ?? ""] = event.time
            case .answer:
                if let id = event.ref { answers[id] = event }
            case .handedToUser:
                if let id = event.ref { handoffs[id] = event }
            case .question:
                let id = event.ref ?? ""
                questions.append(Question(asked: event, handoff: handoffs[id], answer: answers[id], retiredAt: completions[event.missionID ?? ""] ?? close))
            default: break
            }
        }
        return questions.reversed()
    }

    static func canReadArchive(_ events: [Event]) -> Bool {
        if let origin = events.last(where: { $0.kind == .closed })?.detail { return origin == "local" }
        return events.contains { $0.kind == .request }
    }

    struct Context: Sendable {
        var goal: String?
        var next: String?
        var blocker: String?
        var status: String?
        var urls: Set<String> = []
        var pullRequest: PRInfo?
        var observedAt: TimeInterval?

        var pullRequestEvents: [Event] {
            guard let pr = pullRequest, urls.contains(pr.url) else { return [] }
            let opening = TaskThread.time(pr.createdAt).map { Event(time: $0, kind: .pullRequest, number: pr.number, ref: pr.url) }
            return [opening].compactMap { $0 } + TaskThread.checkRuns(pr.checks, url: pr.url, observedAt: observedAt)
        }
    }

    static func summary(_ events: [Event], title: String, context: Context) -> String {
        func quote(_ value: String, _ limit: Int = 200) -> String { DailyPass.quote(value, maxLength: limit) }
        func last(_ kind: Kind) -> String? { events.last { $0.kind == kind }?.text }
        let closed = events.contains { $0.kind == .closed }
        var lines = [(closed ? "Closed task · " : "Task · ") + quote(title)]
        func add(_ label: String, _ text: String?) {
            if let text, !text.isEmpty { lines.append(label + " · " + quote(text, 280)) }
        }
        add("Request", events.first { $0.kind == .request }?.text)
        add("Goal", context.goal ?? last(.goal))
        add("Next", context.next ?? last(.nextStep))
        add("Blocker", context.blocker ?? last(.blocker))
        var statuses = events.filter { $0.kind == .status }.compactMap(\.text)
        if let current = context.status, current != statuses.last { statuses.append(current) }
        for status in statuses.suffix(3) { add("Status", status) }

        var urls = context.urls.union(events.filter { $0.kind == .pullRequest }.compactMap(\.ref))
        if let names = last(.closed) { urls.formUnion(names.split(separator: "\n").map(String.init)) }
        for url in urls.sorted().prefix(4) {
            var detail = url
            if let pr = context.pullRequest, pr.url == url {
                detail += " · " + pr.state.word + (pr.ciStatus.map { " · checks " + $0.lowercased() } ?? "")
            }
            add("PR", detail)
        }
        if let checks = events.last(where: { $0.kind == .checks }) {
            add("Checks", [checks.detail, checks.text].compactMap { $0 }.joined(separator: " · "))
        }
        for terminal in events.filter({ $0.kind == .merged || $0.kind == .prClosed }).suffix(4) {
            if let number = terminal.number {
                lines.append((terminal.kind == .merged ? "Merged" : "Closed PR") + " · #\(number)")
            }
        }

        let questions = questions(in: events)
        for question in questions.filter(\.isOpen).suffix(3) {
            let owner = question.handoff == nil ? question.asked.recipient?.rawValue : "user"
            let who = owner.map { " (\(quote($0, 15)))" } ?? ""
            let recommendation = question.asked.note.map { " · recommendation: " + quote($0, 100) } ?? ""
            lines.append("Open" + who + " · " + quote(question.asked.text ?? "Question") + recommendation)
        }
        if let result = last(.result) { add("Result", result) }
        for question in questions.reversed() {
            guard let answer = question.answer else { continue }
            let response = question.asked.detail == "access" ? "access answer withheld" : quote(answer.text ?? "")
            let line = "Decision · " + quote(question.asked.text ?? "Question") + " → " + quote(answer.by?.rawValue ?? "parent", 16) + ": " + response
            lines.append(line)
            if lines.joined(separator: "\n").count >= LeadTools.maxReadLength { break }
        }
        if events.isEmpty && lines.count == 1 { lines.append("No recorded events.") }
        let text = lines.joined(separator: "\n")
        return text.count <= LeadTools.maxReadLength ? text : String(text.prefix(LeadTools.maxReadLength - 1)) + "…"
    }
}

import Foundation

/// A task's story from its request to its merge (docs/design/task-thread.md).
/// Nirux records only what nothing else keeps: the request, each status
/// line and context change, each turn end. The rest is joined at read from
/// the files that hold it already (`events(from:)`), and copied once, when
/// the task closes, with its pull request's history.
enum TaskThread {
    struct Event: Codable, Equatable, Sendable {
        var time: TimeInterval
        var kind: Kind
        var by: Author?
        /// The request, a line, a message; nil for a field cleared.
        var text: String?
        /// A recommendation, a reason, a pull request's title.
        var note: String?
        /// A question's kind, a verdict, a review pass, an agent.
        var detail: String?
        /// A pull request, a round, a count.
        var number: Int?
        /// The Mission event, commit or URL it is about.
        var ref: String?

        init(
            time: TimeInterval, kind: Kind, by: Author? = nil, text: String? = nil, note: String? = nil,
            detail: String? = nil, number: Int? = nil, ref: String? = nil
        ) {
            self.time = time
            self.kind = kind
            self.by = by
            self.text = text
            self.note = note
            self.detail = detail
            self.number = number
            self.ref = ref
        }

        enum CodingKeys: String, CodingKey {
            case time = "t", kind, by, text, note, detail, number = "n", ref
        }
    }

    /// Open: a kind a later build adds reads as its raw value.
    struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String

        // Recorded by Nirux.
        static let request = Kind("request")
        static let goal = Kind("goal")
        static let status = Kind("status")
        static let nextStep = Kind("nextStep")
        static let blocker = Kind("blocker")
        static let turnEnd = Kind("turnEnd")
        static let closed = Kind("closed")
        // Joined from the files that keep them.
        static let question = Kind("question")
        static let answer = Kind("answer")
        static let tell = Kind("tell")
        static let result = Kind("result")
        static let handedToUser = Kind("handedToUser")
        static let review = Kind("review")
        static let findings = Kind("findings")
        static let ciFailure = Kind("ciFailure")
        static let followUp = Kind("followUp")
        static let rule = Kind("rule")
        // The pull request's history, read from GitHub at close.
        static let pullRequest = Kind("pullRequest")
        static let commit = Kind("commit")
        static let prReview = Kind("prReview")
        static let checks = Kind("checks")
        static let merged = Kind("merged")
        static let prClosed = Kind("prClosed")

        init(rawValue: String) { self.rawValue = rawValue }
        init(_ rawValue: String) { self.rawValue = rawValue }

        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Open, like `Kind`.
    struct Author: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String

        static let user = Author("user")
        static let lead = Author("lead")
        /// The task that started this one as its sub-task.
        static let parentTask = Author("task")
        /// The task's own agent.
        static let agent = Author("agent")
        /// Nirux itself: a turn's status line, a merge clearing the Lead's context.
        static let nirux = Author("nirux")

        init(rawValue: String) { self.rawValue = rawValue }
        init(_ rawValue: String) { self.rawValue = rawValue }

        init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// The thread as it reads now, in time order. A closed task's is its
    /// file alone: it was frozen then, and the files it was joined from may
    /// have dropped it since. A turn end replayed after a relaunch counts once.
    static func thread(recorded: [Event], sources: Sources) -> [Event] {
        let isClosed = recorded.contains { $0.kind == .closed }
        return ordered(isClosed ? recorded : recorded + events(from: sources))
    }

    /// What a closing task appends: what the files say of it, then the close.
    static func frozen(_ sources: Sources, closedAt: TimeInterval) -> [Event] {
        events(from: sources) + [Event(time: closedAt, kind: .closed)]
    }

    static func ordered(_ events: [Event]) -> [Event] {
        var seenTurnEnds = Set<TimeInterval>()
        let unique = events.filter { event in
            event.kind != .turnEnd || seenTurnEnds.insert(event.time).inserted
        }
        return unique.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }
}

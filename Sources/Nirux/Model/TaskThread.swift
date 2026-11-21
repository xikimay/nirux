import Foundation

/// A task's story from its request to its merge (docs/design/task-thread.md).
/// Nirux records what nothing else keeps, or keeps only for a while: the
/// request, each status line and context change, each turn end, each
/// follow-up round and triaged failure. The rest is joined at read from the
/// files that hold it (`events(from:)`), and copied once, when the task
/// closes, with its pull request's history.
enum TaskThread {
    struct Event: Codable, Hashable, Sendable {
        var time: TimeInterval
        var kind: Kind
        var by: Author?
        /// The request, a line, a message; nil for a field cleared.
        var text: String?
        /// A recommendation, a reason, a rule's evidence.
        var note: String?
        /// A question's kind, a verdict, a review pass, an agent.
        var detail: String?
        /// A pull request, a round, a count.
        var number: Int?
        /// The Mission event, commit or URL it is about.
        var ref: String?
        var recipient: Author?
        var missionID: String?
        var until: TimeInterval?

        init(
            time: TimeInterval, kind: Kind, by: Author? = nil, text: String? = nil, note: String? = nil,
            detail: String? = nil, number: Int? = nil, ref: String? = nil, recipient: Author? = nil,
            missionID: String? = nil, until: TimeInterval? = nil
        ) {
            self.time = time
            self.kind = kind
            self.by = by
            self.text = text
            self.note = note
            self.detail = detail
            self.number = number
            self.ref = ref
            self.recipient = recipient
            self.missionID = missionID
            self.until = until
        }

        enum CodingKeys: String, CodingKey {
            case time = "t", kind, by, text, note, detail, number = "n", ref, recipient, missionID, until
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
        /// Its text names the task's pull requests, one per line.
        static let closed = Kind("closed")
        // Recorded as they happen, and joined while their file still has them.
        static let followUp = Kind("followUp")
        static let ciFailure = Kind("ciFailure")
        // Joined from the files that keep them.
        static let question = Kind("question")
        static let answer = Kind("answer")
        static let tell = Kind("tell")
        static let result = Kind("result")
        static let handedToUser = Kind("handedToUser")
        static let questionRetired = Kind("questionRetired")
        static let review = Kind("review")
        static let findings = Kind("findings")
        static let rule = Kind("rule")
        // The pull request's history, read from GitHub at close.
        static let pullRequest = Kind("pullRequest")
        static let commit = Kind("commit")
        static let prReview = Kind("prReview")
        static let checkRun = Kind("checkRun")
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

    static func ordered(_ events: [Event]) -> [Event] {
        var seen = Set<Event>()
        let unique = events.filter { seen.insert($0).inserted }
        var lastStatus: String?
        return unique.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
            .filter { event in
                guard event.kind == .status else { return true }
                defer { lastStatus = event.text }
                return event.text != lastStatus
            }
    }
}

import Foundation

/// A task's story from its request to its merge (docs/design/task-thread.md).
/// Nirux records what nothing else keeps, or keeps only for a while: the
/// request, each status line and context change, each turn end, each
/// follow-up round and triaged failure. The rest is joined at read from the
/// files that hold it (`events(from:)`), and copied once, when the task
/// closes, with its pull request's history.
public enum TaskThread {
    public struct Event: Codable, Hashable, Sendable {
        public var time: TimeInterval
        public var kind: Kind
        public var by: Author?
        /// The request, a line, a message; nil for a field cleared.
        public var text: String?
        /// A recommendation, a reason, a rule's evidence.
        public var note: String?
        /// A question's kind, a verdict, a review pass, an agent.
        public var detail: String?
        /// A pull request, a round, a count.
        public var number: Int?
        /// The Mission event, commit or URL it is about.
        public var ref: String?
        public var recipient: Author?
        public var missionID: String?
        public var until: TimeInterval?

        public init(
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
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String

        // Recorded by Nirux.
        public static let request = Kind("request")
        public static let goal = Kind("goal")
        public static let status = Kind("status")
        public static let nextStep = Kind("nextStep")
        public static let blocker = Kind("blocker")
        public static let turnEnd = Kind("turnEnd")
        /// Its text names the task's pull requests, one per line.
        public static let closed = Kind("closed")
        // Recorded as they happen, and joined while their file still has them.
        public static let followUp = Kind("followUp")
        public static let ciFailure = Kind("ciFailure")
        // Joined from the files that keep them.
        public static let question = Kind("question")
        public static let answer = Kind("answer")
        public static let tell = Kind("tell")
        public static let result = Kind("result")
        public static let handedToUser = Kind("handedToUser")
        public static let questionRetired = Kind("questionRetired")
        public static let review = Kind("review")
        public static let findings = Kind("findings")
        public static let rule = Kind("rule")
        // The pull request's history, read from GitHub at close.
        public static let pullRequest = Kind("pullRequest")
        public static let commit = Kind("commit")
        public static let prReview = Kind("prReview")
        public static let checkRun = Kind("checkRun")
        public static let checks = Kind("checks")
        public static let merged = Kind("merged")
        public static let prClosed = Kind("prClosed")

        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Open, like `Kind`.
    public struct Author: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String

        public static let user = Author("user")
        public static let lead = Author("lead")
        /// The task that started this one as its sub-task.
        public static let parentTask = Author("task")
        /// The task's own agent.
        public static let agent = Author("agent")
        /// Nirux itself: a turn's status line, a merge clearing the Lead's context.
        public static let nirux = Author("nirux")

        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public static func ordered(_ events: [Event]) -> [Event] {
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

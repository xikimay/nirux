import Foundation

/// A space's plan (docs/design/plan.md): features, the lines in them, the steps
/// under those lines, and what the Lead proposes. It changes only through the
/// methods of Plan+Changes.swift, which keep its rules.
public struct Plan: Codable, Hashable, Sendable {
    public typealias Author = TaskThread.Author

    public internal(set) var lines: [Line] = []
    /// Oldest first, until the user takes or drops them.
    public internal(set) var proposals: [Proposal] = []

    public init() {}

    public struct Line: Codable, Hashable, Sendable, Identifiable {
        /// Open: a kind a later build adds is kept as it is, and fits nowhere here.
        public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
            public let rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }

            /// A label that groups lines.
            public static let feature = Kind(rawValue: "feature")
            /// Something the user does.
            public static let todo = Kind(rawValue: "todo")
            /// Work the Lead does itself.
            public static let lead = Kind(rawValue: "lead")
            /// A task, planned until it has a workspace.
            public static let session = Kind(rawValue: "session")
            public static let step = Kind(rawValue: "step")
        }

        public let id: String
        public internal(set) var kind: Kind
        public internal(set) var title: String
        /// What a planned session starts with.
        public internal(set) var detail: String?
        /// A step the user does: it stops its session's agent.
        public internal(set) var isForUser: Bool
        public internal(set) var origin: Origin
        public internal(set) var checkedAt: TimeInterval?
        public internal(set) var workspaceID: String?
        /// The line whose check starts this planned session.
        public internal(set) var after: String?
        /// Added by someone else, and not looked at by the user since.
        public internal(set) var isUnseen = false
        public internal(set) var children: [Line] = []

        public init(
            id: String, kind: Kind, title: String, by author: Author, at time: TimeInterval, source: Source? = nil,
            detail: String? = nil, isForUser: Bool = false, workspaceID: String? = nil, after: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.isForUser = isForUser
            self.origin = Origin(by: author, at: time, source: source)
            self.workspaceID = workspaceID
            self.after = after
        }

        public var isChecked: Bool { checkedAt != nil }
        public var isPlanned: Bool { kind == .session && workspaceID == nil }
        /// What a session's agent works on: the first open line under it.
        public var current: Line? { children.first { !$0.isChecked } }
        public var progress: (done: Int, total: Int) { (children.count(where: \.isChecked), children.count) }
        public var waitsForUser: Bool { kind == .session && current.map { $0.kind == .step && $0.isForUser } == true }
    }

    public struct Origin: Codable, Hashable, Sendable {
        public var by: Author
        public var at: TimeInterval
        public var source: Source?
    }

    /// Where the Lead read a line: GitHub, Linear, Slack, Mail, Figma.
    public struct Source: Codable, Hashable, Sendable {
        public var name: String
        public var url: String?
        /// "assigned yesterday · high priority"
        public var why: String?

        public init(name: String, url: String? = nil, why: String? = nil) {
            self.name = name
            self.url = url
            self.why = why
        }
    }

    public enum Place: Codable, Hashable, Sendable {
        /// Outside any feature.
        case top
        case under(String)
        /// In the feature of this title, or in a new one with this id at the end of the plan.
        case feature(title: String, id: String)
    }

    public struct Proposal: Codable, Hashable, Sendable, Identifiable {
        public var line: Line
        public var place: Place
        public var id: String { line.id }
    }

    public func line(_ id: String) -> Line? {
        lines.path(to: id).map { lines[path: $0] }
    }

    public func line(ofWorkspace workspaceID: String) -> Line? {
        lines.flattened.first { $0.workspaceID == workspaceID }
    }

    /// Planned sessions whose `after` line is checked: theirs to start now.
    public var released: [Line] {
        let all = lines.flattened
        let checked = Set(all.filter(\.isChecked).map(\.id))
        return all.filter { !$0.isChecked && $0.after.map(checked.contains) == true }
    }
}

extension [Plan.Line] {
    var flattened: [Plan.Line] { flatMap { [$0] + $0.children.flattened } }

    /// Offsets from the top down to the line.
    func path(to id: String) -> [Int]? {
        for (index, line) in enumerated() {
            if line.id == id { return [index] }
            if let rest = line.children.path(to: id) { return [index] + rest }
        }
        return nil
    }

    subscript(path path: [Int]) -> Plan.Line {
        get { path.count == 1 ? self[path[0]] : self[path[0]].children[path: [Int](path.dropFirst())] }
        set {
            if path.count == 1 {
                self[path[0]] = newValue
            } else {
                self[path[0]].children[path: [Int](path.dropFirst())] = newValue
            }
        }
    }

    mutating func remove(at path: [Int]) -> Plan.Line {
        guard path.count > 1 else { return remove(at: path[0]) }
        return self[path[0]].children.remove(at: [Int](path.dropFirst()))
    }

    mutating func updateEach(_ body: (inout Plan.Line) -> Void) {
        for index in indices {
            body(&self[index])
            self[index].children.updateEach(body)
        }
    }
}

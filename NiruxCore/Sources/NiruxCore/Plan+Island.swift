import Foundation

extension Plan {
    /// What the Lead island says, in the plan's order: the Lead's line now, the user's to-dos, then the Lead's other
    /// lines and the planned sessions.
    public struct Island: Hashable, Sendable {
        public var now: Line?
        public var forYou: [Line]
        public var next: [Line]
    }

    public var island: Island {
        let open = lines.flatMap { [$0] + $0.descendants }.filter { !$0.isChecked }
        let lead = open.filter { $0.kind == .lead }
        return Island(now: lead.first, forYou: open.filter { $0.kind == .todo }, next: Array(lead.dropFirst()) + open.filter(\.isPlanned))
    }
}

import Foundation

/// A Lead wakes once for the results its tasks report within a window: a
/// result (`completed`) to a Lead whose space groups them waits until the
/// oldest one pending for that Lead is `window` old, then they all go in
/// one pass, typed as one prompt or posted together to its hook.
/// Questions, answers and instructions never wait.
struct MissionResultBatch {
    static let window: TimeInterval = 180

    struct Recipient: Hashable {
        let workspaceID: String
        let agentUUID: String
    }

    /// The results that go to a Lead together, by recipient.
    let groups: [Recipient: [MissionStore.AcceptedEvent]]

    /// `grouped`: whether a mission's results wait for its Lead.
    init(_ deliveries: [MissionStore.AcceptedEvent], grouped: (Mission) -> Bool) {
        groups = Dictionary(grouping: deliveries.filter { $0.event.kind == .completed && grouped($0.mission) }, by: Self.recipient(of:))
    }

    static func recipient(of delivery: MissionStore.AcceptedEvent) -> Recipient {
        Recipient(workspaceID: delivery.mission.parentWorkspaceID, agentUUID: delivery.mission.parentAgentUUID)
    }

    /// The results whose group is still within its window.
    func held(now: TimeInterval) -> Set<String> {
        Set(groups.values.filter { now - Self.oldest($0) < Self.window }.flatMap { $0.map(\.event.id) })
    }

    /// What goes with `delivery`, itself first: its whole group for a
    /// grouped result, else just it.
    func together(with delivery: MissionStore.AcceptedEvent) -> [MissionStore.AcceptedEvent] {
        guard let group = groups[Self.recipient(of: delivery)], group.contains(where: { $0.event.id == delivery.event.id }) else {
            return [delivery]
        }
        return [delivery] + group.filter { $0.event.id != delivery.event.id }
    }

    /// When the next waiting group is due.
    func nextRelease(now: TimeInterval) -> TimeInterval? {
        groups.values.map { Self.oldest($0) + Self.window }.filter { $0 > now }.min()
    }

    private static func oldest(_ group: [MissionStore.AcceptedEvent]) -> TimeInterval {
        group.map(\.event.timestamp).min() ?? 0
    }
}

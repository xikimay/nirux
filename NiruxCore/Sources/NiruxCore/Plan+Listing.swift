import Foundation

extension Plan {
    /// How the sidebar lists a space's tasks with its plan: each feature with its lines, then the tasks in no
    /// feature in their own order, then the to-dos and planned sessions outside any feature.
    public struct Listing: Hashable, Sendable {
        public enum Entry: Hashable, Sendable {
            /// Its lines follow unless it is folded.
            case feature(Line, isFolded: Bool)
            /// A task's row, and its sub-tasks' after it.
            case task(workspaceID: String, inFeature: Bool)
            /// A to-do, a Lead line or a planned session.
            case line(Line, inFeature: Bool)
        }

        public var entries: [Entry] = []
        /// Lead lines outside any feature, for under the Lead's row.
        public var leadLines: [Line] = []
    }

    /// `tasks`: the space's open tasks in the sidebar's order, sub-tasks left out; `shown`: those a folded feature
    /// still lists. A task in a feature leaves its own place, folded or not; a line whose task isn't listed (archived,
    /// closed) shows nowhere. Sessions under a to-do, a Lead line or a session list with their feature.
    public func listing(tasks: [String], folded: Set<String>, shown: Set<String> = []) -> Listing {
        let listed = Set(tasks)
        var listing = Listing()
        var inFeatures = Set<String>()
        for feature in lines where feature.kind == .feature {
            let isFolded = folded.contains(feature.id)
            listing.entries.append(.feature(feature, isFolded: isFolded))
            for line in feature.descendants where Self.listedKinds.contains(line.kind) {
                if let workspaceID = line.workspaceID {
                    guard listed.contains(workspaceID) else { continue }
                    inFeatures.insert(workspaceID)
                    if !isFolded || shown.contains(workspaceID) { listing.entries.append(.task(workspaceID: workspaceID, inFeature: true)) }
                } else if !isFolded {
                    listing.entries.append(.line(line, inFeature: true))
                }
            }
        }
        listing.entries += tasks.filter { !inFeatures.contains($0) }.map { .task(workspaceID: $0, inFeature: false) }
        for top in lines where top.kind != .feature {
            for line in [top] + top.descendants where line.workspaceID == nil && Self.listedKinds.contains(line.kind) {
                if line.kind == .lead {
                    listing.leadLines.append(line)
                } else {
                    listing.entries.append(.line(line, inFeature: false))
                }
            }
        }
        return listing
    }

    private static let listedKinds: Set<Line.Kind> = [.todo, .lead, .session]
}

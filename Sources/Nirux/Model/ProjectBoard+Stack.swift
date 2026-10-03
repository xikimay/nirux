import Foundation

// MARK: - Stacked pull requests (docs/pr-stacks.md)

extension ProjectBoard {
    /// A pull request's place in a stack: open pull requests of the
    /// configured repository, each based on another one's branch.
    struct StackPlace: Equatable {
        /// The open pull request whose branch it is based on.
        let parent: Int?
        /// The stack, root first. Empty when it forks (two pull requests on
        /// one branch): no "n/N" then.
        let chain: [Int]
        /// The root's base: the base branch, or a merged pull request's.
        let rootBase: String
        /// Its base is the branch of this merged pull request: it can be
        /// retargeted onto that one's base, as GitHub does when the branch
        /// is deleted. Only a root has one.
        let mergedBase: MergedBase?
        /// For the board's order: the stack's root, then its place in the
        /// stack, each pull request followed by those based on it.
        let root: Int
        let order: Int

        /// "2/4" in a straight stack, "on #52" in a fork, nil for a lone
        /// pull request on a merged base.
        var label: String? {
            chain.count > 1 ? "\(order + 1)/\(chain.count)" : parent.map { "on #\($0)" }
        }

        /// "Stack: #52 → #53 → #54, on main".
        var tooltip: String {
            let base = mergedBase.map { "\(rootBase) (#\($0.number) merged)" } ?? rootBase
            guard chain.count > 1 else {
                return parent.map { "Stacked on #\($0)" } ?? "Based on \(base)"
            }
            return "Stack: " + chain.map { "#\($0)" }.joined(separator: " → ") + ", on \(base)"
        }
    }

    struct MergedBase: Equatable {
        let number: Int
        /// The merged pull request's base: where to retarget.
        let onto: String
    }

    /// The place of each open pull request that is in a stack, by number.
    /// A pull request is in one when another is based on its branch, or
    /// its own base is the branch of a merged pull request, untouched
    /// since: a long-lived branch merged once (`develop`) has moved on, or
    /// soon will. Both are of the configured repository, by head branch.
    /// One on the base branch is never in a stack.
    /// Without a base branch, no merged base: nothing could tell it apart.
    static func stackPlaces(
        open: [String: PullRequest], merged: [String: PullRequest], baseBranch: String?
    ) -> [Int: StackPlace] {
        func parent(of pullRequest: PullRequest) -> PullRequest? {
            guard let base = pullRequest.baseRefName, base != baseBranch else { return nil }
            return open[base]
        }
        var children: [Int: [PullRequest]] = [:]
        for pullRequest in open.values {
            if let parent = parent(of: pullRequest) { children[parent.number, default: []].append(pullRequest) }
        }

        var places: [Int: StackPlace] = [:]
        // A pull request has one base, so each root heads a tree. Pull
        // requests based on each other in a loop have no root: no place.
        for root in open.values where parent(of: root) == nil {
            var mergedBase: MergedBase?
            if let baseBranch, let base = root.baseRefName, base != baseBranch, let merged = merged[base],
               root.baseOid == merged.headOid, let onto = merged.baseRefName {
                mergedBase = MergedBase(number: merged.number, onto: onto)
            }
            guard children[root.number] != nil || mergedBase != nil else { continue }
            // Depth first, oldest first: each pull request, then those on it.
            var members: [PullRequest] = []
            var pending = [root]
            while let pullRequest = pending.popLast() {
                members.append(pullRequest)
                pending += (children[pullRequest.number] ?? []).sorted { $0.number > $1.number }
            }
            let isStraight = members.allSatisfy { (children[$0.number]?.count ?? 0) <= 1 }
            let chain = isStraight ? members.map(\.number) : []
            for (order, pullRequest) in members.enumerated() {
                places[pullRequest.number] = StackPlace(
                    parent: parent(of: pullRequest)?.number, chain: chain, rootBase: root.baseRefName ?? "",
                    mergedBase: pullRequest.number == root.number ? mergedBase : nil, root: root.number, order: order
                )
            }
        }
        return places
    }
}

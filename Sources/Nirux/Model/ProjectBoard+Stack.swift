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
        /// For the board's order: the stack's root, then the depth in it.
        let root: Int
        let depth: Int

        /// "2/4" in a straight stack, "on #52" in a fork, nil for a lone
        /// pull request on a merged base.
        var label: String? {
            // A straight stack lists one pull request per depth.
            chain.count > 1 ? "\(depth + 1)/\(chain.count)" : parent.map { "on #\($0)" }
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
    /// its own base is the branch of a merged pull request. Both lists are
    /// of the configured repository, one pull request per head branch.
    static func stackPlaces(open: [PullRequest], merged: [PullRequest], baseBranch: String?) -> [Int: StackPlace] {
        let byHead = Dictionary(open.map { ($0.headRefName, $0) }, uniquingKeysWith: { $0.number > $1.number ? $0 : $1 })
        let mergedByHead = Dictionary(merged.map { ($0.headRefName, $0) }, uniquingKeysWith: { $0.number > $1.number ? $0 : $1 })
        func parent(of pullRequest: PullRequest) -> PullRequest? {
            pullRequest.baseRefName.flatMap { byHead[$0] }.flatMap { $0.number == pullRequest.number ? nil : $0 }
        }
        var children: [Int: [PullRequest]] = [:]
        for pullRequest in open {
            if let parent = parent(of: pullRequest) { children[parent.number, default: []].append(pullRequest) }
        }

        var places: [Int: StackPlace] = [:]
        // A pull request has one base, so each root heads a tree. Pull
        // requests based on each other in a loop have no root: no place.
        for root in open where parent(of: root) == nil {
            var mergedBase: MergedBase?
            if let base = root.baseRefName, base != baseBranch, let merged = mergedByHead[base],
               let onto = merged.baseRefName, onto != base {
                mergedBase = MergedBase(number: merged.number, onto: onto)
            }
            guard children[root.number] != nil || mergedBase != nil else { continue }
            var members: [(pullRequest: PullRequest, depth: Int)] = []
            var pending = [(root, 0)]
            while let (pullRequest, depth) = pending.popLast() {
                members.append((pullRequest, depth))
                let next = (children[pullRequest.number] ?? []).sorted { $0.number > $1.number }
                pending += next.map { ($0, depth + 1) }
            }
            let isStraight = members.allSatisfy { (children[$0.pullRequest.number]?.count ?? 0) <= 1 }
            let chain = isStraight ? members.map(\.pullRequest.number) : []
            for (pullRequest, depth) in members {
                places[pullRequest.number] = StackPlace(
                    parent: parent(of: pullRequest)?.number, chain: chain, rootBase: root.baseRefName ?? "",
                    mergedBase: pullRequest.number == root.number ? mergedBase : nil, root: root.number, depth: depth
                )
            }
        }
        return places
    }
}

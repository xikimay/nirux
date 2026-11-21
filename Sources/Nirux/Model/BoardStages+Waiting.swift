import Foundation

extension BoardStages {
    struct WaitingTask: Equatable, Sendable {
        let id: String
        let title: String
        let awaitedID: String
        let pullRequestURL: String?
        let repositoryKey: String
        let state: State
        let phrase: String

        init?(id: String, title: String, wait: MergeWait) {
            guard let start = wait.pendingStart, let status = wait.waitingState else { return nil }
            self.id = id
            self.title = title
            awaitedID = wait.awaited.workspaceID
            pullRequestURL = wait.awaited.pullRequest?.url
            repositoryKey = start.repositoryKey
            switch status {
            case .waits:
                state = .waiting
                phrase = "Starts after \(wait.awaitedName) merges"
            case .starting:
                state = .working
                phrase = status.line
            case .needsYou:
                state = .needsYou
                phrase = status.line
            }
        }

        var line: Line {
            let menu: [MenuItem] = pullRequestURL.flatMap { isGitHubAddress($0) ? [.openPullRequest(url: $0)] : nil } ?? []
            return Line(id: id, title: title, station: .code, state: state, rail: nil, phrase: Phrase(text: phrase), pullRequest: "", since: nil, menu: menu)
        }
    }

    /// Follow workspace IDs across repositories. If the dependency has gone, show the wait in its intended repository.
    static func waitingBySection(
        _ waits: [WaitingTask], locations: [String: String], sections: Set<String>, fallback: String
    ) -> [String: [WaitingTask]] {
        let byID = Dictionary(waits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var assigned = locations
        for wait in waits where assigned[wait.id] == nil {
            var path: [WaitingTask] = []
            var seen = Set<String>()
            var next = wait.id
            while assigned[next] == nil, let task = byID[next], seen.insert(next).inserted {
                path.append(task)
                next = task.awaitedID
            }
            let destination = path.last?.repositoryKey
            let section = assigned[next] ?? destination.flatMap { sections.contains($0) ? $0 : nil } ?? fallback
            for task in path { assigned[task.id] = section }
        }
        return Dictionary(grouping: waits) { assigned[$0.id] ?? fallback }
    }

    /// Insert whole waiting chains after their task without making them members of its PR stack or sub-task family.
    static func attach(_ waits: [WaitingTask], to lines: inout [Line]) -> [Unit] {
        guard !waits.isEmpty else { return [] }
        let children = Dictionary(grouping: waits, by: \.awaitedID)
        var listed = Set(lines.map(\.id))
        func appendChildren(of id: String, to following: inout [Line]) {
            for child in children[id, default: []] where listed.insert(child.id).inserted {
                following.append(child.line)
                appendChildren(of: child.id, to: &following)
            }
        }
        for index in lines.indices {
            let id = lines[index].id
            appendChildren(of: id, to: &lines[index].following)
        }
        var orphans: [Unit] = []
        let ids = Set(waits.map(\.id))
        func appendRoot(_ wait: WaitingTask) {
            guard listed.insert(wait.id).inserted else { return }
            var line = wait.line
            appendChildren(of: wait.id, to: &line.following)
            orphans.append(.task(line, subtasks: []))
        }
        for wait in waits where !ids.contains(wait.awaitedID) { appendRoot(wait) }
        // Recover every row once, even from a cycle in a restored layout.
        for wait in waits where !listed.contains(wait.id) { appendRoot(wait) }
        return orphans
    }
}

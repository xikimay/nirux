import CryptoKit
import Foundation

extension BranchReview {
    struct Receipt: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            case passed, failed, running, unknown
        }

        enum Provenance: Codable, Equatable, Sendable {
            case ci(url: String?)
            case local
            case agent
        }

        enum Freshness: Equatable, Sendable {
            enum Reason: Equatable, Sendable { case localEdits, earlierCommit }

            case fresh
            case stale(Reason)
            case unverified
        }

        struct BrowserArtifact: Codable, Equatable, Sendable {
            let workspaceID: String
            let url: String
            let capturedAt: Date
            let consoleErrorCount: Int
            let networkErrorCount: Int
            let screenshotPath: String?
            let diagnosticsPath: String?

            var fitsStorage: Bool {
                guard UUID(uuidString: workspaceID) != nil,
                      url.utf8.count <= 2048,
                      consoleErrorCount >= 0,
                      networkErrorCount >= 0,
                      (screenshotPath?.utf8.count ?? 0) <= 4096,
                      (diagnosticsPath?.utf8.count ?? 0) <= 4096 else { return false }
                return true
            }
        }

        let id: String
        let title: String
        let command: String?
        let status: Status
        let summary: String?
        let provenance: Provenance
        let recordedAt: Date
        let head: String
        let workingTreeDigest: String?
        let browserCapture: BrowserArtifact?

        init(
            id: String,
            title: String,
            command: String?,
            status: Status,
            summary: String?,
            provenance: Provenance,
            recordedAt: Date,
            head: String,
            workingTreeDigest: String?,
            browserCapture: BrowserArtifact? = nil
        ) {
            self.id = id
            self.title = title
            self.command = command
            self.status = status
            self.summary = summary
            self.provenance = provenance
            self.recordedAt = recordedAt
            self.head = head
            self.workingTreeDigest = workingTreeDigest
            self.browserCapture = browserCapture
        }

        func freshness(head currentHead: String, tree: WorkingTree) -> Freshness {
            guard tree != .incomplete else { return .unverified }
            guard head == currentHead else { return .stale(.earlierCommit) }
            return workingTreeDigest == tree.digest ? .fresh : .stale(.localEdits)
        }

        var fitsStorage: Bool {
            guard !id.isEmpty, id.utf8.count <= 256, !title.isEmpty, title.utf8.count <= 512,
                  (command?.utf8.count ?? 0) <= 4096, (summary?.utf8.count ?? 0) <= 4096,
                  BranchReview.isCommitID(head) else { return false }
            if let workingTreeDigest, workingTreeDigest.utf8.count != 64 || !BranchReview.isCommitID(workingTreeDigest) { return false }
            if case .ci(let url) = provenance { return (url?.utf8.count ?? 0) <= 4096 && browserCapture == nil }
            if let browserCapture {
                guard provenance == .local, browserCapture.fitsStorage else { return false }
            }
            return true
        }
    }

    enum WorkingTree: Equatable, Sendable {
        case clean
        case edited(String)
        case incomplete

        var digest: String? {
            if case .edited(let digest) = self { return digest }
            return nil
        }
    }
}

extension BranchReview.Snapshot {
    var workingTree: BranchReview.WorkingTree {
        guard files.allSatisfy({ $0.omission != .notRead && $0.patchHash != nil }) else { return .incomplete }
        guard hasUncommittedChanges else { return .clean }
        var hash = SHA256()
        for file in files.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            guard let patchHash = file.patchHash, let rawDigest = file.rawPatchDigest else { return .incomplete }
            // Git paths cannot contain NUL, and patch hashes are hexadecimal.
            hash.update(data: Data("\(file.path)\0\(patchHash)\0".utf8))
            hash.update(data: rawDigest)
        }
        return .edited(hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    var workingTreeDigest: String? { workingTree.digest }
}

extension BranchReview {
    static func ciReceipts(checks: [GitHub.Check], head: String, observedAt: Date) -> [Receipt] {
        GitHub.latest(checks).map { check in
            let status: Receipt.Status
            switch check.result {
            case .success: status = .passed
            case .failure:
                status = ["CANCELLED", "STALE", "ACTION_REQUIRED"].contains(check.conclusion) ? .unknown : .failed
            case .pending:
                status = check.status?.uppercased() == "IN_PROGRESS" ? .running : .unknown
            case .skipped, .neutral: status = .unknown
            }
            let identity = "\(head)\0\(check.workflowName ?? "")\0\(check.name)"
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let recordedAt = [check.completedAt, check.startedAt].compactMap(GitHub.startTime)
                .compactMap { try? Date($0, strategy: .iso8601) }.first ?? observedAt
            return Receipt(
                id: id, title: check.qualifiedName ?? check.name, command: nil, status: status,
                summary: check.conclusion ?? check.status, provenance: .ci(url: check.url),
                recordedAt: recordedAt, head: head, workingTreeDigest: nil
            )
        }
    }
}

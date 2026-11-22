import Foundation

extension BranchReview {
    enum BrowserReceipt {
        enum Problem: String, LocalizedError, Equatable, Sendable {
            case incompleteSnapshot = "Refresh the review and try again once the full working tree can be read."
            case invalidWorkspace = "Browser captures can only be attached within their own workspace."
            case crossWorkspaceCapture = "Refused to attach a capture outside this workspace’s private capture directory."
            case unreadableCapture = "The browser capture file is missing, unreadable, or not a valid capture."
            case reviewNotReady = "The branch review is not ready to save a capture."
            case snapshotChanged = "Refresh the branch review, then attach the capture again."

            var errorDescription: String? { rawValue }
        }

        struct MessageError: LocalizedError, Equatable, Sendable {
            let message: String
            var errorDescription: String? { message }
        }

        struct Input: Equatable, Sendable {
            let workspaceID: String
            let url: String
            let capturedAt: Date
            let consoleErrorCount: Int
            let networkErrorCount: Int
            let screenshotPath: String?
            let diagnosticsPath: String?
        }

        struct ResolvedArtifacts: Equatable, Sendable {
            let screenshotURL: URL?
            let diagnosticsURL: URL?

            var hasAny: Bool { screenshotURL != nil || diagnosticsURL != nil }
        }

        enum DisplayAccess: Equatable, Sendable {
            case allowed(ResolvedArtifacts)
            case denied
        }

        static func receipt(
            from input: Input,
            for snapshot: Snapshot,
            workspaceID: String,
            stateDirectory: URL = Persistence.stateDirectory,
            id: String = UUID().uuidString
        ) throws -> Receipt {
            let tree = snapshot.workingTree
            guard tree != .incomplete else { throw Problem.incompleteSnapshot }
            guard let expectedID = UUID(uuidString: workspaceID),
                  let inputID = UUID(uuidString: input.workspaceID) else {
                throw Problem.invalidWorkspace
            }
            guard expectedID == inputID else { throw Problem.crossWorkspaceCapture }
            guard input.consoleErrorCount >= 0, input.networkErrorCount >= 0 else {
                throw Problem.unreadableCapture
            }

            let canonicalID = expectedID.uuidString
            let validatedScreenshot = try validateRequiredArtifact(
                input.screenshotPath, kind: .screenshot, workspaceID: canonicalID, stateDirectory: stateDirectory
            )
            let validatedDiagnostics = try validateRequiredArtifact(
                input.diagnosticsPath, kind: .diagnostics, workspaceID: canonicalID, stateDirectory: stateDirectory
            )

            let sanitizedURL = BrowserCapture.sanitizedURLString(input.url)
            let title = label(sanitizedURL.isEmpty ? "Isolated browser capture" : sanitizedURL)
            let hasErrors = input.consoleErrorCount > 0 || input.networkErrorCount > 0
            let summary = summaryText(
                consoleErrorCount: input.consoleErrorCount,
                networkErrorCount: input.networkErrorCount,
                hasScreenshot: validatedScreenshot != nil,
                hasDiagnostics: validatedDiagnostics != nil
            )
            let artifact = Receipt.BrowserArtifact(
                workspaceID: canonicalID,
                url: sanitizedURL,
                capturedAt: input.capturedAt,
                consoleErrorCount: input.consoleErrorCount,
                networkErrorCount: input.networkErrorCount,
                screenshotPath: validatedScreenshot?.path,
                diagnosticsPath: validatedDiagnostics?.path
            )
            return Receipt(
                id: id,
                title: title,
                command: nil,
                status: hasErrors ? .failed : .passed,
                summary: summary,
                provenance: .local,
                recordedAt: input.capturedAt,
                head: snapshot.head,
                workingTreeDigest: tree.digest,
                browserCapture: artifact
            )
        }

        static func displayAccess(
            for artifact: Receipt.BrowserArtifact,
            workspaceID: String?,
            stateDirectory: URL = Persistence.stateDirectory
        ) -> DisplayAccess {
            guard let workspaceID,
                  let expectedID = UUID(uuidString: workspaceID),
                  let actualID = UUID(uuidString: artifact.workspaceID),
                  expectedID == actualID else { return .denied }

            let canonicalID = expectedID.uuidString
            let screenshotURL: URL?
            if let path = artifact.screenshotPath {
                switch BrowserCapture.checkArtifactPath(path, kind: .screenshot, workspaceID: canonicalID, stateDirectory: stateDirectory) {
                case .valid(let url): screenshotURL = url
                case .missing: screenshotURL = nil
                case .rejected: return .denied
                }
            } else {
                screenshotURL = nil
            }

            let diagnosticsURL: URL?
            if let path = artifact.diagnosticsPath {
                switch BrowserCapture.checkArtifactPath(path, kind: .diagnostics, workspaceID: canonicalID, stateDirectory: stateDirectory) {
                case .valid(let url): diagnosticsURL = url
                case .missing: diagnosticsURL = nil
                case .rejected: return .denied
                }
            } else {
                diagnosticsURL = nil
            }

            return .allowed(ResolvedArtifacts(screenshotURL: screenshotURL, diagnosticsURL: diagnosticsURL))
        }

        static func errorCountsText(consoleErrorCount: Int, networkErrorCount: Int) -> String {
            let console = "\(consoleErrorCount) console \(consoleErrorCount == 1 ? "error" : "errors")"
            let network = "\(networkErrorCount) network \(networkErrorCount == 1 ? "error" : "errors")"
            return "\(console), \(network)"
        }

        private static func summaryText(
            consoleErrorCount: Int,
            networkErrorCount: Int,
            hasScreenshot: Bool,
            hasDiagnostics: Bool
        ) -> String {
            let counts = errorCountsText(consoleErrorCount: consoleErrorCount, networkErrorCount: networkErrorCount)
            switch (hasScreenshot, hasDiagnostics) {
            case (true, true): return "\(counts) · screenshot + diagnostics"
            case (true, false): return "\(counts) · screenshot"
            case (false, true): return "\(counts) · diagnostics"
            case (false, false): return counts
            }
        }

        private static func validateRequiredArtifact(
            _ path: String?,
            kind: BrowserCapture.ArtifactKind,
            workspaceID: String,
            stateDirectory: URL
        ) throws -> URL? {
            guard let path else { return nil }
            switch BrowserCapture.checkArtifactPath(path, kind: kind, workspaceID: workspaceID, stateDirectory: stateDirectory) {
            case .valid(let url): return url
            case .missing: throw Problem.unreadableCapture
            case .rejected: throw Problem.crossWorkspaceCapture
            }
        }

        private static func label(_ value: String) -> String {
            let prefix = BranchReview.visible(String(value.unicodeScalars.prefix(121))).unicodeScalars
            return prefix.count > 120 ? String(prefix.prefix(119)) + "…" : String(prefix)
        }
    }
}

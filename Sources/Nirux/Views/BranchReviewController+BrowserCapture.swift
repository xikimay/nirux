import AppKit
import Foundation

extension BranchReviewController {
    func attachBrowserCapture(
        _ input: BranchReview.BrowserReceipt.Input,
        completion: (@MainActor (Result<Void, Error>) -> Void)? = nil
    ) {
        guard let snapshot else {
            let error = BranchReview.BrowserReceipt.Problem.reviewNotReady
            view.showReportProblem(error.localizedDescription)
            completion?(.failure(error))
            return
        }
        guard let generation = reportGeneration else {
            let error = BranchReview.BrowserReceipt.Problem.snapshotChanged
            view.showReportProblem(error.localizedDescription)
            completion?(.failure(error))
            return
        }
        guard review?.canWrite == true else {
            let message = review?.problem ?? BranchReview.BrowserReceipt.Problem.reviewNotReady.localizedDescription
            view.showReportProblem(message)
            completion?(.failure(BranchReview.BrowserReceipt.MessageError(message: message)))
            return
        }
        guard let workspaceID else {
            let error = BranchReview.BrowserReceipt.Problem.invalidWorkspace
            view.showReportProblem(error.localizedDescription)
            completion?(.failure(error))
            return
        }
        view.showReportProblem(nil)
        let stateDirectory = effectiveStateDirectory
        Self.inBackground(on: .global(qos: .userInitiated), {
            Result {
                try BranchReview.BrowserReceipt.receipt(
                    from: input, for: snapshot, workspaceID: workspaceID, stateDirectory: stateDirectory
                )
            }
        }) { [weak self] result in
            guard let self else { return }
            guard self.reportGeneration == generation else {
                let error = BranchReview.BrowserReceipt.Problem.snapshotChanged
                self.view.showReportProblem(error.localizedDescription)
                completion?(.failure(error))
                return
            }
            switch result {
            case .failure(let error):
                self.view.showReportProblem(error.localizedDescription)
                completion?(.failure(error))
            case .success(let receipt):
                self.writeReview({ $0.addReceipt(receipt) }) { [weak self] state in
                    guard let self else { return }
                    guard self.snapshot?.branch == snapshot.branch,
                          state.record.receipts.contains(where: { $0.id == receipt.id }) else {
                        let message = state.problem ?? "This review’s receipt format cannot be updated by this version of Nirux."
                        self.view.showReportProblem(message)
                        completion?(.failure(BranchReview.BrowserReceipt.MessageError(message: message)))
                        return
                    }
                    completion?(.success(()))
                }
            }
        }
    }

    func openReceiptArtifact(id: String) {
        guard let receipt = reviewRecord?.receipts.first(where: { $0.id == id }),
              let capture = receipt.browserCapture else { return }
        switch BranchReview.BrowserReceipt.displayAccess(
            for: capture, workspaceID: workspaceID, stateDirectory: effectiveStateDirectory
        ) {
        case .denied:
            view.showReportProblem(BranchReview.BrowserReceipt.Problem.crossWorkspaceCapture.localizedDescription)
        case .allowed(let artifacts):
            guard artifacts.hasAny else {
                view.showReportProblem("This capture file is no longer available in this workspace’s private capture store.")
                return
            }
            if let presentReceiptArtifact {
                presentReceiptArtifact(receipt, artifacts)
            } else if let window = view.window {
                Self.showCapturePreview(in: window, receipt: receipt, artifacts: artifacts, reveal: revealArtifact)
            }
        }
    }

    static func showCapturePreview(
        in window: NSWindow,
        receipt: BranchReview.Receipt,
        artifacts: BranchReview.BrowserReceipt.ResolvedArtifacts,
        reveal: @escaping @MainActor ([URL]) -> Void
    ) {
        guard let capture = receipt.browserCapture else { return }
        let alert = NSAlert()
        alert.messageText = "Local Browser Capture"
        let counts = BranchReview.BrowserReceipt.errorCountsText(
            consoleErrorCount: capture.consoleErrorCount, networkErrorCount: capture.networkErrorCount
        )
        let urlLine = capture.url.isEmpty ? "Isolated test browser" : BranchReview.visible(capture.url)
        alert.informativeText = "\(urlLine)\n\(counts) · \(capture.capturedAt.formatted(.iso8601))\nFactual local capture — not a review approval."
        if let screenshotURL = artifacts.screenshotURL,
           let data = ProjectMemory.readData(screenshotURL.path, limit: BrowserCapture.maxScreenshotBytes, followingSymlinks: false),
           let image = NSImage(data: data) {
            let preview = NSImageView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
            preview.image = image
            preview.imageScaling = .scaleProportionallyDown
            preview.imageFrameStyle = .grayBezel
            alert.accessoryView = preview
        } else if let diagnosticsURL = artifacts.diagnosticsURL,
                  let data = ProjectMemory.readData(diagnosticsURL.path, limit: BrowserCapture.maxDiagnosticsBytes, followingSymlinks: false) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let snapshot = try? decoder.decode(BrowserCapture.DiagnosticsSnapshot.self, from: data) {
                let scroll = NSTextView.scrollableTextView()
                scroll.frame.size = NSSize(width: 480, height: 240)
                if let text = scroll.documentView as? NSTextView {
                    text.isEditable = false
                    text.isRichText = false
                    text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                    text.string = snapshot.events.isEmpty
                        ? "No diagnostics events recorded."
                        : snapshot.events.map { "[\($0.kind.rawValue)] \($0.message)" }.joined(separator: "\n")
                    alert.accessoryView = scroll
                }
            }
        }
        let files = [artifacts.screenshotURL, artifacts.diagnosticsURL].compactMap { $0 }
        alert.addButton(withTitle: "Done")
        if !files.isEmpty {
            alert.addButton(withTitle: "Show in Finder")
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, !files.isEmpty {
                reveal(files)
            }
        }
    }
}

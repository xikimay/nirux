import AppKit
import WebKit

extension WebViewColumn {
    private static let attachDiagnosticsResponse = NSApplication.ModalResponse(
        rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1
    )

    @objc func showDiagnostics() {
        guard let diagnostics, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Browser Diagnostics"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame.size = NSSize(width: 480, height: 240)
        guard let text = scroll.documentView as? NSTextView else { return }
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        diagnostics.display = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Clear")
        if onAttachCaptureToBranchReview != nil {
            alert.addButton(withTitle: "Attach to Branch Review")
        }
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            alert.window.orderOut(nil)
            diagnostics.display = nil
            switch response {
            case .alertSecondButtonReturn:
                guard !diagnostics.buffer.events.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text.string, forType: .string)
            case .alertThirdButtonReturn:
                diagnostics.clear()
            case Self.attachDiagnosticsResponse:
                guard let self, let window else { return }
                self.attachCurrentDiagnostics(diagnostics: diagnostics, in: window)
            default: break
            }
        }
    }

    @objc func captureScreenshot() {
        guard let diagnostics, let window else { return }
        let url = webView.url
        let revision = diagnostics.revision
        let capture = BrowserCapture(
            url: url,
            viewport: webView.bounds.size,
            consoleErrorCount: diagnostics.buffer.consoleErrorCount,
            networkErrorCount: diagnostics.buffer.networkErrorCount
        )
        let events = diagnostics.buffer.events
        webView.takeSnapshot(with: nil) { [weak self, weak window] image, error in
            guard let self, let window else { return }
            let alert = NSAlert()
            do {
                if let error { throw error }
                guard diagnostics.revision == revision, self.webView.url == url else {
                    throw CocoaError(.userCancelled)
                }
                guard let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let stateDirectory = Persistence.stateDirectory
                let file = try capture.save(image, workspaceID: diagnostics.workspaceID, stateDirectory: stateDirectory)
                let counts = BranchReview.BrowserReceipt.errorCountsText(
                    consoleErrorCount: capture.consoleErrorCount, networkErrorCount: capture.networkErrorCount
                )
                alert.messageText = "Screenshot Saved"
                alert.informativeText = "\(file.lastPathComponent)\n\(counts)"
                alert.addButton(withTitle: "Done")
                alert.addButton(withTitle: "Show in Finder")
                if self.onAttachCaptureToBranchReview != nil {
                    alert.addButton(withTitle: "Attach to Branch Review")
                }
                alert.beginSheetModal(for: window) { [weak self, weak window] response in
                    alert.window.orderOut(nil)
                    switch response {
                    case .alertSecondButtonReturn:
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    case .alertThirdButtonReturn:
                        guard let self, let window else { return }
                        self.attachSavedScreenshot(
                            file, capture: capture, events: events,
                            workspaceID: diagnostics.workspaceID, stateDirectory: stateDirectory, in: window
                        )
                    default: break
                    }
                }
            } catch {
                alert.messageText = "Couldn’t Save Screenshot"
                alert.informativeText = BrowserDiagnostics.sanitized(error.localizedDescription)
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func attachSavedScreenshot(
        _ file: URL,
        capture: BrowserCapture,
        events: [BrowserDiagnostics.Event],
        workspaceID: String,
        stateDirectory: URL,
        in window: NSWindow
    ) {
        var diagnosticsPath: String?
        if !events.isEmpty {
            let snapshot = BrowserCapture.DiagnosticsSnapshot(
                url: capture.url, timestamp: capture.timestamp,
                consoleErrorCount: capture.consoleErrorCount, networkErrorCount: capture.networkErrorCount,
                events: events
            )
            diagnosticsPath = try? BrowserCapture.saveDiagnostics(snapshot, workspaceID: workspaceID, stateDirectory: stateDirectory).path
        }
        let input = BranchReview.BrowserReceipt.Input(
            workspaceID: workspaceID,
            url: capture.url,
            capturedAt: capture.timestamp,
            consoleErrorCount: capture.consoleErrorCount,
            networkErrorCount: capture.networkErrorCount,
            screenshotPath: file.path,
            diagnosticsPath: diagnosticsPath
        )
        attachCaptureToBranchReview(input, in: window)
    }

    private func attachCurrentDiagnostics(diagnostics: IsolatedBrowserDiagnostics, in window: NSWindow) {
        let now = Date()
        let sanitizedURL = BrowserCapture.sanitizedURL(webView.url)
        let consoleErrors = diagnostics.buffer.consoleErrorCount
        let networkErrors = diagnostics.buffer.networkErrorCount
        let snapshot = BrowserCapture.DiagnosticsSnapshot(
            url: sanitizedURL, timestamp: now,
            consoleErrorCount: consoleErrors, networkErrorCount: networkErrors,
            events: diagnostics.buffer.events
        )
        do {
            let file = try BrowserCapture.saveDiagnostics(
                snapshot, workspaceID: diagnostics.workspaceID, stateDirectory: Persistence.stateDirectory
            )
            let input = BranchReview.BrowserReceipt.Input(
                workspaceID: diagnostics.workspaceID,
                url: sanitizedURL,
                capturedAt: now,
                consoleErrorCount: consoleErrors,
                networkErrorCount: networkErrors,
                screenshotPath: nil,
                diagnosticsPath: file.path
            )
            attachCaptureToBranchReview(input, in: window)
        } catch {
            showAttachError(error, in: window)
        }
    }

    private func attachCaptureToBranchReview(_ input: BranchReview.BrowserReceipt.Input, in window: NSWindow) {
        guard let attach = onAttachCaptureToBranchReview else { return }
        attach(input) { [weak self, weak window] result in
            guard let self, let window else { return }
            switch result {
            case .success(let shownInReview):
                guard !shownInReview else { return }
                let alert = NSAlert()
                alert.messageText = "Attached to Branch Review"
                alert.informativeText = "Saved as a local browser verification receipt for the current snapshot."
                alert.addButton(withTitle: "Done")
                if self.onOpenBranchReview != nil {
                    alert.addButton(withTitle: "Open Branch Review")
                }
                alert.beginSheetModal(for: window) { [weak self] response in
                    if response == .alertSecondButtonReturn {
                        self?.onOpenBranchReview?()
                    }
                }
            case .failure(let error):
                self.showAttachError(error, in: window)
            }
        }
    }

    private func showAttachError(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t Attach to Branch Review"
        alert.informativeText = BrowserDiagnostics.sanitized(error.localizedDescription)
        alert.beginSheetModal(for: window)
    }
}

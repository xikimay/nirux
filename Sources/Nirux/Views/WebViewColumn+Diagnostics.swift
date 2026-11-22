import AppKit
import WebKit

extension WebViewColumn {
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
        alert.beginSheetModal(for: window) { response in
            diagnostics.display = nil
            switch response {
            case .alertSecondButtonReturn:
                guard !diagnostics.buffer.events.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text.string, forType: .string)
            case .alertThirdButtonReturn:
                diagnostics.clear()
            default: break
            }
        }
    }

    @objc func captureScreenshot() {
        guard let diagnostics, let window else { return }
        let url = webView.url
        let revision = diagnostics.revision
        let capture = BrowserCapture(url: url, viewport: webView.bounds.size, consoleErrorCount: diagnostics.buffer.consoleErrorCount)
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
                let file = try capture.save(image, workspaceID: diagnostics.workspaceID, stateDirectory: Persistence.stateDirectory)
                alert.messageText = "Screenshot Saved"
                alert.informativeText = file.lastPathComponent
                alert.addButton(withTitle: "Done")
                alert.addButton(withTitle: "Show in Finder")
                alert.beginSheetModal(for: window) { response in
                    if response == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                }
            } catch {
                alert.messageText = "Couldn’t Save Screenshot"
                alert.informativeText = BrowserDiagnostics.sanitized(error.localizedDescription)
                alert.beginSheetModal(for: window)
            }
        }
    }
}

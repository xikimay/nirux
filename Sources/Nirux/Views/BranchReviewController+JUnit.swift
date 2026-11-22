import AppKit
import UniformTypeIdentifiers

extension BranchReviewController {
    static func chooseJUnitReport(in window: NSWindow, directory: URL, selected: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Attach JUnit Report"
        panel.prompt = "Attach"
        panel.directoryURL = directory
        panel.allowedContentTypes = [.xml]
        panel.resolvesAliases = false
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { selected(url) }
        }
    }

    func attachReport() {
        guard let snapshot, let window = view.window else { return }
        let changed = "Refresh the branch review, then attach the report again."
        guard let generation = reportGeneration else { return view.showReportProblem(changed) }
        guard review?.canWrite == true else {
            return view.showReportProblem(review?.problem ?? "The branch review is not ready to save a report.")
        }
        view.showReportProblem(nil)
        chooseReport(window, URL(fileURLWithPath: worktree, isDirectory: true)) { [weak self] url in
            Self.inBackground(on: .global(qos: .userInitiated), {
                Result { try BranchReview.JUnit.read(url, for: snapshot) }
            }) { [weak self] result in
                guard let self else { return }
                guard self.reportGeneration == generation else { return self.view.showReportProblem(changed) }
                switch result {
                case .failure(let error):
                    self.view.showReportProblem(error.localizedDescription)
                case .success(let receipt):
                    self.writeReview({ $0.addReceipt(receipt) }) { [weak self] state in
                        guard let self, self.snapshot?.branch == snapshot.branch,
                              !state.record.receipts.contains(where: { $0.id == receipt.id }) else { return }
                        self.view.showReportProblem(state.problem ?? "This review’s receipt format cannot be updated by this version of Nirux.")
                    }
                }
            }
        }
    }
}

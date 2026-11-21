import AppKit

@MainActor
final class MergeQueueJournalPanel: NSPanel, NSTextViewDelegate {
    private let queue: MergeQueueController
    private let openURL: @MainActor (URL) -> Void
    private let scroll = NSTextView.scrollableTextView()
    private let heading = NSTextField(labelWithString: "Merge Queue Journal")
    var pasteboard: NSPasteboard = .general
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private(set) var snapshot: MergeQueue.JournalSnapshot?
    private var textView: NSTextView { scroll.documentView as! NSTextView }

    init(queue: MergeQueueController, openURL: @escaping @MainActor (URL) -> Void) {
        self.queue = queue
        self.openURL = openURL
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                   styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        appearance = Theme.appearance
        backgroundColor = Theme.Color.base
        title = "Merge Queue Journal"
        contentMinSize = NSSize(width: 360, height: 230)
        let container = NSView()
        contentView = container
        heading.font = Theme.Font.bodyEmphasized
        heading.lineBreakMode = .byTruncatingMiddle
        textView.isEditable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = self
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.string = "Reading journal…"
        scroll.drawsBackground = false

        copyButton.target = self
        copyButton.action = #selector(copyJournal)
        copyButton.isEnabled = false
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [refreshButton, copyButton, doneButton])
        for view in [heading, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
    }

    func show(in parent: NSWindow) {
        parent.beginSheet(self)
        refresh()
    }

    @objc private func refresh() {
        refreshButton.isEnabled = false
        Task {
            let snapshot = await queue.journalSnapshot()
            self.snapshot = snapshot
            heading.stringValue = snapshot.title
            let body = NSMutableAttributedString(string: snapshot.status, attributes: [
                .font: Theme.Font.bodyEmphasized, .foregroundColor: Theme.Color.textPrimary
            ])
            if let link = snapshot.link {
                body.append(NSAttributedString(string: "\nOpen on GitHub ↗", attributes: [.link: link, .font: Theme.Font.body]))
            }
            let entries = snapshot.entriesText.isEmpty ? "No readable journal entries." : snapshot.entriesText
            let paragraphs = NSMutableParagraphStyle()
            paragraphs.paragraphSpacing = 5
            body.append(NSAttributedString(string: "\n\n" + entries, attributes: [
                .font: Theme.Font.mono, .foregroundColor: Theme.Color.textSecondary, .paragraphStyle: paragraphs
            ]))
            textView.textStorage?.setAttributedString(body)
            refreshButton.isEnabled = true
            copyButton.isEnabled = true
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, url == snapshot?.link { openURL(url) }
        return true
    }

    @objc private func copyJournal() {
        guard let snapshot else { return }
        pasteboard.clearContents()
        pasteboard.setString(snapshot.copyText, forType: .string)
    }

    @objc private func done() {
        sheetParent?.endSheet(self)
    }

    override func cancelOperation(_ sender: Any?) { done() }
}

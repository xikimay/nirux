import AppKit

@MainActor
final class MergeQueueJournalPanel: NSPanel, NSTextViewDelegate {
    private let queue: MergeQueueController
    private let openURL: @MainActor (URL) -> Void
    private let scroll = NSTextView.scrollableTextView()
    private let heading = NSTextField(labelWithString: "Merge Queue Journal")
    let resolveButton = NSButton(title: "Ask Agent to Resolve", target: nil, action: nil)
    private let resolveError = NSTextField(wrappingLabelWithString: "")
    var readResolution: ((ProcessSnapshot) -> NiruxShellView.QueueResolution)?
    var onResolve: ((MergeQueue.Conflict, NiruxShellView.ReviewSendColumn) async -> String?)?
    private var resolution = NiruxShellView.QueueResolution.hidden
    private var resolving = false
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

        resolveButton.target = self
        resolveButton.action = #selector(chooseAgent)
        resolveButton.isHidden = true
        resolveError.isHidden = true
        let actions = NSStackView(views: [resolveButton, resolveError])
        actions.orientation = .vertical
        actions.alignment = .leading
        copyButton.target = self
        copyButton.action = #selector(copyJournal)
        copyButton.isEnabled = false
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [refreshButton, copyButton, doneButton])
        for view in [heading, actions, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            actions.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: heading.trailingAnchor),
            actions.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            scroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 4),
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
            refreshResolution(snapshot: ProcessSnapshot())
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

    func refreshResolution(snapshot: ProcessSnapshot) {
        guard !resolving else { return }
        let current = readResolution?(snapshot) ?? .hidden
        guard current != resolution else { return }
        resolution = current
        resolveError.isHidden = true
        resolveButton.menu = nil
        resolveButton.isHidden = current == .hidden
        switch current {
        case .hidden: break
        case .blocked(let reason):
            resolveButton.isEnabled = false
            resolveButton.toolTip = reason
        case .ready(let conflict, let targets):
            resolveButton.isEnabled = true
            resolveButton.toolTip = "Prepare a prompt for #\(conflict.number). Read it in the agent’s column and submit it there."
            if targets.count > 1 {
                let menu = NSMenu()
                for target in targets {
                    menu.addClosureItem(title: target.label) { [weak self] in self?.resolve(conflict, target: target) }
                }
                resolveButton.menu = menu
            }
        }
    }

    @objc private func chooseAgent() {
        guard case .ready(let conflict, let targets) = resolution else { return }
        if targets.count == 1 {
            resolve(conflict, target: targets[0])
        } else {
            resolveButton.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: resolveButton.bounds.maxY), in: resolveButton)
        }
    }

    private func resolve(_ conflict: MergeQueue.Conflict, target: NiruxShellView.ReviewSendColumn) {
        guard !resolving, let onResolve else { return }
        resolving = true
        resolveButton.isEnabled = false
        Task {
            let error = await onResolve(conflict, target)
            resolving = false
            guard sheetParent != nil else { return }
            resolution = .hidden
            resolveButton.isHidden = true
            refreshResolution(snapshot: ProcessSnapshot())
            if let error {
                resolveError.stringValue = error
                resolveError.isHidden = false
            }
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

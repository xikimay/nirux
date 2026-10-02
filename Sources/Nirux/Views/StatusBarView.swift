import AppKit

/// Global status bar at the bottom of the window.
/// Shows app-level info (a merge queue, updates, crashes) — not
/// workspace-specific.
///
/// A merge queue comes first, with its Stop: it must stay in reach while
/// it runs. Then one notice at a time: a crash of the previous session
/// outranks an available update, which shows once the crash notice is
/// dismissed.
final class StatusBarView: NSView {
    static let height: CGFloat = 28

    enum CrashAction {
        case copySummary, openReport
    }

    /// A merge queue (docs/project-board.md, section 3.6): running, with
    /// Stop; or ended, until dismissed.
    struct QueueNotice: Equatable {
        /// "Queue: #52 waiting for the nightly, 3 of 7".
        let text: String
        var tooltip: String?
        var isRunning: Bool
        var isStopping = false
        var isDryRun: Bool
        /// Stopped by a problem, not by the user.
        var isFailure = false
        /// Several queues run: Stop stops them all.
        var stopsAll = false
    }

    private static let crashColor = Theme.Color.error.withAlphaComponent(0.9)
    private static let copyTitle = "Copy summary"
    private static let copiedTitle = "Copied ✓"
    private static let copiedFlashDuration: TimeInterval = 1.5

    private var label: NSTextField?
    private var versionLabel: NSTextField?
    private var installButton: NSButton?
    private var copySummaryButton: NSButton?
    private var openReportButton: NSButton?
    private var dismissButton: NSButton?
    /// The queue's text, a button: a click shows its board.
    private(set) var queueButton: NSButton?
    private(set) var queueStopButton: NSButton?
    private(set) var queueDismissButton: NSButton?
    private(set) var queueNotice: QueueNotice?
    private var trackingArea: NSTrackingArea?
    private var updateVersion: String?
    private(set) var crashNotice: CrashNotice?
    private var copiedFlashGeneration = 0
    /// Whether the last render showed a notice.
    private var renderedContent = false
    /// Fits either title, so the flash doesn't slide the next buttons under
    /// the pointer.
    private var copySummaryWidth: CGFloat = 0
    /// Set while hovering the update notice; reset when it goes away.
    private var showsPointingHand = false
    var onInstall: (() -> Void)?
    var onCrashAction: ((CrashAction) -> Void)?
    var onQueueClick: (() -> Void)?
    var onQueueStop: (() -> Void)?
    var onQueueDismiss: (() -> Void)?
    /// A notice appeared or went away: the shell shows or hides the bar.
    var onContentChange: (() -> Void)?
    var hasContent: Bool { hasNotice || queueNotice != nil }
    /// A crash or an update: the notice after the queue.
    private var hasNotice: Bool { crashNotice != nil || updateVersion != nil }
    private var isShowingUpdate: Bool { crashNotice == nil && updateVersion != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.cgColor

        // Top border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        border.autoresizingMask = [.width]
        addSubview(border)

        // Left label (update or crash info)
        let lbl = NSTextField(labelWithString: "")
        lbl.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        lbl.textColor = NSColor.white.withAlphaComponent(0.4)
        lbl.lineBreakMode = .byTruncatingTail
        addSubview(lbl)
        label = lbl

        // Notice buttons (inline, right after label)
        installButton = actionButton("Install ↗", action: #selector(installClicked))
        let copy = actionButton(Self.copiedTitle, action: #selector(copySummaryClicked))
        copy.sizeToFit()
        copySummaryWidth = copy.frame.width
        copy.title = Self.copyTitle
        copy.sizeToFit()
        copySummaryWidth = max(copySummaryWidth, copy.frame.width)
        copy.toolTip = "Copy the crash summary, ready to paste to an agent"
        copySummaryButton = copy
        openReportButton = actionButton("Open report", action: #selector(openReportClicked))
        openReportButton?.toolTip = "Open the full crash report in Console"

        // Merge queue: its text (a click shows the board), Stop, or ✕ once ended.
        let queue = NSButton(title: "", target: self, action: #selector(queueClicked))
        queue.bezelStyle = .inline
        queue.isBordered = false
        queue.alignment = .left
        (queue.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        queue.isHidden = true
        addSubview(queue)
        queueButton = queue
        queueStopButton = actionButton("Stop", action: #selector(queueStopClicked))
        queueStopButton?.contentTintColor = Self.crashColor
        queueStopButton?.toolTip = "Stop the queue before its next command; a call already sent to GitHub finishes"
        let queueDismiss = NSButton(title: "✕", target: self, action: #selector(queueDismissClicked))
        queueDismiss.bezelStyle = .inline
        queueDismiss.isBordered = false
        queueDismiss.font = .systemFont(ofSize: 11)
        queueDismiss.contentTintColor = NSColor.white.withAlphaComponent(0.25)
        queueDismiss.isHidden = true
        queueDismiss.setAccessibilityLabel("Dismiss the queue notice")
        addSubview(queueDismiss)
        queueDismissButton = queueDismiss

        // Dismiss button
        let x = NSButton(title: "✕", target: self, action: #selector(dismissClicked))
        x.bezelStyle = .inline
        x.isBordered = false
        x.font = .systemFont(ofSize: 11)
        x.contentTintColor = NSColor.white.withAlphaComponent(0.25)
        x.isHidden = true
        x.setAccessibilityLabel("Dismiss")
        addSubview(x)
        dismissButton = x

        // Version label (right-aligned, always visible)
        let ver = NSTextField(labelWithString: "")
        ver.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        ver.textColor = NSColor.white.withAlphaComponent(0.2)
        ver.alignment = .right
        ver.lineBreakMode = .byTruncatingTail
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            ver.stringValue = version
        }
        // Below every button (the border stays first): where they meet on a
        // narrow bar, the buttons take the clicks.
        addSubview(ver, positioned: .above, relativeTo: border)
        versionLabel = ver
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        button.contentTintColor = Theme.Color.accent
        button.isHidden = true
        addSubview(button)
        return button
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let pad: CGFloat = 16
        // Top border
        if let border = subviews.first {
            border.frame = NSRect(x: 0, y: height - 1, width: bounds.width, height: 1)
        }

        let verW: CGFloat = 120
        let versionMinX = bounds.width - verW - pad
        let noticeButtons = [installButton, copySummaryButton, openReportButton].compactMap { $0 }.filter { !$0.isHidden }
        noticeButtons.forEach { $0.sizeToFit() }
        copySummaryButton?.frame.size.width = copySummaryWidth
        let noticeButtonsW = noticeButtons.reduce(CGFloat(0)) { $0 + $1.frame.width + 8 }
        // The queue first: at most half the bar when a notice follows it,
        // and never so wide that the notice's buttons and ✕ reach the
        // version label; its text shrinks first.
        var start = pad
        if let queueButton, !queueButton.isHidden {
            let trailing = [queueStopButton, queueDismissButton].compactMap { $0 }.filter { !$0.isHidden }
            trailing.forEach { $0.sizeToFit() }
            let trailingW = trailing.reduce(CGFloat(0)) { $0 + $1.frame.width + 6 }
            var limit = (hasNotice ? bounds.width / 2 : versionMinX - 8) - pad - trailingW
            if hasNotice {
                let noticeMinW: CGFloat = 80 + noticeButtonsW + 26
                limit = min(limit, versionMinX - 4 - noticeMinW - 18 - pad - trailingW)
            }
            let textW = min(ceil(queueButton.attributedTitle.size().width) + 6, max(40, limit))
            queueButton.frame = NSRect(x: pad, y: (height - 18) / 2, width: textW, height: 18)
            var queueX = queueButton.frame.maxX
            for button in trailing {
                queueX += 6
                button.frame = NSRect(x: queueX, y: (height - 18) / 2, width: button.frame.width, height: 18)
                queueX += button.frame.width
            }
            start = queueX + 18
        }

        let buttons = noticeButtons
        let buttonsW = noticeButtonsW
        let dismissW: CGFloat = dismissButton?.isHidden == false ? 22 : 0
        let labelSize = label?.attributedStringValue.size() ?? .zero
        // The notice (label, then its buttons and ✕) takes at least the left
        // half, and up to a pad before the version label; never so wide that
        // ✕ reaches the version label. Its text shrinks first.
        let labelMaxW = min(
            max(80, bounds.width / 2 - start, versionMinX - pad - start - buttonsW - dismissW),
            max(40, versionMinX - 4 - start - buttonsW - dismissW)
        )
        let labelW = hasNotice ? min(ceil(labelSize.width) + 4, labelMaxW) : 0
        label?.frame = NSRect(x: start, y: (height - 14) / 2, width: labelW, height: 14)

        var x = start + labelW
        for button in buttons {
            x += 8
            button.frame = NSRect(x: x, y: (height - 18) / 2, width: button.frame.width, height: 18)
            x += button.frame.width
        }
        dismissButton?.frame = NSRect(x: x + 4, y: (height - 18) / 2, width: 18, height: 18)

        versionLabel?.frame = NSRect(x: versionMinX, y: (height - 14) / 2, width: verW, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseMoved(with event: NSEvent) {
        guard isShowingUpdate else { return }
        let loc = convert(event.locationInWindow, from: nil)
        if updateHitFrame.contains(loc) {
            NSCursor.pointingHand.set()
            showsPointingHand = true
            label?.textColor = Theme.Color.accent
        } else {
            NSCursor.arrow.set()
            showsPointingHand = false
            label?.textColor = Theme.Color.accent.withAlphaComponent(0.8)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard isShowingUpdate else { return }
        NSCursor.arrow.set()
        showsPointingHand = false
        label?.textColor = Theme.Color.accent.withAlphaComponent(0.8)
    }

    override func mouseDown(with event: NSEvent) {
        guard isShowingUpdate else { super.mouseDown(with: event); return }
        let loc = convert(event.locationInWindow, from: nil)
        if updateHitFrame.contains(loc) {
            onInstall?()
            return
        }
        super.mouseDown(with: event)
    }

    /// Hit area covering label + install button
    private var updateHitFrame: NSRect {
        guard let lbl = label, let btn = installButton, !btn.isHidden else { return .zero }
        return NSRect(x: lbl.frame.minX, y: 0,
                      width: btn.frame.maxX - lbl.frame.minX, height: bounds.height)
    }

    func showUpdate(version: String) {
        updateVersion = version
        render()
    }

    func showCrash(_ notice: CrashNotice) {
        crashNotice = notice
        render()
    }

    /// The merge queue to show, or none.
    func showQueue(_ notice: QueueNotice?) {
        guard notice != queueNotice else { return }
        queueNotice = notice
        render()
    }

    /// What the queue's text looks like.
    private func renderQueue() {
        guard let queueNotice else {
            queueButton?.isHidden = true
            queueStopButton?.isHidden = true
            queueDismissButton?.isHidden = true
            return
        }
        let color: NSColor = queueNotice.isFailure ? Self.crashColor
            : queueNotice.isDryRun ? NSColor.systemOrange
            : queueNotice.isRunning ? NSColor.white.withAlphaComponent(0.75) : NSColor.white.withAlphaComponent(0.45)
        queueButton?.attributedTitle = NSAttributedString(string: "● " + queueNotice.text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: color
        ])
        queueButton?.toolTip = queueNotice.tooltip ?? queueNotice.text
        queueButton?.isHidden = false
        queueStopButton?.isHidden = !queueNotice.isRunning
        queueStopButton?.title = queueNotice.isStopping ? "Stopping…" : queueNotice.stopsAll ? "Stop All" : "Stop"
        queueStopButton?.toolTip = queueNotice.stopsAll
            ? "Stop every running queue before its next command; a call already sent to GitHub finishes"
            : "Stop the queue before its next command; a call already sent to GitHub finishes"
        queueStopButton?.isEnabled = !queueNotice.isStopping
        queueDismissButton?.isHidden = queueNotice.isRunning
    }

    /// What the label says for a crash notice.
    static func crashText(for notice: CrashNotice) -> String {
        let times = notice.reportCount > 1 ? " \(notice.reportCount)×" : ""
        return "● Nirux crashed\(times) · \(notice.headline)"
    }

    private func render() {
        if showsPointingHand, !isShowingUpdate {
            NSCursor.arrow.set()
            showsPointingHand = false
        }
        renderQueue()
        installButton?.isHidden = true
        copySummaryButton?.isHidden = true
        openReportButton?.isHidden = true
        dismissButton?.isHidden = !hasNotice
        label?.toolTip = nil
        if let crashNotice {
            label?.stringValue = Self.crashText(for: crashNotice)
            label?.textColor = Self.crashColor
            label?.toolTip = "\(Self.crashText(for: crashNotice))\n\(crashNotice.reportURL.lastPathComponent)"
            copySummaryButton?.isHidden = false
            openReportButton?.isHidden = false
        } else if let updateVersion {
            label?.stringValue = "● Update available · \(updateVersion)"
            label?.textColor = Theme.Color.accent.withAlphaComponent(0.8)
            installButton?.isHidden = false
        } else {
            label?.stringValue = ""
            label?.textColor = NSColor.white.withAlphaComponent(0.4)
        }
        needsLayout = true
        guard renderedContent != hasContent else { return }
        renderedContent = hasContent
        onContentChange?()
    }

    @objc private func installClicked() {
        onInstall?()
    }

    @objc private func copySummaryClicked() {
        onCrashAction?(.copySummary)
        copiedFlashGeneration += 1
        let generation = copiedFlashGeneration
        copySummaryButton?.title = Self.copiedTitle
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedFlashDuration) { @MainActor [weak self] in
            guard let self, self.copiedFlashGeneration == generation else { return }
            self.copySummaryButton?.title = Self.copyTitle
        }
    }

    @objc private func openReportClicked() {
        onCrashAction?(.openReport)
    }

    @objc private func queueClicked() {
        onQueueClick?()
    }

    @objc private func queueStopClicked() {
        onQueueStop?()
    }

    @objc private func queueDismissClicked() {
        onQueueDismiss?()
    }

    /// Dismisses the notice on screen; an update hidden behind a crash
    /// notice shows next.
    @objc private func dismissClicked() {
        if crashNotice != nil {
            crashNotice = nil
        } else {
            updateVersion = nil
        }
        render()
    }
}

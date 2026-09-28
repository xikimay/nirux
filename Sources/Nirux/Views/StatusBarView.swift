import AppKit

/// Global status bar at the bottom of the window.
/// Shows app-level info (updates, crashes, pilot shortcuts) — not workspace-specific.
///
/// One notice at a time: a crash of the previous session outranks an
/// available update, which shows once the crash notice is dismissed.
final class StatusBarView: NSView {
    static let height: CGFloat = 28

    enum CrashAction {
        case copySummary, openReport
    }

    private static let crashColor = NSColor(red: 0.95, green: 0.47, blue: 0.43, alpha: 0.9)
    private static let copyTitle = "Copy summary"
    private static let copiedTitle = "Copied ✓"
    private static let copiedFlashDuration: TimeInterval = 1.5

    private var label: NSTextField?
    private var hintsLabel: NSTextField?
    private var versionLabel: NSTextField?
    private var installButton: NSButton?
    private var copySummaryButton: NSButton?
    private var openReportButton: NSButton?
    private var dismissButton: NSButton?
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
    /// A notice appeared or went away: the shell shows or hides the bar.
    var onContentChange: (() -> Void)?
    var hasContent: Bool { crashNotice != nil || updateVersion != nil }
    private var isShowingUpdate: Bool { crashNotice == nil && updateVersion != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1).cgColor

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
        addSubview(ver)
        versionLabel = ver

        // Right hints label (pilot shortcuts)
        let hints = NSTextField(labelWithString: "")
        hints.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hints.textColor = NSColor.white.withAlphaComponent(0.25)
        hints.alignment = .right
        hints.lineBreakMode = .byTruncatingTail
        addSubview(hints)
        hintsLabel = hints
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        button.contentTintColor = .niruxAccent
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

        // The notice (label, then its buttons) takes the left half, and more
        // when the right-aligned pilot hints leave room; when both don't
        // fit, the hints are cut.
        let verW: CGFloat = 120
        let hintsMaxX = bounds.width - verW - pad * 2
        let hintsText = hintsLabel?.stringValue.isEmpty == false ? hintsLabel?.attributedStringValue.size().width ?? 0 : 0
        let noticeMaxX = hintsMaxX - (hintsText > 0 ? ceil(hintsText) + 4 + pad : 0)

        let buttons = [installButton, copySummaryButton, openReportButton].compactMap { $0 }.filter { !$0.isHidden }
        buttons.forEach { $0.sizeToFit() }
        copySummaryButton?.frame.size.width = copySummaryWidth
        let buttonsW = buttons.reduce(CGFloat(0)) { $0 + $1.frame.width + 8 }
        let dismissW: CGFloat = dismissButton?.isHidden == false ? 22 : 0
        let labelSize = label?.attributedStringValue.size() ?? .zero
        // At least the left half, as before the hints moved aside; never so
        // wide that ✕ goes under the version label, which would take its clicks.
        let versionMinX = bounds.width - verW - pad
        let labelMaxW = min(
            max(80, bounds.width / 2 - pad, noticeMaxX - pad - buttonsW - dismissW),
            max(40, versionMinX - 4 - pad - buttonsW - dismissW)
        )
        let labelW = min(ceil(labelSize.width) + 4, labelMaxW)
        label?.frame = NSRect(x: pad, y: (height - 14) / 2, width: labelW, height: 14)

        var x = pad + labelW
        for button in buttons {
            x += 8
            button.frame = NSRect(x: x, y: (height - 18) / 2, width: button.frame.width, height: 18)
            x += button.frame.width
        }
        dismissButton?.frame = NSRect(x: x + 4, y: (height - 18) / 2, width: 18, height: 18)
        let noticeEndX = hasContent ? x + 4 + dismissW : 0

        versionLabel?.frame = NSRect(x: versionMinX, y: (height - 14) / 2, width: verW, height: 14)
        // Starts after the notice: a label on top of a button takes its clicks.
        let hintsX = max(bounds.width / 2, noticeEndX + 8)
        hintsLabel?.frame = NSRect(x: hintsX, y: (height - 14) / 2, width: max(0, hintsMaxX - hintsX), height: 14)
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
            label?.textColor = NSColor(red: 0.57, green: 0.74, blue: 1.0, alpha: 1.0)
        } else {
            NSCursor.arrow.set()
            showsPointingHand = false
            label?.textColor = NSColor.niruxAccent.withAlphaComponent(0.8)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard isShowingUpdate else { return }
        NSCursor.arrow.set()
        showsPointingHand = false
        label?.textColor = NSColor.niruxAccent.withAlphaComponent(0.8)
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

    func setPilotHints(_ text: String) {
        hintsLabel?.stringValue = text
        needsLayout = true
    }

    func clearPilotHints() {
        hintsLabel?.stringValue = ""
        needsLayout = true
    }

    func showUpdate(version: String) {
        updateVersion = version
        render()
    }

    func showCrash(_ notice: CrashNotice) {
        crashNotice = notice
        render()
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
        installButton?.isHidden = true
        copySummaryButton?.isHidden = true
        openReportButton?.isHidden = true
        dismissButton?.isHidden = !hasContent
        label?.toolTip = nil
        if let crashNotice {
            label?.stringValue = Self.crashText(for: crashNotice)
            label?.textColor = Self.crashColor
            label?.toolTip = "\(Self.crashText(for: crashNotice))\n\(crashNotice.reportURL.lastPathComponent)"
            copySummaryButton?.isHidden = false
            openReportButton?.isHidden = false
        } else if let updateVersion {
            label?.stringValue = "● Update available · \(updateVersion)"
            label?.textColor = NSColor.niruxAccent.withAlphaComponent(0.8)
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

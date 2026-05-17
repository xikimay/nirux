import AppKit

/// Global status bar at the bottom of the window.
/// Shows app-level info (updates, pilot shortcuts) — not workspace-specific.
final class StatusBarView: NSView {
    static let height: CGFloat = 28

    private var label: NSTextField?
    private var hintsLabel: NSTextField?
    private var versionLabel: NSTextField?
    private var installButton: NSButton?
    private var dismissButton: NSButton?
    private var updateHitArea: NSView?
    private var trackingArea: NSTrackingArea?
    var onInstall: (() -> Void)?
    private(set) var hasContent: Bool = false

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

        // Left label (update info)
        let lbl = NSTextField(labelWithString: "")
        lbl.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        lbl.textColor = NSColor.white.withAlphaComponent(0.4)
        lbl.lineBreakMode = .byTruncatingTail
        addSubview(lbl)
        label = lbl

        // Install button (inline, right after label)
        let btn = NSButton(title: "Install ↗", target: self, action: #selector(installClicked))
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        btn.contentTintColor = .niruxAccent
        btn.isHidden = true
        addSubview(btn)
        installButton = btn

        // Dismiss button
        let x = NSButton(title: "✕", target: self, action: #selector(dismissClicked))
        x.bezelStyle = .inline
        x.isBordered = false
        x.font = .systemFont(ofSize: 11)
        x.contentTintColor = NSColor.white.withAlphaComponent(0.25)
        x.isHidden = true
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

    override func layout() {
        super.layout()
        let height = bounds.height
        let pad: CGFloat = 16
        // Top border
        if let border = subviews.first {
            border.frame = NSRect(x: 0, y: height - 1, width: bounds.width, height: 1)
        }

        // Measure label width to position install button right after it
        let labelSize = label?.attributedStringValue.size() ?? .zero
        let labelW = min(ceil(labelSize.width) + 4, bounds.width / 2 - pad)
        label?.frame = NSRect(x: pad, y: (height - 14) / 2, width: labelW, height: 14)

        installButton?.sizeToFit()
        let btnW = installButton?.frame.width ?? 0
        let btnX = pad + labelW + 8
        installButton?.frame = NSRect(x: btnX, y: (height - 18) / 2, width: btnW, height: 18)

        let dismissX = btnX + btnW + 4
        dismissButton?.frame = NSRect(x: dismissX, y: (height - 18) / 2, width: 18, height: 18)

        let verW: CGFloat = 120
        versionLabel?.frame = NSRect(x: bounds.width - verW - pad, y: (height - 14) / 2, width: verW, height: 14)
        hintsLabel?.frame = NSRect(x: bounds.width / 2, y: (height - 14) / 2, width: bounds.width / 2 - verW - pad * 2, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseMoved(with event: NSEvent) {
        guard hasContent else { return }
        let loc = convert(event.locationInWindow, from: nil)
        if updateHitFrame.contains(loc) {
            NSCursor.pointingHand.set()
            label?.textColor = NSColor(red: 0.57, green: 0.74, blue: 1.0, alpha: 1.0)
        } else {
            NSCursor.arrow.set()
            label?.textColor = NSColor.niruxAccent.withAlphaComponent(0.8)
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hasContent else { return }
        NSCursor.arrow.set()
        label?.textColor = NSColor.niruxAccent.withAlphaComponent(0.8)
    }

    override func mouseDown(with event: NSEvent) {
        guard hasContent else { super.mouseDown(with: event); return }
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
    }

    func clearPilotHints() {
        hintsLabel?.stringValue = ""
    }

    func showUpdate(version: String) {
        label?.stringValue = "● Update available · \(version)"
        label?.textColor = NSColor.niruxAccent.withAlphaComponent(0.8)
        installButton?.isHidden = false
        dismissButton?.isHidden = false
        hasContent = true
        needsLayout = true
    }

    @objc private func installClicked() {
        onInstall?()
    }

    @objc private func dismissClicked() {
        hasContent = false
        label?.stringValue = ""
        label?.textColor = NSColor.white.withAlphaComponent(0.4)
        installButton?.isHidden = true
        dismissButton?.isHidden = true
        needsLayout = true
    }
}

import AppKit

/// The sheet that adds a rule to a space's brief (see LearnedRules): a rule
/// the Lead proposed (Add to Brief, Dismiss, Later), or one the user writes
/// from a task's row (Add to Brief, Cancel). The rule and where it was
/// learned can be edited; under them, what the brief weighs before and
/// after, and Add stays off while the brief would pass what sessions get.
@MainActor
final class LearnedRuleSheet: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    enum Origin: Equatable {
        case proposal(RuleProposal)
        case user
    }

    static let size = NSSize(width: 540, height: 318)
    static let addTitle = "Add to Brief"

    let origin: Origin
    private(set) var window: NSWindow?
    let titleLabel = NSTextField(labelWithString: "")
    let explanationLabel = NSTextField(wrappingLabelWithString: "")
    let ruleView = NSTextView()
    let evidenceField = NSTextField()
    let sizeLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var addButton: NSButton?
    private(set) var dismissButton: NSButton?
    private(set) var closeButton: NSButton?

    private let spaceName: String
    /// The brief as read when the sheet opened: what the size line counts.
    private let briefText: String
    /// Adds the rule and evidence: nil once added (the sheet closes), else
    /// why not (it stays open, saying so).
    var onAdd: (String, String) -> String? = { _, _ in nil }
    var onDismiss: () -> Void = {}

    init(origin: Origin, spaceName: String, briefText: String, evidence: String) {
        self.origin = origin
        self.spaceName = spaceName
        self.briefText = briefText
        super.init()
        if case .proposal(let proposal) = origin {
            ruleView.string = proposal.rule
            evidenceField.stringValue = proposal.evidence
        } else {
            evidenceField.stringValue = evidence
        }
    }

    func begin(on parent: NSWindow) {
        let window = makeWindow()
        self.window = window
        update()
        parent.beginSheet(window)
        window.makeFirstResponder(ruleView)
        ruleView.setSelectedRange(NSRange(location: (ruleView.string as NSString).length, length: 0))
    }

    var isOpen: Bool { window != nil }

    /// The rule and evidence as they would be written.
    var rule: String { LearnedRules.cleaned(ruleView.string, limit: LearnedRules.maxRuleLength) }
    var evidence: String { LearnedRules.cleaned(evidenceField.stringValue, limit: LearnedRules.maxEvidenceLength) }

    // MARK: - Actions

    @objc func add() {
        guard addButton?.isEnabled == true else { return NSSound.beep() }
        if let problem = onAdd(rule, evidence) {
            setStatus(problem, color: Theme.Color.error)
            return
        }
        close()
    }

    @objc func dismissProposal() {
        close()
        onDismiss()
    }

    /// Later, Cancel or Esc: nothing changes.
    @objc func cancel() {
        close()
    }

    func close() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        self.window = nil
    }

    // MARK: - State

    /// The size line, what's wrong with the rule, and the Add button.
    func update() {
        let rule = rule
        let evidence = evidence
        let before = LearnedRules.characterCount(of: briefText)
        let max = SpaceBrief.maxCharacters
        var problem = rule.isEmpty ? nil : LearnedRules.problem(rule: rule, evidence: evidence)
        var after: Int?
        if problem == nil {
            let bullet = LearnedRules.line(rule: rule.isEmpty ? "…" : rule, evidence: evidence, date: Date())
            let base = briefText.isEmpty ? SpaceBrief.template(spaceName: spaceName) : briefText
            do {
                after = LearnedRules.characterCount(of: try LearnedRules.inserting(bullet, into: base))
            } catch {
                problem = error.localizedDescription
            }
        }
        let size = Self.sizeText(before: before, after: after, max: max)
        sizeLabel.stringValue = size.text
        sizeLabel.textColor = size.color
        sizeLabel.toolTip = size.toolTip
        if let problem {
            setStatus(problem, color: Theme.Color.error)
        } else if let after, after > max {
            setStatus("Shorten the brief in Space Settings › Brief first, or move rules to memory in Space Settings › Memory.",
                      color: Theme.Color.error)
        } else {
            setStatus("")
        }
        addButton?.isEnabled = !rule.isEmpty && problem == nil && (after ?? .max) <= max
    }

    /// "Brief: 1,240 → 1,330 of 16,000 characters", orange past half of
    /// what sessions get, red past all of it.
    nonisolated static func sizeText(
        before: Int, after: Int?, max: Int, prefix: String = "Brief: "
    ) -> (text: String, color: NSColor, toolTip: String) {
        let format = { (count: Int) in count.formatted() }
        let shown = after ?? before
        let text = prefix + format(before) + (after.map { " → \(format($0))" } ?? "") + " of \(format(max)) characters"
        let toolTip = "What every session started in this space reads, comments left out. It goes with every request."
        if shown > max { return (text, Theme.Color.error, toolTip) }
        if shown > LearnedRules.longBriefCharacters {
            return (text, Theme.Color.waiting, toolTip + " A long brief: move older rules to memory (Space Settings › Memory) or delete them.")
        }
        return (text, Theme.Color.textTertiary, toolTip)
    }

    private func setStatus(_ text: String, color: NSColor = Theme.Color.textSecondary) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    func controlTextDidChange(_ obj: Notification) {
        update()
    }

    func textDidChange(_ notification: Notification) {
        update()
    }

    /// Return adds (a rule is one paragraph), Tab moves on, Esc closes.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            add()
        case #selector(NSResponder.insertTab(_:)):
            window?.selectNextKeyView(nil)
        case #selector(NSResponder.insertBacktab(_:)):
            window?.selectPreviousKeyView(nil)
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
        default:
            return false
        }
        return true
    }

    // MARK: - Construction

    private func makeWindow() -> NSWindow {
        let size = Self.size
        // A panel: ⌘Z reaches its fields (see PanelTextUndo).
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.Color.base
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let inset = Theme.Space.xl
        let width = size.width - inset * 2
        var y = size.height - inset

        let isProposal: Bool
        if case .proposal = origin { isProposal = true } else { isProposal = false }
        titleLabel.stringValue = isProposal ? "The Lead Proposes a Rule" : "Add a Rule to the Brief"
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = Theme.Color.textPrimary
        y -= 18
        titleLabel.frame = NSRect(x: inset, y: y, width: width, height: 18)
        content.addSubview(titleLabel)

        explanationLabel.stringValue = (isProposal ? "Learned from a defect found twice. " : "")
            + "Every Claude and Codex session started in “\(spaceName)” from now on reads it; "
            + "sessions already running keep the brief they started with."
        explanationLabel.font = Theme.Font.caption
        explanationLabel.textColor = Theme.Color.textSecondary
        explanationLabel.isSelectable = false
        y -= Theme.Space.sm + 30
        explanationLabel.frame = NSRect(x: inset, y: y, width: width, height: 30)
        content.addSubview(explanationLabel)

        y -= Theme.Space.md + 15
        content.addSubview(fieldLabel("Rule", y: y, x: inset))
        let ruleHeight: CGFloat = 64
        y -= Theme.Space.xs + ruleHeight
        let scroll = NSScrollView(frame: NSRect(x: inset, y: y, width: width, height: ruleHeight))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        ruleView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        ruleView.isRichText = false
        ruleView.allowsUndo = true
        ruleView.delegate = self
        // Agents read it as written: no curly quotes, no `—` for `--`.
        ruleView.isAutomaticQuoteSubstitutionEnabled = false
        ruleView.isAutomaticDashSubstitutionEnabled = false
        ruleView.isAutomaticTextReplacementEnabled = false
        ruleView.isAutomaticSpellingCorrectionEnabled = false
        ruleView.font = Theme.Font.body
        ruleView.textColor = Theme.Color.textPrimary
        ruleView.backgroundColor = Theme.Color.surface
        ruleView.insertionPointColor = Theme.Color.textPrimary
        ruleView.autoresizingMask = [.width]
        ruleView.isVerticallyResizable = true
        ruleView.textContainer?.widthTracksTextView = true
        ruleView.setAccessibilityLabel("Rule")
        scroll.documentView = ruleView
        content.addSubview(scroll)

        y -= Theme.Space.md + 15
        content.addSubview(fieldLabel("Learned from", y: y, x: inset))
        y -= Theme.Space.xs + 22
        evidenceField.frame = NSRect(x: inset, y: y, width: width, height: 22)
        evidenceField.placeholderString = "#395, #417"
        evidenceField.delegate = self
        evidenceField.setAccessibilityLabel("Learned from")
        content.addSubview(evidenceField)

        y -= Theme.Space.sm + 15
        sizeLabel.font = Theme.Font.caption
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.frame = NSRect(x: inset, y: y, width: width, height: 15)
        content.addSubview(sizeLabel)

        statusLabel.font = Theme.Font.caption
        statusLabel.isSelectable = false
        statusLabel.maximumNumberOfLines = 2
        let buttonsTop: CGFloat = 14 + 30
        statusLabel.frame = NSRect(x: inset, y: buttonsTop + 2, width: width, height: max(0, y - buttonsTop - 6))
        content.addSubview(statusLabel)

        let add = button(Self.addTitle, action: #selector(add))
        add.keyEquivalent = "\r"
        add.frame.origin = NSPoint(x: size.width - inset - add.frame.width, y: 14)
        content.addSubview(add)
        addButton = add
        let close = button(isProposal ? "Later" : "Cancel", action: #selector(cancel))
        close.keyEquivalent = "\u{1b}"
        close.frame.origin = NSPoint(x: add.frame.minX - Theme.Space.sm - close.frame.width, y: 14)
        content.addSubview(close)
        closeButton = close
        if isProposal {
            let dismiss = button("Dismiss", action: #selector(dismissProposal))
            dismiss.toolTip = "The Lead hears it, and can’t propose this rule again for 90 days."
            dismiss.frame.origin = NSPoint(x: inset, y: 14)
            content.addSubview(dismiss)
            dismissButton = dismiss
        }
        ruleView.nextKeyView = evidenceField
        evidenceField.nextKeyView = add

        window.contentView = content
        return window
    }

    private func fieldLabel(_ text: String, y: CGFloat, x: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.Font.caption
        label.textColor = Theme.Color.textSecondary
        label.frame = NSRect(x: x, y: y, width: 200, height: 15)
        return label
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width, 88)
        return button
    }
}

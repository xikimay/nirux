import AppKit

/// The Project Memory panel's right side: the selected item's title, its
/// scope and what it means, a memory's description, then its text, and in
/// small the file it comes from. Its `[[links]]` are links: a click hands
/// the memory's file to `onLink`; a link to no memory stays plain. An item
/// of the brief or of the memory gets a switch between Always and When
/// relevant (`onScope`), and its text can be edited as written
/// (`beginEditing`).
@MainActor
final class ProjectMemoryPreview: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let metaLabel = NSTextField(labelWithString: "")
    let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    let sourceLabel = NSTextField(labelWithString: "")
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private let separator = NSView()
    /// Gets the linked memory's file.
    var onLink: (String) -> Void = { _ in }
    /// Gets the scope the switch was set to.
    var onScope: (ProjectMemory.Scope) -> Void = { _ in }
    /// Gets what the user decided about the brick shown.
    var onBrick: (BrickAction) -> Void = { _ in }
    /// A brick's decisions: validate or dismiss a proposal, confirm a brick
    /// that expired or became suspect, close one.
    enum BrickAction: Equatable { case validate, dismiss, reconfirm, close }
    let primaryButton = NSButton(title: "", target: nil, action: nil)
    let secondaryButton = NSButton(title: "", target: nil, action: nil)
    private var brickActions: (primary: BrickAction?, secondary: BrickAction?) = (nil, nil)
    let scopeControl = NSSegmentedControl(
        labels: [ProjectMemory.Scope.always.title, ProjectMemory.Scope.whenRelevant.title],
        trackingMode: .selectOne, target: nil, action: nil
    )
    /// The text shown as written, editable.
    private(set) var isEditing = false
    /// The edit's own: the panel's window, reused across items, never undoes
    /// an earlier item's typing into this one.
    private let editUndo = UndoManager()

    nonisolated static let linkScheme = "nirux-memory"
    private static let sourceHeight: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = Theme.Font.display
        titleLabel.textColor = Theme.Color.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        metaLabel.font = Theme.Font.caption
        metaLabel.textColor = Theme.Color.textTertiary
        metaLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.font = Theme.Font.body
        descriptionLabel.textColor = Theme.Color.textSecondary
        descriptionLabel.maximumNumberOfLines = 3
        // The keyboard stays in the panel's search field.
        descriptionLabel.isSelectable = false
        sourceLabel.font = Theme.Font.caption
        sourceLabel.textColor = Theme.Color.textTertiary
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.Color.line.cgColor
        scopeControl.controlSize = .small
        scopeControl.font = Theme.Font.caption
        scopeControl.selectedSegmentBezelColor = Theme.Color.accent
        // The keyboard stays in the panel's search field.
        scopeControl.refusesFirstResponder = true
        scopeControl.setAccessibilityLabel("Applies")
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.sizeToFit()

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Theme.Space.lg - 5, height: Theme.Space.md)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // Agents read what is typed here as written: no curly quotes, no
        // `—` for `--`, no corrected command names.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: Theme.Color.accent, .cursor: NSCursor.pointingHand
        ]
        textView.delegate = self
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for button in [primaryButton, secondaryButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = Theme.Font.caption
            // The keyboard stays in the panel's search field.
            button.refusesFirstResponder = true
            button.target = self
            button.action = #selector(brickButton(_:))
            button.isHidden = true
        }
        [titleLabel, metaLabel, descriptionLabel, separator, scroll, sourceLabel, scopeControl, primaryButton, secondaryButton].forEach(addSubview)

        wantsLayer = true
        layer?.backgroundColor = Theme.Color.canvas.cgColor
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let inset = Theme.Space.lg
        let width = bounds.width - 2 * inset
        var y = bounds.height - Theme.Space.md - 20
        var switchWidth = scopeControl.isHidden ? 0 : scopeControl.frame.width + Theme.Space.md
        scopeControl.frame.origin = NSPoint(x: bounds.width - inset - scopeControl.frame.width, y: y + 1)
        var right = bounds.width - inset
        for button in [secondaryButton, primaryButton] where !button.isHidden {
            button.sizeToFit()
            button.frame.origin = NSPoint(x: right - button.frame.width, y: y - 1)
            right = button.frame.minX - Theme.Space.sm
            switchWidth = bounds.width - inset - right
        }
        titleLabel.frame = NSRect(x: inset, y: y, width: width - switchWidth, height: 20)
        y -= 18
        metaLabel.frame = NSRect(x: inset, y: y, width: width, height: 15)
        if descriptionLabel.isHidden {
            y -= Theme.Space.sm
        } else {
            let height = min(ceil(descriptionLabel.cell?.cellSize(forBounds: NSRect(
                x: 0, y: 0, width: width, height: 200
            )).height ?? 16), 50)
            y -= Theme.Space.sm + height
            descriptionLabel.frame = NSRect(x: inset, y: y, width: width, height: height)
            y -= Theme.Space.md
        }
        separator.frame = NSRect(x: inset, y: y, width: width, height: 1)
        let bottom = sourceLabel.isHidden ? 0 : Self.sourceHeight
        sourceLabel.frame = NSRect(x: inset, y: (Self.sourceHeight - 15) / 2, width: width, height: 15)
        scroll.frame = NSRect(x: 0, y: bottom, width: bounds.width, height: max(y - 1 - bottom, 0))
        textView.frame.size.width = scroll.contentSize.width
    }

    // MARK: - Showing

    func show(_ entry: ProjectMemory.Entry, in knowledge: ProjectMemory.Knowledge, location: ProjectMemory.Location) {
        setHeaderHidden(false)
        endEditing()
        let movable: Bool
        switch entry.source {
        case .rule: movable = entry.scope == .always
        case .memory: movable = true
        case .missingFile, .brick, .proposal, .flag: movable = false
        }
        scopeControl.isHidden = !movable
        scopeControl.selectedSegment = entry.scope == .always ? 0 : 1
        // While Claude Code doesn't use its memory, nothing moves there.
        scopeControl.setEnabled(location.disabledBy == nil || entry.scope == .whenRelevant, forSegment: 1)
        titleLabel.stringValue = entry.title
        titleLabel.toolTip = entry.title
        showBrickActions(nil, nil)
        var meta = [entry.scope.title]
        var description = ""
        let body: NSAttributedString
        switch entry.source {
        case .rule:
            guard let (file, rule) = knowledge.rule(of: entry) else { return }
            meta.append(entry.scope == .team
                ? "In the repository’s \(file.label): change it there, in a commit"
                : "Every session Nirux starts in this space gets it")
            body = Self.text(of: rule.text, in: knowledge.memory)
            let lines = rule.lines.count == 1 ? "line \(rule.lines.lowerBound)" : "lines \(rule.lines.lowerBound)–\(rule.lines.upperBound)"
            sourceLabel.stringValue = "Source: \(file.label), \(lines)"
            sourceLabel.toolTip = file.url.path
        case .memory:
            guard let memory = knowledge.memory(of: entry), let contents = knowledge.memory else { return }
            meta.append(location.disabledBy == nil ? "Claude Code reads it when it needs it" : "Unused while auto-memory is off")
            if let type = memory.type { meta.append(type.lowercased()) }
            if let modified = memory.modified { meta.append(Self.dateFormatter.string(from: modified)) }
            if let line = memory.indexLine {
                if !contents.isRead(line) { meta.append("past what Claude Code reads of \(ProjectMemory.indexFileName)") }
            } else {
                meta.append("not in \(ProjectMemory.indexFileName)")
            }
            description = memory.description
            body = Self.text(of: memory.body, in: contents)
            sourceLabel.stringValue = "Source: Claude Code memory, \(memory.fileName)"
            sourceLabel.toolTip = contents.directory.appendingPathComponent(memory.fileName).path
        case .missingFile(let line):
            meta.append("Its file is gone")
            description = line.hook
            body = NSAttributedString(
                string: "\(ProjectMemory.indexFileName) lists \(line.fileName), which isn’t in Claude Code’s memory folder: "
                    + "sessions read this line but find nothing behind it.",
                attributes: Self.bodyAttributes
            )
            sourceLabel.stringValue = "Source: \(ProjectMemory.indexFileName), line \(line.number)"
            sourceLabel.toolTip = knowledge.memory?.directory.appendingPathComponent(ProjectMemory.indexFileName).path
        case .brick, .proposal:
            guard let (id, brick, status) = knowledge.brick(of: entry), let bricks = knowledge.bricks else { return }
            let card = Self.card(id: id, brick: brick, status: status, in: bricks)
            // The sentence is the brick: whole, under its subject.
            // "keyDown" stays as written; "backing layer" starts with a capital.
            titleLabel.stringValue = brick.subject.dropFirst().contains(where: \.isUppercase)
                ? brick.subject : brick.subject.prefix(1).uppercased() + brick.subject.dropFirst()
            meta = card.meta
            description = brick.sentence
            body = NSAttributedString(string: card.body, attributes: Self.bodyAttributes)
            switch status {
            case nil: showBrickActions(.validate, .dismiss)
            case .open?: showBrickActions(nil, .close)
            case .expired?, .suspect?, .failing?, .flagged?: showBrickActions(.reconfirm, .close)
            case .closed?: showBrickActions(nil, nil)
            }
            sourceLabel.stringValue = status == nil ? "Source: proposal \(id), in this space’s knowledge" : "Source: brick \(id), never edited"
            sourceLabel.toolTip = nil
        case .flag:
            guard let flag = knowledge.flag(of: entry) else { return }
            meta = ["Flagged by an agent", flag.kind.rawValue, Self.dateFormatter.string(from: Date(timeIntervalSince1970: flag.time))]
            description = flag.text
            let lines = (flag.evidence.map { ["Where it showed: \($0)"] } ?? [])
                + ["A flag changes no brick: ask the Lead for one, on a proof, if it is worth keeping."]
            body = NSAttributedString(string: lines.joined(separator: "\n"), attributes: Self.bodyAttributes)
            showBrickActions(nil, .dismiss)
            sourceLabel.stringValue = "Source: flag \(flag.id), from a task’s agent"
            sourceLabel.toolTip = nil
        }
        if !entry.cites.isEmpty, let bricks = knowledge.bricks {
            // Why it is flagged reads in full, above what it says.
            if let base = bricks.flaggedBase(in: entry.cites) {
                meta.append("flagged")
                description = ["Flagged: it rests on \(base.id), \(base.why)", description].filter { !$0.isEmpty }.joined(separator: " ")
            } else {
                meta.append("rests on " + entry.cites.joined(separator: ", "))
            }
        }
        metaLabel.stringValue = meta.joined(separator: " · ")
        descriptionLabel.stringValue = description
        descriptionLabel.isHidden = description.isEmpty
        textView.textStorage?.setAttributedString(body)
        textView.scroll(.zero)
        needsLayout = true
    }

    func showEmpty(_ text: String) {
        setHeaderHidden(true)
        endEditing()
        scopeControl.isHidden = true
        showBrickActions(nil, nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        textView.textStorage?.setAttributedString(NSAttributedString(string: "\n\n" + text, attributes: [
            .font: Theme.Font.body, .foregroundColor: Theme.Color.textTertiary, .paragraphStyle: paragraph
        ]))
        needsLayout = true
    }

    // MARK: - Editing

    /// Shows `text` as written, Markdown marks and all, ready to change.
    func beginEditing(_ text: String) {
        isEditing = true
        // No move halfway through an edit; the text shows it can change.
        scopeControl.isHidden = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.Color.surface
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        editUndo.removeAllActions()
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.bodyAttributes))
        textView.typingAttributes = Self.bodyAttributes
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// Back to reading; the caller shows the item again.
    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        textView.isEditable = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        editUndo.removeAllActions()
        if textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
    }

    var editedText: String { textView.string }

    /// While a save runs, the text can't change: typed then, it would be
    /// lost.
    func setEditable(_ editable: Bool) {
        guard isEditing else { return }
        textView.isEditable = editable
    }

    /// An input method composing in the text being edited.
    var isComposing: Bool { isEditing && textView.hasMarkedText() }

    /// Sets the switch back to `scope`, for a move that didn't start.
    func reshowScope(_ scope: ProjectMemory.Scope) {
        scopeControl.selectedSegment = scope == .always ? 0 : 1
    }

    private func showBrickActions(_ primary: BrickAction?, _ secondary: BrickAction?) {
        brickActions = (primary, secondary)
        for (button, action) in [(primaryButton, primary), (secondaryButton, secondary)] {
            button.isHidden = action == nil
            button.title = action.map(Self.title) ?? ""
            button.keyEquivalent = ""
        }
        needsLayout = true
    }

    static func title(of action: BrickAction) -> String {
        switch action {
        case .validate: return "Validate"
        case .dismiss: return "Dismiss"
        case .reconfirm: return "Still True"
        case .close: return "Close…"
        }
    }

    /// While a decision is written, none other can be.
    func setBrickActionsEnabled(_ enabled: Bool) {
        primaryButton.isEnabled = enabled
        secondaryButton.isEnabled = enabled
    }

    @objc private func brickButton(_ sender: NSButton) {
        guard let action = sender === primaryButton ? brickActions.primary : brickActions.secondary else { return }
        onBrick(action)
    }

    /// A brick's card: what it is, where it stands, how it is proven, what
    /// it reached.
    static func card(
        id: String, brick: KnowledgeBrick, status: BrickStatus?, in bricks: ProjectMemory.Bricks
    ) -> (meta: [String], body: String) {
        let state = bricks.loaded.state(of: id)
        var meta = [status == nil ? "Proposed by \(brick.proposedBy ?? "an agent")" : "Brick"]
        switch status {
        case nil: meta.append("no agent gets it until you validate it")
        case .open?: meta.append(bricks.serves ? "agents get it when they open a file it concerns" : "the space’s bricks are off")
        case .expired?: meta.append("expired")
        case .suspect?: meta.append("suspect")
        case .failing?: meta.append("failing")
        case .flagged?: meta.append("flagged")
        case .closed?: meta.append("closed")
        }
        var lines = ["About " + brick.scope.paths.map { "\(brick.scope.name)/\($0)" }.joined(separator: ", ")]
        if let reason = status?.reason { lines.append(reason) }
        lines.append("")
        lines.append("Proofs:")
        lines += brick.proofs.map { proof in
            let kind = proof.isRechecked ? "rechecked" : "proves it was true"
            return "• \(proof.label) — \(kind)"
        }
        if let tip = state.checkedTip, let at = state.checkedAt {
            lines.append("Last checked at \(tip.prefix(7)), \(dateFormatter.string(from: Date(timeIntervalSince1970: at))).")
        }
        if status != nil, let expiry = brick.expiry(state) {
            lines.append("No check can contradict it: served until \(dateFormatter.string(from: Date(timeIntervalSince1970: expiry))) unless you confirm it again.")
        }
        if let macOS = brick.macOS { lines.append("Reviewed again on each new macOS (validated on macOS \(state.reconfirmedMacOS ?? macOS)).") }
        if let bases = brick.restsOn, !bases.isEmpty {
            lines.append("Rests on " + bases.map { base in
                let status = bricks.status(of: base)
                return "\(base) (\(status == .open ? "served" : status?.title ?? "gone"))"
            }.joined(separator: ", ") + ".")
        }
        let resting = bricks.loaded.resting(on: id)
        if !resting.isEmpty { lines.append("Bricks resting on it: " + resting.joined(separator: ", ") + ".") }
        // Flags since the user last confirmed it: older ones were answered.
        let flags = bricks.flags.filter { $0.brick == id && $0.time > (state.reconfirmedAt ?? 0) }
        if !flags.isEmpty {
            lines.append("")
            lines.append("Agents flagged it:")
            lines += flags.suffix(3).map { "• \($0.kind.rawValue), \(dateFormatter.string(from: Date(timeIntervalSince1970: $0.time))): \($0.text)" }
        }
        if status != nil {
            let reach = bricks.reach[id] ?? .init()
            let corrections = switch reach.corrections {
            case 0: "no correction followed"
            case 1: "a correction followed in 1 (a correction in another task stops serving it)"
            default: "a correction followed in \(reach.corrections)"
            }
            lines.append("")
            lines.append("Reached \(reach.tasks) task\(reach.tasks == 1 ? "" : "s"); \(corrections).")
            if let validated = brick.validatedAt { lines.append("Validated \(dateFormatter.string(from: Date(timeIntervalSince1970: validated))).") }
        }
        return (meta, lines.joined(separator: "\n"))
    }

    @objc private func scopeChanged() {
        onScope(scopeControl.selectedSegment == 0 ? .always : .whenRelevant)
    }

    private func setHeaderHidden(_ hidden: Bool) {
        [titleLabel, metaLabel, separator, sourceLabel].forEach { $0.isHidden = hidden }
        if hidden { descriptionLabel.isHidden = true }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - Text

    nonisolated private static var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return [.font: Theme.Font.body, .foregroundColor: Theme.Color.textPrimary, .paragraphStyle: paragraph]
    }

    /// The memory's Markdown, read: `**bold**` in bold, `` `code` `` in
    /// mono, `[[links]]` linked when they name a memory, their marks gone.
    /// A link's URL names the memory's file: two memories can share a name.
    nonisolated static func text(of body: String, in contents: ProjectMemory.Contents?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: body, attributes: bodyAttributes)
        let length = (body as NSString).length
        /// Marks to remove once every range is styled: removing them first
        /// would move the ranges.
        var marks: [NSRange] = []
        /// Code spans: a `**` or `[[` inside one stays as written.
        var code: [NSRange] = []
        func isCode(_ range: NSRange) -> Bool { code.contains { NSIntersectionRange($0, range).length > 0 } }
        func matches(_ pattern: String) -> [NSRange] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: body, range: NSRange(location: 0, length: length)).map(\.range)
        }
        func addMarks(around range: NSRange, width: Int) {
            marks.append(NSRange(location: range.location, length: width))
            marks.append(NSRange(location: NSMaxRange(range) - width, length: width))
        }
        code = matches(#"`[^`\n]+`"#)
        // Bold around code keeps its code in mono: code is styled after.
        for range in matches(#"\*\*[^*\n]+\*\*"#) where !isCode(NSRange(location: range.location, length: 2))
            && !isCode(NSRange(location: NSMaxRange(range) - 2, length: 2)) {
            text.addAttribute(.font, value: Theme.Font.bodyEmphasized, range: range)
            addMarks(around: range, width: 2)
        }
        for range in code {
            text.addAttributes([.font: Theme.Font.code, .foregroundColor: Theme.Color.textSecondary], range: range)
            addMarks(around: range, width: 1)
        }
        for link in ProjectMemory.links(in: body) where !isCode(link.range) {
            if let contents, let index = contents.index(ofMemoryNamed: link.name),
               let url = linkURL(fileName: contents.memories[index].fileName) {
                text.addAttributes([.link: url, .toolTip: contents.memories[index].title], range: link.range)
            } else {
                text.addAttributes([
                    .foregroundColor: Theme.Color.textTertiary, .toolTip: "No memory named \(link.name)"
                ], range: link.range)
            }
            addMarks(around: link.range, width: 2)
        }
        for mark in marks.sorted(by: { $0.location > $1.location }) { text.deleteCharacters(in: mark) }
        return text
    }

    nonisolated static func linkURL(fileName: String) -> URL? {
        var components = URLComponents()
        components.scheme = linkScheme
        components.path = fileName
        return components.url
    }
}

extension ProjectMemoryPreview: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        editUndo
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)), url.scheme == Self.linkScheme,
              let fileName = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
        else { return true }
        onLink(fileName)
        return true
    }
}

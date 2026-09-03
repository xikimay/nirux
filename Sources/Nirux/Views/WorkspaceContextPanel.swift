import AppKit

struct WorkspaceContextValues {
    let purpose: String
    let phase: WorkspacePhase?
    let lastSummary: String
    let nextStep: String
    let blocker: String
}

struct WorkspaceContextPanelConfiguration {
    let title: String
    let cwd: String
    let purpose: String?
    let phaseOverride: WorkspacePhase?
    let effectivePhase: WorkspacePhase
    let lastSummary: String?
    let lastSummaryIsManual: Bool
    let lastActivityAt: TimeInterval?
    let nextStep: String?
    let blocker: String?
    let gitBranch: String?
    let diffStats: String?
    let prInfo: PRInfo?
    let agentStatuses: [AgentStatus]
}

/// Detailed workspace-memory editor opened from the sidebar card menu.
/// Human-owned fields are editable; live Git/PR/agent state is presented in
/// a read-only block so the normal sidebar can stay compact.
@MainActor
final class WorkspaceContextPanel {
    enum ShortcutAction: Equatable {
        case cancel
        case save
    }

    var onSave: ((WorkspaceContextValues) -> Void)?

    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var cwdLabel: NSTextField?
    private var purposeEditor: NSTextView?
    private var phasePopUp: NSPopUpButton?
    private var summaryEditor: NSTextView?
    private var summaryHelpLabel: NSTextField?
    private var nextStepField: NSTextField?
    private var blockerField: NSTextField?
    private var liveContextLabel: NSTextField?

    private static let size = NSSize(width: 660, height: 640)

    func show(relativeTo window: NSWindow, configuration: WorkspaceContextPanelConfiguration) {
        if panel == nil { createPanel() }
        guard let panel else { return }

        titleLabel?.stringValue = configuration.title
        cwdLabel?.stringValue = configuration.cwd
        cwdLabel?.toolTip = configuration.cwd
        purposeEditor?.string = configuration.purpose ?? ""
        summaryEditor?.string = configuration.lastSummary ?? ""
        nextStepField?.stringValue = configuration.nextStep ?? ""
        blockerField?.stringValue = configuration.blocker ?? ""
        summaryHelpLabel?.stringValue = configuration.lastSummaryIsManual
            ? "User-owned summary — automatic agent updates will not replace it. Clear it to resume automatic summaries."
            : "Agent turn completions update this automatically until you edit it."
        configurePhaseMenu(
            override: configuration.phaseOverride,
            effective: configuration.effectivePhase
        )
        liveContextLabel?.stringValue = Self.liveContextText(configuration)

        let windowFrame = window.frame
        let x = windowFrame.midX - Self.size.width / 2
        let y = windowFrame.midY - Self.size.height / 2
        panel.setFrame(NSRect(x: x, y: y, width: Self.size.width, height: Self.size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(purposeEditor)
    }

    private func configurePhaseMenu(override: WorkspacePhase?, effective: WorkspacePhase) {
        guard let phasePopUp else { return }
        phasePopUp.removeAllItems()
        phasePopUp.addItem(withTitle: "Automatic — \(effective.displayName)")
        for phase in WorkspacePhase.allCases {
            phasePopUp.addItem(withTitle: "\(phase.symbol)  \(phase.displayName)")
        }
        if let override, let index = WorkspacePhase.allCases.firstIndex(of: override) {
            phasePopUp.selectItem(at: index + 1)
        } else {
            phasePopUp.selectItem(at: 0)
        }
    }

    private func createPanel() {
        let panel = makePanel()
        let container = makeContainer()

        let heading = NSTextField(labelWithString: "Workspace Context")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = NSColor.white.withAlphaComponent(0.48)
        heading.frame = NSRect(x: 24, y: 600, width: 200, height: 18)
        container.addSubview(heading)

        let title = NSTextField(labelWithString: "")
        title.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        title.textColor = NSColor.white.withAlphaComponent(0.94)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 24, y: 570, width: Self.size.width - 48, height: 26)
        container.addSubview(title)

        let cwd = NSTextField(labelWithString: "")
        cwd.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        cwd.textColor = NSColor.white.withAlphaComponent(0.36)
        cwd.lineBreakMode = .byTruncatingMiddle
        cwd.frame = NSRect(x: 24, y: 550, width: Self.size.width - 48, height: 16)
        container.addSubview(cwd)

        container.addSubview(fieldLabel("Purpose", y: 521))
        let purpose = makeTextEditor(frame: NSRect(x: 24, y: 464, width: Self.size.width - 48, height: 52))
        container.addSubview(purpose.scrollView)

        container.addSubview(fieldLabel("Phase", y: 436))
        let phase = NSPopUpButton(frame: NSRect(x: 24, y: 402, width: 230, height: 28), pullsDown: false)
        phase.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        container.addSubview(phase)

        container.addSubview(fieldLabel("Latest meaningful summary", y: 372))
        let summary = makeTextEditor(frame: NSRect(x: 24, y: 294, width: Self.size.width - 48, height: 72))
        container.addSubview(summary.scrollView)
        let summaryHelp = NSTextField(labelWithString: "")
        summaryHelp.font = .systemFont(ofSize: 10, weight: .regular)
        summaryHelp.textColor = NSColor.white.withAlphaComponent(0.34)
        summaryHelp.lineBreakMode = .byTruncatingTail
        summaryHelp.frame = NSRect(x: 24, y: 276, width: Self.size.width - 48, height: 14)
        container.addSubview(summaryHelp)

        let halfWidth = (Self.size.width - 60) / 2
        container.addSubview(fieldLabel("Next step", y: 246))
        container.addSubview(fieldLabel("Blocker", x: 36 + halfWidth, y: 246))
        let nextStep = makeSingleLineField(frame: NSRect(x: 24, y: 210, width: halfWidth, height: 28))
        nextStep.placeholderString = "What should happen next?"
        container.addSubview(nextStep)
        let blocker = makeSingleLineField(frame: NSRect(x: 36 + halfWidth, y: 210, width: halfWidth, height: 28))
        blocker.placeholderString = "What is preventing progress?"
        container.addSubview(blocker)

        container.addSubview(fieldLabel("Live context", y: 179))
        let liveBackground = NSView(frame: NSRect(x: 24, y: 61, width: Self.size.width - 48, height: 112))
        liveBackground.wantsLayer = true
        liveBackground.layer?.cornerRadius = 7
        liveBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
        liveBackground.layer?.borderWidth = 1
        liveBackground.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        container.addSubview(liveBackground)
        let live = NSTextField(wrappingLabelWithString: "")
        live.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        live.textColor = NSColor.white.withAlphaComponent(0.52)
        live.maximumNumberOfLines = 6
        live.frame = NSRect(x: 12, y: 9, width: liveBackground.bounds.width - 24, height: 94)
        liveBackground.addSubview(live)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: Self.size.width - 206, y: 17, width: 82, height: 30)
        container.addSubview(cancel)
        let save = NSButton(title: "Save Context", target: self, action: #selector(saveAction))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: Self.size.width - 118, y: 17, width: 94, height: 30)
        container.addSubview(save)

        panel.contentView = container
        self.panel = panel
        titleLabel = title
        cwdLabel = cwd
        purposeEditor = purpose.textView
        phasePopUp = phase
        summaryEditor = summary.textView
        summaryHelpLabel = summaryHelp
        nextStepField = nextStep
        blockerField = blocker
        liveContextLabel = live
        installShortcutMonitor(for: panel)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovable = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    private func makeContainer() -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor(red: 0.105, green: 0.105, blue: 0.14, alpha: 0.99).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
        container.layer?.masksToBounds = true
        return container
    }

    private func installShortcutMonitor(for panel: NSPanel) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, let panel, panel.isVisible,
                  let action = Self.shortcutAction(
                      keyCode: event.keyCode,
                      modifierFlags: event.modifierFlags,
                      eventWindow: event.window,
                      panel: panel
                  )
            else { return event }
            switch action {
            case .cancel:
                self.cancelAction()
                return nil
            case .save:
                self.saveAction()
                return nil
            }
        }
    }

    static func shortcutAction(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventWindow: AnyObject?,
        panel: AnyObject
    ) -> ShortcutAction? {
        guard eventWindow === panel else { return nil }
        if keyCode == 0x35 { return .cancel }
        if [0x24, 0x4C].contains(keyCode), modifierFlags.contains(.command) {
            return .save
        }
        return nil
    }

    private func fieldLabel(_ text: String, x: CGFloat = 24, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .monospacedSystemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.46)
        label.frame = NSRect(x: x, y: y, width: 260, height: 14)
        return label
    }

    private func makeTextEditor(frame: NSRect) -> (scrollView: NSScrollView, textView: NSTextView) {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let editor = NSTextView(frame: scroll.bounds)
        editor.font = .systemFont(ofSize: 12.5, weight: .regular)
        editor.textColor = NSColor.white.withAlphaComponent(0.88)
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.textContainerInset = NSSize(width: 8, height: 7)
        editor.autoresizingMask = [.width]
        scroll.documentView = editor
        return (scroll, editor)
    }

    private func makeSingleLineField(frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.font = .systemFont(ofSize: 12, weight: .regular)
        field.textColor = NSColor.white.withAlphaComponent(0.88)
        field.backgroundColor = NSColor.white.withAlphaComponent(0.035)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        return field
    }

    @objc private func cancelAction() {
        panel?.orderOut(nil)
    }

    @objc private func saveAction() {
        let selectedIndex = phasePopUp?.indexOfSelectedItem ?? 0
        let phase = selectedIndex > 0 ? WorkspacePhase.allCases[safe: selectedIndex - 1] : nil
        let values = WorkspaceContextValues(
            purpose: purposeEditor?.string ?? "",
            phase: phase,
            lastSummary: summaryEditor?.string ?? "",
            nextStep: nextStepField?.stringValue ?? "",
            blocker: blockerField?.stringValue ?? ""
        )
        panel?.orderOut(nil)
        onSave?(values)
    }

    static func liveContextText(_ configuration: WorkspaceContextPanelConfiguration) -> String {
        let activity: String
        if let timestamp = configuration.lastActivityAt {
            let age = SidebarView.relativeAge(since: timestamp)
            let date = Date(timeIntervalSince1970: timestamp).formatted(
                date: .abbreviated,
                time: .shortened
            )
            activity = "Activity  \(date) (\(age) ago)"
        } else {
            activity = "Activity  No agent activity recorded"
        }

        let branch = configuration.gitBranch ?? "No Git branch"
        let git = [branch, configuration.diffStats].compactMap { $0 }.joined(separator: "  ·  ")

        let pullRequest: String
        if let pr = configuration.prInfo {
            let ci = pr.ciStatus.map { "  ·  CI \($0.lowercased())" } ?? ""
            pullRequest = "PR        #\(pr.number) \(pr.state.lowercased())\(ci)"
        } else {
            pullRequest = "PR        None detected"
        }

        let working = configuration.agentStatuses.filter { $0 == .working }.count
        let waiting = configuration.agentStatuses.filter { $0 == .needsAttention }.count
        let agents = "Agents    \(working) working  ·  \(waiting) waiting  ·  \(configuration.agentStatuses.count) columns"
        return [activity, "Git       \(git)", pullRequest, agents, "Path      \(configuration.cwd)"]
            .joined(separator: "\n")
    }
}

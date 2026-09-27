import Foundation

/// What the checklist card asks its owner to do.
enum OnboardingChecklistAction: Equatable, Sendable {
    case installSkills
    case checkAgain
    case close
}

/// One step of the checklist as the card renders it. Kept free of AppKit so
/// the wording and the offered controls are unit-testable.
struct OnboardingChecklistRow: Equatable {
    enum Mark: Equatable {
        case done
        case todo
        /// Not done, and nothing the user needs to do from here.
        case off
    }

    enum Control: Equatable {
        /// Filled button.
        case button(String, OnboardingChecklistAction)
        /// Link-styled action.
        case action(String, OnboardingChecklistAction)
        /// Monospaced command; clicking copies it.
        case copyCommand(String)
        /// Opens in the default browser.
        case link(String, URL)
    }

    let mark: Mark
    let title: String
    let detail: String?
    let controls: [Control]
}

extension OnboardingChecklist {
    /// The documented installers that need nothing preinstalled (Claude
    /// Code's native installer) or only Homebrew. The project links cover
    /// the other methods (npm needs Node.js).
    static let claudeInstallCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    static let codexInstallCommand = "brew install --cask codex"
    static let claudeProjectURL = URL(string: "https://github.com/anthropics/claude-code")!
    static let codexProjectURL = URL(string: "https://github.com/openai/codex")!
    static let hooksDocumentationURL = URL(string: "https://github.com/xikimay/nirux#agent-status-hooks")!

    var rows: [OnboardingChecklistRow] { [agentRow, skillsRow, hooksRow] }

    var agentRow: OnboardingChecklistRow {
        switch (agents.claudePath, agents.codexPath) {
        case (.some, .some):
            return OnboardingChecklistRow(
                mark: .done, title: "Claude Code and Codex found",
                detail: "Start one from ⌘P → Open Claude Code or Open Codex.", controls: []
            )
        case (.some(let path), nil):
            // The path shows where the lookup looked, since it can't run the
            // shell's startup files (see AgentCLILocator).
            return OnboardingChecklistRow(
                mark: .done, title: "Claude Code found",
                detail: "At \(path.abbreviatedPath(maxComponents: 8)). Start it from ⌘P → Open Claude Code.",
                controls: []
            )
        case (nil, .some(let path)):
            return OnboardingChecklistRow(
                mark: .done, title: "Codex found",
                detail: "At \(path.abbreviatedPath(maxComponents: 8)). Start it from ⌘P → Open Codex.",
                controls: []
            )
        case (nil, nil):
            return OnboardingChecklistRow(
                mark: .todo, title: "Install Claude Code or Codex",
                detail: "Nirux didn't find claude or codex in the usual places. Install one (click to copy), "
                    + "or close this if you already have it.",
                controls: [
                    .copyCommand(Self.claudeInstallCommand),
                    .copyCommand(Self.codexInstallCommand),
                    .link("Claude Code ↗", Self.claudeProjectURL),
                    .link("Codex ↗", Self.codexProjectURL),
                    .action("Check again", .checkAgain)
                ]
            )
        }
    }

    var skillsRow: OnboardingChecklistRow {
        let purpose = "Lets agents open worktree workspaces and show code in the editor."
        switch skills {
        case .installed:
            return OnboardingChecklistRow(
                mark: .done, title: "Agent Skills installed", detail: purpose, controls: []
            )
        case .missing:
            return OnboardingChecklistRow(
                mark: .todo, title: "Install Agent Skills", detail: purpose,
                controls: [.button("Install", .installSkills)]
            )
        case .outdated:
            return OnboardingChecklistRow(
                mark: .todo, title: "Update Agent Skills",
                detail: "The installed copies differ from this version of Nirux. Update replaces them.",
                controls: [.button("Update", .installSkills)]
            )
        }
    }

    var hooksRow: OnboardingChecklistRow {
        let files = "~/.claude/settings.json and ~/.codex/config.toml"
        let learnMore = OnboardingChecklistRow.Control.link("How status hooks work ↗", Self.hooksDocumentationURL)
        guard hooks.anyInstalled else {
            return OnboardingChecklistRow(
                mark: .off,
                title: hooks.installsHooks ? "Status hooks not installed" : "Status hooks off in this build",
                detail: hooks.installsHooks
                    ? "Nirux couldn't add them to \(files), so agent status is estimated from terminal output."
                    : "This build leaves \(files) untouched (development build or NIRUX_SKIP_HOOK_INSTALL).",
                controls: [learnMore]
            )
        }
        let title: String
        if hooks.claude && hooks.codex {
            title = "Status hooks installed"
        } else {
            title = hooks.claude ? "Status hooks installed for Claude Code" : "Status hooks installed for Codex"
        }
        return OnboardingChecklistRow(
            mark: .done, title: title,
            detail: "Nirux adds entries to \(files) so each column shows exact agent status.",
            controls: [learnMore]
        )
    }

    /// Chords the card teaches, in display order.
    static let shortcuts: [(key: String, label: String)] = [
        (NiruxShortcuts.commandPalette.chord.display, "palette"),
        (NiruxShortcuts.newTerminal.chord.display, "column"),
        (NiruxShortcuts.newWorkspace.chord.display, "workspace"),
        (NiruxShortcuts.pilotMode.chord.display, "pilot mode")
    ]
}

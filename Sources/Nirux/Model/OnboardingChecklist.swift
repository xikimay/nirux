import Foundation

/// Lifecycle of the first-launch checklist, persisted in settings.
enum OnboardingChecklistState: String, Codable, Sendable {
    /// Shown in the expanded sidebar until the user closes it.
    case pending
    /// Closed with every actionable step done.
    case completed
    /// Closed before every actionable step was done.
    case dismissed
}

/// Which agent CLIs a Nirux terminal would find, with the path found.
struct AgentCLIAvailability: Hashable, Sendable {
    var claudePath: String?
    var codexPath: String?

    var anyFound: Bool { claudePath != nil || codexPath != nil }
}

/// The bundled agent skills compared with the copies on disk.
enum AgentSkillsStatus: Hashable, Sendable {
    /// Every copy matches the skills this build ships.
    case installed
    /// Some copies are missing or differ (an older Nirux wrote them).
    case outdated
    /// No copy at all.
    case missing
}

/// Whether the agent-status hooks are present in the agents' configs.
struct AgentHooksStatus: Hashable, Sendable {
    /// Every Claude Code event Nirux listens to has a Nirux entry in
    /// ~/.claude/settings.json.
    var claude: Bool
    /// ~/.codex/config.toml runs Nirux as its `notify` program.
    var codex: Bool
    /// False when this build never writes the hooks (development builds,
    /// NIRUX_SKIP_HOOK_INSTALL).
    var installsHooks: Bool

    var anyInstalled: Bool { claude || codex }
}

/// What the first-launch checklist shows. Every field is read from disk, so
/// refreshing it is cheap enough for launch and explicit re-checks.
struct OnboardingChecklist: Hashable {
    var agents: AgentCLIAvailability
    var skills: AgentSkillsStatus
    var hooks: AgentHooksStatus

    /// The steps the user can act on from the checklist. Hooks install
    /// themselves at launch (or can't be fixed from here) and shortcuts are
    /// only for reading, so neither holds completion back.
    var isComplete: Bool { agents.anyFound && skills == .installed }

    /// State recorded when the user closes the checklist.
    var closedState: OnboardingChecklistState { isComplete ? .completed : .dismissed }

    /// Checklist state at launch, from what was on disk before this launch
    /// saved anything. Nil hides the checklist without recording a state:
    /// - a state file that has workspaces but no checklist key predates the
    ///   checklist, so it belongs to a user who is already set up;
    /// - `hasUnreadableState`: state files exist but none could be read (a
    ///   newer build's format, damage). That is not a fresh install either.
    static func launchState(
        persisted: PersistedState?, hasUnreadableState: Bool = false
    ) -> OnboardingChecklistState? {
        if let saved = persisted?.settings?.onboardingChecklist { return saved }
        if let persisted, !persisted.workspaces.isEmpty { return nil }
        if persisted == nil, hasUnreadableState { return nil }
        return .pending
    }

    /// The sidebar starts collapsed, which would hide the checklist. Open it
    /// while the checklist is pending and the user has no sidebar preference
    /// yet (a fresh install); a saved preference always wins.
    static func shouldExpandSidebarAtLaunch(persisted: PersistedState?, hasUnreadableState: Bool = false) -> Bool {
        launchState(persisted: persisted, hasUnreadableState: hasUnreadableState) == .pending
            && persisted?.settings?.sidebarExpanded == nil
    }

    /// Settings as the shell saves them. A nil state (a user set up before
    /// the checklist existed) keeps whatever is saved, so saving never adds
    /// the key for them.
    static func settings(
        _ settings: PersistedSettings, recording state: OnboardingChecklistState?
    ) -> PersistedSettings {
        var settings = settings
        if let state { settings.onboardingChecklist = state }
        return settings
    }
}

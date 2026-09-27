import AppKit

// MARK: - Getting Started checklist

extension NiruxShellView {
    /// Decides whether the checklist shows this launch, from the state on
    /// disk before anything saved. A fresh install also gets the sidebar
    /// open, where the checklist lives.
    func decideOnboardingChecklist(persisted: PersistedState?, hasUnreadableState: Bool) {
        onboardingState = OnboardingChecklist.launchState(
            persisted: persisted, hasUnreadableState: hasUnreadableState
        )
        guard OnboardingChecklist.shouldExpandSidebarAtLaunch(
            persisted: persisted, hasUnreadableState: hasUnreadableState
        ) else { return }
        isSidebarExpanded = true
        sidebar.isExpanded = true
        relayout(animated: false)
    }

    /// Every step as it is on disk now.
    func currentOnboardingChecklist() -> OnboardingChecklist {
        OnboardingChecklist(
            agents: AgentCLILocator.locate(),
            skills: AgentSkillsInstaller.status(of: Self.agentSkills, home: NSHomeDirectory()),
            hooks: AgentHookInstaller.status()
        )
    }

    /// Re-reads every step and shows the card while the checklist is
    /// pending, or hides it.
    func refreshOnboardingChecklist() {
        sidebar.onboardingChecklist = onboardingState == .pending ? currentOnboardingChecklist() : nil
    }

    func handleOnboardingAction(_ action: OnboardingChecklistAction) {
        switch action {
        case .installSkills:
            installAgentSkills(confirmsSuccess: false)
        case .checkAgain:
            refreshOnboardingChecklist()
        case .close:
            guard onboardingState == .pending else { return }
            onboardingState = currentOnboardingChecklist().closedState
            refreshOnboardingChecklist()
            saveState()
        }
    }

    /// Palette action: brings a closed checklist back, and shows it to users
    /// who were set up before it existed.
    func showOnboardingChecklist() {
        onboardingState = .pending
        saveState()
        // Pilot mode hides the sidebar and toggleSidebar() ignores it there.
        if isPilotMode { togglePilotMode() }
        refreshOnboardingChecklist()
        if !isSidebarExpanded { toggleSidebar() }
        sidebar.revealOnboardingCard()
    }
}

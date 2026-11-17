import AppKit

// MARK: - Space Settings › Safety (ClaudeSpaceSettings, LoopRecap)

extension NiruxShellView {
    func spaceSettingsSafetyModel(
        for space: WorkspaceProfile, shown: SpaceSettingsSafetyPane.Model = .init()
    ) -> SpaceSettingsSafetyPane.Model {
        let loaded = SpaceDefaultsStore(spaceID: space.id)?.load()
        let defaults = loaded?.defaults ?? SpaceDefaults()
        let since = Date().timeIntervalSince1970 - Double(shown.periodDays) * 86_400
        return SpaceSettingsSafetyPane.Model(
            on: Set(ClaudeSpaceSettings.Part.allCases.filter(defaults.isOn)),
            repositories: ClaudeSpaceSettings.repositories(space.anchors),
            canChange: loaded?.isWritable ?? false,
            problem: loaded?.problem,
            periodDays: shown.periodDays,
            recap: LoopRecap.groups(LoopLog.load(spaceID: space.id), since: since),
            logFull: LoopLog.isFull(spaceID: space.id),
            added: defaults.addedLines
        )
    }

    /// Saved in the space's defaults.json; a part set to its default writes
    /// nothing. Sessions get it at their next launch.
    func setClaudeSafety(_ part: ClaudeSpaceSettings.Part, on: Bool, spaceID: String) {
        changeSpaceDefaults(spaceID: spaceID) { $0.set(part, on: on) }
        refreshSpaceSettingsSafety()
    }

    /// A line the user added or removed from the recap.
    func changeClaudeLines(spaceID: String, _ change: (inout SpaceDefaults) -> Void) {
        changeSpaceDefaults(spaceID: spaceID, change)
        refreshSpaceSettingsSafety()
    }

    /// The pane as the files hold it now, over the period it shows.
    func refreshSpaceSettingsSafety(periodDays: Int? = nil) {
        guard let settings = spaceSettings, let space = profiles.first(where: { $0.id == settings.spaceID }) else { return }
        var shown = settings.safety.model
        if let periodDays { shown.periodDays = periodDays }
        let model = spaceSettingsSafetyModel(for: space, shown: shown)
        if model != settings.safety.model { settings.safety.update(model) }
        settings.fitToContent()
    }
}

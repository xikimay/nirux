import AppKit

// MARK: - Space Settings › Safety (ClaudeSpaceSettings)

extension NiruxShellView {
    func spaceSettingsSafetyModel(for space: WorkspaceProfile) -> SpaceSettingsSafetyPane.Model {
        let loaded = SpaceDefaultsStore(spaceID: space.id)?.load()
        let defaults = loaded?.defaults ?? SpaceDefaults()
        return SpaceSettingsSafetyPane.Model(
            on: Set(ClaudeSpaceSettings.Part.allCases.filter(defaults.isOn)),
            repositories: ClaudeSpaceSettings.repositories(space.anchors),
            canChange: loaded?.isWritable ?? false,
            problem: loaded?.problem
        )
    }

    /// Saved in the space's defaults.json; a part set to its default writes
    /// nothing. Sessions get it at their next launch.
    func setClaudeSafety(_ part: ClaudeSpaceSettings.Part, on: Bool, spaceID: String) {
        changeSpaceDefaults(spaceID: spaceID) { $0.set(part, on: on) }
        refreshSpaceSettingsSafety()
    }

    func refreshSpaceSettingsSafety() {
        guard let settings = spaceSettings, let space = profiles.first(where: { $0.id == settings.spaceID }) else { return }
        let model = spaceSettingsSafetyModel(for: space)
        if model != settings.safety.model { settings.safety.update(model) }
    }
}

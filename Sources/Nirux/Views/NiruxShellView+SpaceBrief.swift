import AppKit

// MARK: - Space brief (see SpaceBrief)

extension NiruxShellView {
    /// `--append-system-prompt <text of briefFile>`, the text read by the
    /// shell as one word. Claude refuses in-session restarts (a version
    /// switch, /tui, the restart after /login) for sessions launched with
    /// `--append-system-prompt-file`, not with `--append-system-prompt`.
    /// `command cat` skips a user's `cat` alias or function. `"$(…)"` stays
    /// one word even for an emptied brief (fish needs 3.4 for it; fish's
    /// `(…)` would give no word at all and swallow the next argument). tcsh
    /// and csh keep the file flag: they have no command substitution that
    /// keeps a multi-line text in one word.
    static func claudeAppendSystemPromptArguments(briefFile: String, shell: String) -> [String] {
        switch (shell as NSString).lastPathComponent {
        case "tcsh", "csh": return [Self.shellQuotedArgument("--append-system-prompt-file=" + briefFile)]
        default: return ["--append-system-prompt", "\"$(command cat \(Self.shellQuotedArgument(briefFile)))\""]
        }
    }

    /// `developer_instructions=<TOML string read from briefFile>` as one
    /// shell word. A shell runs the launch line, so the brief itself can't go
    /// inline: the shell reads the one-line file. `command cat` skips a user's
    /// `cat` alias or function. Nil for tcsh and csh, which lack `$(…)`.
    static func codexDeveloperInstructionsOverride(briefFile: String, shell: String) -> String? {
        let read = "command cat \(Self.shellQuotedArgument(briefFile))"
        switch (shell as NSString).lastPathComponent {
        case "tcsh", "csh": return nil
        // fish before 3.4 has no `$(…)`; `(…)` works in every version.
        case "fish": return "\"developer_instructions=\"(\(read))"
        default: return "\"developer_instructions=$(\(read))\""
        }
    }

    /// Writes the brief files for `workspace`'s space and returns them, or
    /// nil when the space has no brief.
    func spaceBriefInjection(for workspace: WorkspaceState) -> SpaceBrief.Injection? {
        SpaceBrief.prepareInjection(spaceID: workspace.profileID)
    }

    /// Opens the space's brief in an editor column, creating it on first use.
    func editSpaceBrief(profileID: String) {
        let spaceName = workspaceStore.profiles.first { $0.id == profileID }?.name ?? profileID
        do {
            guard let url = try SpaceBrief.ensureBriefFile(spaceID: profileID, spaceName: spaceName) else {
                NSSound.beep()
                return
            }
            // A tab in the workspace's usual editor: rooting an editor at the
            // brief's folder would make it the workspace's working directory.
            openInEditorColumn(path: url.path)
        } catch {
            NiruxDebugLog.log("SpaceBrief: could not create the brief file: \(error)")
            NSSound.beep()
        }
    }

    /// The Codex brief file, unless one of the user's Codex configs already
    /// sets `developer_instructions`, which Nirux must not override: the user
    /// config (`$CODEX_HOME` when Nirux sees it, else ~/.codex) and project
    /// configs (`.codex/config.toml`) from `launchDirectory` up to the home
    /// folder.
    static func codexBriefFile(from injection: SpaceBrief.Injection?, launchDirectory: String) -> String? {
        guard let injection else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        var configs = [codexHome.appendingPathComponent("config.toml")]
        var folder = URL(fileURLWithPath: launchDirectory).standardizedFileURL
        while folder.path.hasPrefix(home.path + "/") {
            configs.append(folder.appendingPathComponent(".codex/config.toml"))
            folder.deleteLastPathComponent()
        }
        for config in configs {
            if let text = try? String(contentsOf: config, encoding: .utf8),
               SpaceBrief.codexConfigSetsDeveloperInstructions(text) {
                return nil
            }
        }
        return injection.codexInstructionsFile
    }
}

import AppKit
import GhosttyTerminal

/// Builds the libghostty config for Nirux terminals in layers: Nirux's
/// defaults, the user's theme (or Nirux's colors), the appearance settings
/// from the user's Ghostty config, then the keys Nirux always owns.
/// Everything else in the Ghostty config (keybinds, window and macOS
/// options, shell/command settings, …) is ignored: Nirux routes input and
/// spawns shells itself.
enum TerminalConfigBuilder {
    /// Ghostty keys honored from the user's config and theme: fonts, cell
    /// metrics, colors and cursor. `theme` itself is handled separately.
    static let honoredKeys: Set<String> = [
        "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic",
        "font-style", "font-style-bold", "font-style-italic", "font-style-bold-italic",
        "font-synthetic-style", "font-feature", "font-variation", "font-variation-bold",
        "font-variation-italic", "font-variation-bold-italic", "font-codepoint-map",
        "font-size", "font-thicken", "font-thicken-strength", "font-shaping-break",
        "adjust-cell-width", "adjust-cell-height", "adjust-font-baseline",
        "adjust-underline-position", "adjust-underline-thickness",
        "adjust-strikethrough-position", "adjust-strikethrough-thickness",
        "adjust-overline-position", "adjust-overline-thickness",
        "adjust-cursor-thickness", "adjust-cursor-height", "adjust-box-thickness",
        "adjust-icon-height",
        "background", "foreground", "palette", "palette-generate", "palette-harmonious",
        "bold-color", "minimum-contrast", "faint-opacity", "alpha-blending", "window-colorspace",
        "selection-foreground", "selection-background",
        "search-foreground", "search-background",
        "search-selected-foreground", "search-selected-background",
        "cursor-color", "cursor-text", "cursor-opacity", "cursor-style", "cursor-style-blink",
        // Deprecated, still mapped by Ghostty 1.3.
        "bold-is-bright", "cursor-invert-fg-bg", "selection-invert-fg-bg"
    ]

    /// Nirux's look when the Ghostty config doesn't override it:
    /// libghostty-spm's `TerminalConfiguration.default`, written out so a
    /// library update can't silently change it, and its Afterglow palette.
    /// Both are what Nirux terminals have always rendered with (the window
    /// is forced to dark appearance, which selects Afterglow).
    static let niruxDefaults = [
        "cursor-style = block",
        "cursor-style-blink = true",
        "font-size = 14",
        "font-thicken = true"
    ]
    static let niruxColors = TerminalConfiguration.afterglow.rendered.split(separator: "\n").map(String.init)
    /// Applied last so nothing overrides them.
    static let enforced = ["term = xterm-256color"]

    /// A setting kept for the final config, from the user's config or from
    /// the theme it selects.
    struct UserLine: Equatable {
        let entry: GhosttyConfigEntry
        let isTheme: Bool

        var text: String { entry.line }
    }

    /// Honored lines: the selected theme's, then the config's, in order.
    ///
    /// The theme file is inlined rather than passed as `theme = <path>`,
    /// which is equivalent (Ghostty loads a theme first and replays the
    /// config over it) but keeps its lines under the allowlist, above
    /// Nirux's defaults, and validated one by one. It is found with
    /// `resolveTheme`; when that fails it is returned as `unresolvedTheme`.
    static func userLines(
        from entries: [GhosttyConfigEntry],
        resolveTheme: (String) -> String?,
        readFile: (String) -> String? = GhosttyConfigFile.readRegularFile
    ) -> (lines: [UserLine], unresolvedTheme: GhosttyConfigEntry?) {
        let settings = entries
            .filter { honoredKeys.contains($0.key) }
            .map { UserLine(entry: $0, isTheme: false) }
        guard let theme = selectedTheme(in: entries) else { return (settings, nil) }
        guard let name = darkThemeName(theme.value),
              let path = resolveTheme(name),
              let contents = readFile(path)
        else { return (settings, theme) }

        let themeLines = GhosttyConfigFile.parse(contents, source: path)
            .filter { honoredKeys.contains($0.key) }
            .map { UserLine(entry: $0, isTheme: true) }
        return (themeLines + settings, nil)
    }

    /// The `theme` entry in effect, picked as Ghostty does: the last one
    /// whose value parses (an invalid value leaves the previous theme in
    /// place). Nil when there is none or when it is empty, which clears
    /// the theme.
    static func selectedTheme(in entries: [GhosttyConfigEntry]) -> GhosttyConfigEntry? {
        let selected = entries.last { entry in
            entry.key == "theme" && entry.line.contains("=")
                && (entry.value.isEmpty || darkThemeName(entry.value) != nil)
        }
        guard let selected, !selected.value.isEmpty else { return nil }
        return selected
    }

    /// The theme Nirux renders with. Nirux forces a dark appearance, so a
    /// `light:A,dark:B` pair resolves to B, as it would in Ghostty. Returns
    /// nil for a value Ghostty would reject.
    static func darkThemeName(_ value: String) -> String? {
        // Same pair detection as Ghostty's Theme.parseCLI.
        guard value.contains(",") || value.contains(":") || value.contains("=") else {
            return value.isEmpty ? nil : value
        }
        var variants: [String: String] = [:]
        for part in splitOutsideQuotes(value) {
            guard let separator = part.firstIndex(of: ":") else { return nil }
            let name = part[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == "light" || name == "dark" else { return nil }
            var theme = part[part.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if theme.count >= 2, theme.hasPrefix("\""), theme.hasSuffix("\"") {
                theme = String(theme.dropFirst().dropLast())
            }
            variants[name] = theme
        }
        guard variants["light"]?.isEmpty == false, let dark = variants["dark"], !dark.isEmpty else {
            return nil
        }
        return dark
    }

    /// Non-blank comma-separated parts, ignoring commas inside double
    /// quotes (Ghostty's CommaSplitter).
    private static func splitOutsideQuotes(_ value: String) -> [Substring] {
        var parts: [Substring] = []
        var start = value.startIndex
        var quoted = false
        for index in value.indices {
            if value[index] == "\"" {
                quoted.toggle()
            } else if value[index] == ",", !quoted {
                parts.append(value[start..<index])
                start = value.index(after: index)
            }
        }
        parts.append(value[start...])
        return parts.filter { !$0.allSatisfy(\.isWhitespace) }
    }

    /// Resolves a theme the way Ghostty's themepkg.open does: an absolute
    /// path is used as is; a bare name is looked up in each directory of
    /// `searchDirectories`, in order (evaluated lazily).
    static func resolveTheme(
        _ name: String,
        searchDirectories: [() -> String?],
        isFile: (String) -> Bool = GhosttyConfigFile.isRegularFile
    ) -> String? {
        if name.hasPrefix("/") {
            return isFile(name) ? name : nil
        }
        guard !name.contains("/") else { return nil }
        for directory in searchDirectories {
            guard let directory = directory() else { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            if isFile(path) { return path }
        }
        return nil
    }

    /// Afterglow keys that only suit Afterglow's own background.
    static let backgroundBoundColorKeys: Set<String> = ["cursor-color", "selection-background"]

    /// Nirux's lines before the user's. Nirux's colors are left out when a
    /// theme is used: like in Ghostty, keys the theme doesn't set fall back
    /// to Ghostty's defaults. When the user sets their own background or
    /// foreground, Afterglow's cursor and selection colors are left out
    /// too, as they could vanish against it.
    static func baseLines(for user: [UserLine]) -> [String] {
        if user.contains(where: \.isTheme) { return niruxDefaults }
        guard user.contains(where: { $0.entry.key == "background" || $0.entry.key == "foreground" }) else {
            return niruxDefaults + niruxColors
        }
        let colors = niruxColors.filter { line in
            let key = line.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
            return !backgroundBoundColorKeys.contains(key)
        }
        return niruxDefaults + colors
    }

    /// Full config text for the given user lines.
    static func render(_ user: [UserLine]) -> String {
        (baseLines(for: user) + user.map(\.text) + enforced).joined(separator: "\n") + "\n"
    }

    /// Drops the user lines libghostty rejects — a single invalid line
    /// makes it discard the whole config. `diagnostics` returns
    /// libghostty's config diagnostics for a config text, nil if accepted.
    /// Rejected lines are found by the line numbers in the report; an
    /// error without one drops every user line.
    static func sanitize(
        _ user: [UserLine],
        diagnostics: (String) -> String?
    ) -> (contents: String, dropped: [UserLine]) {
        var kept = user
        var dropped: [UserLine] = []
        while !kept.isEmpty, let report = diagnostics(render(kept)) {
            // Line numbers index into the rendered text; map them to `kept`.
            let userStart = baseLines(for: kept).count
            let rejected = Set(rejectedLineNumbers(in: report).map { $0 - 1 - userStart })
                .filter(kept.indices.contains)
            guard !rejected.isEmpty else {
                dropped += kept
                kept = []
                break
            }
            dropped += kept.indices.filter(rejected.contains).map { kept[$0] }
            kept = kept.indices.filter { !rejected.contains($0) }.map { kept[$0] }
        }
        return (render(kept), dropped)
    }

    /// libghostty-spm's prefix for config diagnostics, as opposed to other
    /// failures such as writing its temporary file.
    static let diagnosticsPrefix = "ghostty config diagnostics: "

    /// Line numbers of the diagnostics located in the config text
    /// libghostty-spm generated (`…/ghostty-config-<UUID>.conf:<line>:…`).
    /// Each diagnostic is matched from its start, so a rejected value that
    /// looks like a location can't point at another line.
    static func rejectedLineNumbers(in report: String) -> [Int] {
        guard report.hasPrefix(diagnosticsPrefix) else { return [] }
        let location = /[^:|]*\/ghostty-config-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.conf:(\d+):/
        return report.dropFirst(diagnosticsPrefix.count)
            .split(separator: " | ")
            .compactMap { $0.prefixMatch(of: location).flatMap { Int($0.output.1) } }
    }
}

/// Creates the TerminalController of each Nirux terminal from the user's
/// Ghostty config, re-read for every new terminal so edits apply to
/// terminals opened afterwards.
@MainActor
enum TerminalAppearance {
    /// Hidden off switch: `defaults write com.xikimay.nirux
    /// IgnoreGhosttyConfig -bool true` makes terminals ignore the Ghostty
    /// config.
    static let ignoreGhosttyConfigKey = "IgnoreGhosttyConfig"

    /// Last config validated against libghostty, keyed by its input, so
    /// opening terminals doesn't re-validate an unchanged config.
    private static var lastSanitized: (input: [TerminalConfigBuilder.UserLine], contents: String)?

    static func makeController() -> TerminalController {
        // An empty theme: libghostty-spm's default one would be appended
        // after the user's colors and override them.
        let controller = TerminalController(configSource: .generated(currentConfig()), theme: TerminalTheme())
        if let issue = controller.lastConfigurationIssue {
            // libghostty-spm fell back to its own defaults; validate again
            // for the next terminal.
            NSLog("[GhosttyConfig] terminal config rejected: %@", issue)
            lastSanitized = nil
        }
        return controller
    }

    static func currentConfig() -> String {
        guard !UserDefaults.standard.bool(forKey: ignoreGhosttyConfigKey) else {
            return TerminalConfigBuilder.render([])
        }
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entries = GhosttyConfigFile.load(
            paths: GhosttyConfigFile.defaultPaths(environment: environment, home: home),
            home: home
        )
        let userThemes = (GhosttyConfigFile.xdgConfigHome(environment: environment, home: home) as NSString)
            .appendingPathComponent("ghostty/themes")
        let (user, unresolvedTheme) = TerminalConfigBuilder.userLines(from: entries) {
            TerminalConfigBuilder.resolveTheme($0, searchDirectories: [{ userThemes }, { ghosttyAppThemesDirectory }])
        }
        if let lastSanitized, lastSanitized.input == user {
            return lastSanitized.contents
        }

        if let entry = unresolvedTheme {
            NSLog("[GhosttyConfig] ignoring %@:%ld: theme not found", entry.source, entry.lineNumber)
        }
        let result = TerminalConfigBuilder.sanitize(user, diagnostics: libghosttyDiagnostics)
        for line in result.dropped {
            NSLog(
                "[GhosttyConfig] ignoring %@:%ld (%@): rejected by libghostty",
                line.entry.source, line.entry.lineNumber, line.entry.key
            )
        }
        lastSanitized = (user, result.contents)
        return result.contents
    }

    /// libghostty's config diagnostics for a config text, nil if it accepts
    /// it. A throwaway controller runs the same validation as the real one.
    /// Other failures (e.g. writing its temporary file) aren't the config's
    /// fault and count as accepted; `makeController` catches them.
    private static func libghosttyDiagnostics(_ contents: String) -> String? {
        let issue = TerminalController(configSource: .generated(contents), theme: TerminalTheme())
            .lastConfigurationIssue
        return issue?.hasPrefix(TerminalConfigBuilder.diagnosticsPrefix) == true ? issue : nil
    }

    /// Themes bundled with Ghostty.app, when it is installed. Looked up on
    /// first use only: most configs never need it.
    private static let ghosttyAppThemesDirectory: String? = {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
        return app?.appendingPathComponent("Contents/Resources/ghostty/themes").path
    }()
}

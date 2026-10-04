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
    /// libghostty-spm's `TerminalConfiguration.default` and its Afterglow
    /// palette, which Nirux terminals have always rendered with (the window
    /// is forced to dark appearance, which selects Afterglow). Written out
    /// so a library update can't silently change them.
    static let niruxDefaults = [
        "cursor-style = block",
        "cursor-style-blink = true",
        "font-size = 14",
        "font-thicken = true"
    ]
    static let niruxColors = [
        "background = 212121",
        "foreground = D0D0D0",
        "cursor-color = D0D0D0",
        "selection-background = 303030"
    ] + ["#151515", "#AC4142", "#7E8E50", "#E4B567", "#6C99BB", "#9F4E86", "#7DD5CF", "#D0D0D0",
         "#505050", "#AC4142", "#7E8E50", "#E4B567", "#6C99BB", "#9F4E86", "#7DD5CF", "#F5F5F5"]
        .enumerated().map { "palette = \($0.offset)=\($0.element)" }
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
    /// nil for a value Ghostty would reject (Theme.parseCLI and
    /// parseAutoStruct in ghostty/src).
    static func darkThemeName(_ value: String) -> String? {
        let whitespace = CharacterSet(charactersIn: " \t")
        guard value.contains(",") || value.contains(":") || value.contains("=") else {
            return value.isEmpty ? nil : value.trimmingCharacters(in: whitespace)
        }
        guard let parts = splitOutsideQuotes(value) else { return nil }
        var variants: [String: String] = [:]
        for part in parts {
            guard let separator = part.firstIndex(of: ":") else { return nil }
            let name = part[..<separator].trimmingCharacters(in: whitespace)
            guard name == "light" || name == "dark" else { return nil }
            let theme = part[part.index(after: separator)...].trimmingCharacters(in: whitespace)
            if GhosttyConfigFile.isQuoted(theme) {
                guard let decoded = decodeQuoted(theme) else { return nil }
                variants[name] = decoded
            } else {
                variants[name] = theme
            }
        }
        guard variants["light"] != nil else { return nil }
        return variants["dark"]
    }

    /// Comma-separated parts, ignoring commas inside double quotes or
    /// escaped with a backslash; a trailing comma ends the list. Like
    /// Ghostty's CommaSplitter, escapes are checked but kept as written,
    /// and an unclosed quote or illegal escape fails.
    private static func splitOutsideQuotes(_ value: String) -> [String]? {
        let scalars = Array(value.unicodeScalars)
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        var quoted = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                guard let end = escapeEnd(scalars, from: index + 1) else { return nil }
                current.append(contentsOf: scalars[index..<end])
                index = end
                continue
            }
            if scalar == ",", !quoted {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                if scalar == "\"" { quoted.toggle() }
                current.append(scalar)
            }
            index += 1
        }
        guard !quoted else { return nil }
        if !current.isEmpty {
            parts.append(String(current))
        }
        return parts
    }

    /// End index of the escape sequence starting at `start`, right after a
    /// backslash, as CommaSplitter validates it: `\n`, `\r`, `\t`, `\\`,
    /// `\'`, `\"`, `\x` and two hex digits, or `\u{…}` with hex digits
    /// (bounded by CommaSplitter's own value check). Nil if illegal.
    private static func escapeEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        guard start < scalars.count else { return nil }
        switch scalars[start] {
        case "n", "r", "t", "\\", "'", "\"":
            return start + 1
        case "x":
            let digits = scalars.dropFirst(start + 1).prefix(2)
            return digits.count == 2 && digits.allSatisfy(\.properties.isASCIIHexDigit) ? start + 3 : nil
        case "u":
            guard start + 1 < scalars.count, scalars[start + 1] == "{" else { return nil }
            // CommaSplitter maps a-f to 0-5 in this check; kept for parity.
            var value = 0
            var index = start + 2
            while index < scalars.count, scalars[index] != "}" {
                guard scalars[index].properties.isASCIIHexDigit else { return nil }
                let digit = Int(scalars[index].value)
                value = value << 4 + (digit >= 0x61 ? digit - 0x61 : digit >= 0x41 ? digit - 0x41 : digit - 0x30)
                guard value <= 0x10FFFF else { return nil }
                index += 1
            }
            guard index < scalars.count, index > start + 2 else { return nil }
            return index + 1
        default:
            return nil
        }
    }

    /// Decodes a double-quoted value as a Zig string literal, as Ghostty's
    /// parseAutoStruct does: `\xNN` is a raw byte, and decoding stops at
    /// an unescaped quote. Nil when an escape is malformed.
    private static func decodeQuoted(_ value: String) -> String? {
        let scalars = Array(value.unicodeScalars.dropFirst())
        var bytes: [UInt8] = []
        var index = 0
        while index < scalars.count, scalars[index] != "\"" {
            guard scalars[index] == "\\" else {
                bytes += Array(String(scalars[index]).utf8)
                index += 1
                continue
            }
            let start = index + 1
            guard let end = escapeEnd(scalars, from: start) else { return nil }
            let body = String(String.UnicodeScalarView(scalars[(start + 1)..<end]))
            switch scalars[start] {
            case "n": bytes.append(0x0A)
            case "r": bytes.append(0x0D)
            case "t": bytes.append(0x09)
            case "x": bytes.append(UInt8(body, radix: 16) ?? 0)
            case "u":
                guard let value = UInt32(body.dropFirst().dropLast(), radix: 16),
                      let scalar = Unicode.Scalar(value)
                else { return nil }
                bytes += Array(String(scalar).utf8)
            default: bytes += Array(String(scalars[start]).utf8)
            }
            index = end
        }
        // Lossy: a byte sequence that isn't UTF-8 can't name a theme file.
        return String(decoding: bytes, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    /// Resolves a theme the way Ghostty's themepkg.open does: an absolute
    /// path is used as is; a bare name is looked up in each directory of
    /// `searchDirectories`, in order (evaluated lazily), and the search
    /// stops at an entry that exists but isn't a regular file.
    static func resolveTheme(
        _ name: String,
        searchDirectories: [() -> String?],
        pathKind: (String) -> GhosttyConfigFile.PathKind = GhosttyConfigFile.pathKind
    ) -> String? {
        if name.hasPrefix("/") {
            return pathKind(name) == .regularFile ? name : nil
        }
        guard !name.contains("/") else { return nil }
        for directory in searchDirectories {
            guard let directory = directory() else { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            switch pathKind(path) {
            case .regularFile: return path
            case .other: return nil
            case .missing: continue
            }
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
    /// Each diagnostic is matched from its start, and must name the same
    /// file as the first one, so a rejected value echoed in a message can't
    /// point at another line.
    static func rejectedLineNumbers(in report: String) -> [Int] {
        guard report.hasPrefix(diagnosticsPrefix) else { return [] }
        let location = /([^:|]*\/ghostty-config-[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.conf):(\d+):/
        var file: Substring?
        return report.dropFirst(diagnosticsPrefix.count)
            .split(separator: " | ")
            .compactMap { diagnostic in
                guard let match = diagnostic.prefixMatch(of: location) else { return nil }
                file = file ?? match.output.1
                return match.output.1 == file ? Int(match.output.2) : nil
            }
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

    /// Lines added at the end of each new terminal's config: none in the
    /// app. The tests turn vsync off (see their TestBootstrap).
    static var appendedLines: [String] = []

    static func makeController() -> TerminalController {
        let appended = appendedLines.map { $0 + "\n" }.joined()
        // An empty theme: libghostty-spm's default one would be appended
        // after the user's colors and override them.
        let controller = TerminalController(configSource: .generated(currentConfig() + appended), theme: TerminalTheme())
        guard let issue = controller.lastConfigurationIssue else { return controller }
        NSLog("[GhosttyConfig] terminal config rejected: %@", issue)
        // A failure that isn't the config's (e.g. writing libghostty-spm's
        // temporary file) would recur whatever the config.
        guard issue.hasPrefix(TerminalConfigBuilder.diagnosticsPrefix) else { return controller }
        // libghostty-spm fell back to its own defaults: use Nirux's look
        // instead, and validate the config again for the next terminal.
        lastSanitized = nil
        return TerminalController(configSource: .generated(TerminalConfigBuilder.render([]) + appended), theme: TerminalTheme())
    }

    static func currentConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        defaults: UserDefaults = .standard
    ) -> String {
        guard !defaults.bool(forKey: ignoreGhosttyConfigKey) else {
            return TerminalConfigBuilder.render([])
        }
        let entries = GhosttyConfigFile.load(
            paths: GhosttyConfigFile.defaultPaths(environment: environment, home: home),
            home: GhosttyConfigFile.ghosttyHome(environment: environment, home: home)
        )
        let userThemes = (GhosttyConfigFile.xdgConfigHome(environment: environment, home: home) as NSString)
            .appendingPathComponent("ghostty/themes")
        let (user, unresolvedTheme) = TerminalConfigBuilder.userLines(from: entries) {
            TerminalConfigBuilder.resolveTheme($0, searchDirectories: [{ userThemes }, ghosttyAppThemesDirectory])
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

    private static var cachedGhosttyAppThemesDirectory: String?

    /// Themes bundled with Ghostty.app, when it is installed. Only needed
    /// for bundled theme names; the Launch Services lookup is repeated
    /// until it finds the app, and when the app moves.
    private static func ghosttyAppThemesDirectory() -> String? {
        if let cached = cachedGhosttyAppThemesDirectory, FileManager.default.fileExists(atPath: cached) {
            return cached
        }
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
        cachedGhosttyAppThemesDirectory = app?.appendingPathComponent("Contents/Resources/ghostty/themes").path
        return cachedGhosttyAppThemesDirectory
    }
}

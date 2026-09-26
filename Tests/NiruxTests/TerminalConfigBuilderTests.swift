import GhosttyTerminal
import XCTest
@testable import Nirux

final class TerminalConfigBuilderTests: XCTestCase {

    private typealias Builder = TerminalConfigBuilder

    private func entries(_ contents: String) -> [GhosttyConfigEntry] {
        GhosttyConfigFile.parse(contents, source: "/cfg/config")
    }

    /// `themes` maps a theme name to its file contents, served from `/t/<name>`.
    private func userLines(
        _ contents: String,
        themes: [String: String] = [:]
    ) -> (lines: [Builder.UserLine], unresolvedTheme: GhosttyConfigEntry?) {
        Builder.userLines(
            from: entries(contents),
            resolveTheme: { themes[$0] == nil ? nil : "/t/\($0)" },
            readFile: { path in themes[(path as NSString).lastPathComponent] }
        )
    }

    private func renderedLines(_ user: [Builder.UserLine]) -> [String] {
        Builder.render(user).split(separator: "\n").map(String.init)
    }

    // MARK: - Defaults

    func testWithoutUserConfigNiruxKeepsItsCurrentLook() {
        // What Nirux rendered before reading the Ghostty config: the
        // libghostty-spm defaults plus its Afterglow dark palette.
        let lines = renderedLines([])
        XCTAssertEqual(Array(lines.prefix(4)), [
            "cursor-style = block", "cursor-style-blink = true", "font-size = 14", "font-thicken = true"
        ])
        XCTAssertEqual(
            Array(lines.dropFirst(4).dropLast()),
            TerminalConfiguration.afterglow.rendered.split(separator: "\n").map(String.init)
        )
        XCTAssertTrue(lines.contains("background = 212121"))
        XCTAssertEqual(lines.last, "term = xterm-256color")
    }

    // MARK: - Honored keys

    func testOnlyAppearanceKeysAreHonored() {
        let user = userLines("""
        keybind = cmd+t=new_tab
        term = xterm-ghostty
        command = /bin/bash
        window-padding-x = 20
        background-opacity = 0.8
        macos-titlebar-style = hidden
        config-file = other
        font-family = JetBrains Mono
        adjust-cell-height = 10%
        palette = 1=#ff0000
        cursor-style = bar
        bold-is-bright = true
        window-colorspace = display-p3
        """).lines
        XCTAssertEqual(user.map(\.entry.key), [
            "font-family", "adjust-cell-height", "palette", "cursor-style", "bold-is-bright", "window-colorspace"
        ])
    }

    func testUserSettingsOverrideDefaultsAndEnforcedKeysComeLast() {
        let lines = renderedLines(userLines("font-size = 16\nbackground = #101010\nterm = dumb").lines)
        XCTAssertGreaterThan(lines.lastIndex(of: "font-size = 16") ?? 0, lines.firstIndex(of: "font-size = 14") ?? .max)
        XCTAssertGreaterThan(
            lines.firstIndex(of: "background = #101010") ?? 0,
            lines.firstIndex(of: "background = 212121") ?? .max
        )
        XCTAssertFalse(lines.contains("term = dumb"))
        XCTAssertEqual(lines.last, "term = xterm-256color")
    }

    func testOwnBackgroundDropsAfterglowCursorAndSelection() {
        let lines = renderedLines(userLines("background = #2e3440").lines)
        XCTAssertFalse(lines.contains { $0.hasPrefix("cursor-color") || $0.hasPrefix("selection-background") })
        XCTAssertTrue(lines.contains("palette = 1=#AC4142"), "the Afterglow palette stays")
        XCTAssertTrue(lines.contains("foreground = D0D0D0"))

        let foregroundOnly = renderedLines(userLines("foreground = #eceff4").lines)
        XCTAssertFalse(foregroundOnly.contains { $0.hasPrefix("selection-background") })
        XCTAssertTrue(renderedLines(userLines("font-size = 15").lines).contains("selection-background = 303030"))
    }

    // MARK: - Themes

    func testThemeIsInlinedBetweenDefaultsAndUserSettings() {
        let theme = "background = #1e1e2e\nfont-size = 22\nbackground-opacity = 0.3\nkeybind = a=b\npalette = 1=#f38ba8"
        let user = userLines("font-family = Menlo\ntheme = Mocha\npalette = 1=#ff0000", themes: ["Mocha": theme])
        XCTAssertNil(user.unresolvedTheme)
        XCTAssertEqual(renderedLines(user.lines), Builder.niruxDefaults + [
            // The theme's, allowlisted: it overrides Nirux's defaults...
            "background = #1e1e2e", "font-size = 22", "palette = 1=#f38ba8",
            // ...and the user's settings override it, whatever their position.
            "font-family = Menlo", "palette = 1=#ff0000"
        ] + Builder.enforced)
        XCTAssertEqual(user.lines.first?.entry.source, "/t/Mocha")
    }

    func testUnresolvedThemeIsReportedAndNiruxColorsStay() {
        let result = userLines("theme = Nope\nfont-size = 15")
        XCTAssertEqual(result.lines.map(\.entry.key), ["font-size"])
        XCTAssertEqual(result.unresolvedTheme?.value, "Nope")
        XCTAssertTrue(renderedLines(result.lines).contains("background = 212121"))
    }

    func testDarkVariantOfAPairIsUsed() {
        let themes = ["Latte": "background = #eff1f5", "Mocha Dark": "background = #1e1e2e"]
        let lines = userLines("theme = light:Latte,dark:\"Mocha Dark\"", themes: themes).lines
        XCTAssertEqual(lines.map(\.text), ["background = #1e1e2e"])
    }

    func testSelectedThemeFollowsGhostty() {
        let pick = { (config: String) in Builder.selectedTheme(in: self.entries(config))?.value }
        XCTAssertEqual(pick("theme = A\ntheme = B"), "B")
        // An invalid value leaves the previous theme in place...
        XCTAssertEqual(pick("theme = A\ntheme = light:B"), "A")
        XCTAssertEqual(pick("theme = A\ntheme"), "A")
        // ...an empty one clears it.
        XCTAssertNil(pick("theme = A\ntheme ="))
        XCTAssertNil(pick("font-size = 12"))
        // A missing last theme isn't replaced by an earlier one.
        let result = userLines("theme = A\ntheme = Missing", themes: ["A": "background = #000000"])
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.unresolvedTheme?.value, "Missing")
    }

    func testDarkThemeName() {
        XCTAssertEqual(Builder.darkThemeName("TokyoNight"), "TokyoNight")
        XCTAssertEqual(Builder.darkThemeName(" Nord\t"), "Nord")
        XCTAssertEqual(Builder.darkThemeName("light:Catppuccin Latte,dark:Catppuccin Mocha"), "Catppuccin Mocha")
        XCTAssertEqual(Builder.darkThemeName(" dark: B , light: A ,"), "B", "one trailing comma is fine")
        XCTAssertEqual(Builder.darkThemeName("light:\"Rose Pine Dawn\",dark:\"Rose, Pine\""), "Rose, Pine")
        XCTAssertEqual(Builder.darkThemeName("light:,dark:Mocha"), "Mocha", "an empty variant parses")
        XCTAssertEqual(Builder.darkThemeName("light:A,dark:"), "")
        XCTAssertNil(Builder.darkThemeName("dark:B"))
        XCTAssertNil(Builder.darkThemeName("light:A,dark:B,dusk:C"))
        XCTAssertNil(Builder.darkThemeName("light:A,,dark:B"))
        XCTAssertNil(Builder.darkThemeName(",light:A,dark:B"))
        XCTAssertNil(Builder.darkThemeName("light:A,dark:\"B"), "unclosed quote")
        XCTAssertNil(Builder.darkThemeName("light:A,dark:B\\"), "dangling escape")
        XCTAssertNil(Builder.darkThemeName("light=A,dark=B"))
        XCTAssertNil(Builder.darkThemeName(""))
    }

    func testResolveThemeSearchesDirectoriesInOrderAndLazily() {
        let files: Set<String> = ["/user/themes/Mine", "/app/themes/Mine", "/app/themes/Builtin", "/abs/theme"]
        var appLookups = 0
        let directories: [() -> String?] = [{ "/user/themes" }, { appLookups += 1; return "/app/themes" }]
        let resolve = { (name: String) in
            Builder.resolveTheme(name, searchDirectories: directories) { files.contains($0) }
        }
        XCTAssertEqual(resolve("Mine"), "/user/themes/Mine")
        XCTAssertEqual(resolve("/abs/theme"), "/abs/theme")
        XCTAssertEqual(appLookups, 0)
        XCTAssertEqual(resolve("Builtin"), "/app/themes/Builtin")
        XCTAssertNil(resolve("/abs/missing"))
        XCTAssertNil(resolve("sub/Mine"))
        XCTAssertNil(resolve("Missing"))
        XCTAssertNil(Builder.resolveTheme("Mine", searchDirectories: [{ nil }]) { _ in true })
    }

    // MARK: - Sanitizing

    /// Mimics libghostty-spm's report for the lines of `contents` matching
    /// `isInvalid`.
    private func fakeDiagnostics(rejecting isInvalid: @escaping (String) -> Bool) -> (String) -> String? {
        { contents in
            let located = contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .filter { isInvalid(String($0.element)) }
                .map { "/tmp/ghostty-config-6E2CDE4E-264A-44C6-BE8A-7F769BA3773B.conf:\($0.offset + 1):key: invalid value" }
            return located.isEmpty ? nil : Builder.diagnosticsPrefix + located.joined(separator: " | ")
        }
    }

    func testSanitizeKeepsAcceptedConfig() {
        let user = userLines("font-size = 15").lines
        let result = Builder.sanitize(user) { _ in nil }
        XCTAssertEqual(result.contents, Builder.render(user))
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func testSanitizeDropsOnlyRejectedLines() {
        let user = userLines("font-family = Menlo\nfont-size = abc\ncursor-style = nope\nfont-size = 15").lines
        let result = Builder.sanitize(user, diagnostics: fakeDiagnostics { $0.contains("abc") || $0.contains("nope") })
        XCTAssertEqual(result.dropped.map(\.entry.lineNumber), [2, 3])
        XCTAssertTrue(result.contents.contains("font-family = Menlo\nfont-size = 15\n"))
    }

    func testSanitizeDropsRejectedThemeLinesOneByOne() {
        let theme = "background = #000000\npalette = 1=#zz"
        let user = userLines("theme = T\nfont-size = abc", themes: ["T": theme]).lines
        let result = Builder.sanitize(user, diagnostics: fakeDiagnostics { $0.contains("abc") || $0.contains("#zz") })
        XCTAssertEqual(result.dropped.map(\.text), ["palette = 1=#zz", "font-size = abc"])
        XCTAssertTrue(result.contents.contains("background = #000000\n"))
        XCTAssertFalse(result.contents.contains("background = 212121"))
    }

    func testSanitizeRestoresNiruxColorsWhenEveryThemeLineIsRejected() {
        let user = userLines("theme = T\nfont-size = 15", themes: ["T": "palette = 1=#zz"]).lines
        let result = Builder.sanitize(user, diagnostics: fakeDiagnostics { $0.contains("#zz") })
        XCTAssertEqual(result.dropped.map(\.isTheme), [true])
        XCTAssertTrue(result.contents.contains("background = 212121"))
        XCTAssertTrue(result.contents.contains("font-size = 15"))
    }

    func testSanitizeMapsLinesWhenAfterglowIsTrimmed() {
        // An own background shortens Nirux's lines: numbering must follow,
        // and dropping that background brings the full Afterglow back.
        let user = userLines("background = #zz\nfont-size = abc\nfont-size = 15").lines
        let result = Builder.sanitize(user, diagnostics: fakeDiagnostics { $0.contains("#zz") || $0.contains("abc") })
        XCTAssertEqual(result.dropped.map(\.entry.lineNumber), [1, 2])
        XCTAssertEqual(result.contents, Builder.render([user[2]]))
        XCTAssertTrue(result.contents.contains("selection-background = 303030"))
    }

    func testSanitizeFallsBackToDefaultsOnUnlocatedErrors() {
        let user = userLines("font-size = 15\nfont-family = Menlo").lines
        let result = Builder.sanitize(user) { _ in Builder.diagnosticsPrefix + "something went wrong" }
        XCTAssertEqual(result.contents, Builder.render([]))
        XCTAssertEqual(result.dropped.count, 2)
    }

    func testSanitizeWithoutUserLinesSkipsValidation() {
        let result = Builder.sanitize([]) { _ in
            XCTFail("defaults need no validation")
            return nil
        }
        XCTAssertEqual(result.contents, Builder.render([]))
    }

    func testRejectedLineNumbersAreAnchoredToEachDiagnostic() {
        let file = "/var/T/ghostty-config-6E2CDE4E-264A-44C6-BE8A-7F769BA3773B.conf"
        let report = Builder.diagnosticsPrefix + "\(file):2:font-size: invalid value \"x \(file):25:\" | "
            + "/t/theme:3:palette: invalid value | theme \"X\" not found | \(file):7:bogus: unknown field"
        XCTAssertEqual(Builder.rejectedLineNumbers(in: report), [2, 7])
        XCTAssertEqual(Builder.rejectedLineNumbers(in: "failed to write generated ghostty config: \(file):2:"), [])

        // An echoed value containing " | " can't smuggle in another file.
        let fake = "/t/ghostty-config-00000000-0000-0000-0000-000000000000.conf"
        let injected = Builder.diagnosticsPrefix + "\(file):25:cursor-style: invalid value \"x | \(fake):30:\""
        XCTAssertEqual(Builder.rejectedLineNumbers(in: injected), [25])
    }
}

/// Runs the real libghostty validation, to catch drift between these
/// assumptions and the library (report format, rejection behavior).
@MainActor
final class TerminalConfigLibghosttyTests: XCTestCase {

    private func diagnostics(_ contents: String) -> String? {
        TerminalController(configSource: .generated(contents), theme: .init()).lastConfigurationIssue
    }

    private func sanitize(
        _ config: String,
        theme: String? = nil
    ) -> (contents: String, dropped: [TerminalConfigBuilder.UserLine]) {
        let user = TerminalConfigBuilder.userLines(
            from: GhosttyConfigFile.parse(config, source: "/cfg/config"),
            resolveTheme: { _ in theme == nil ? nil : "/t/theme" },
            readFile: { _ in theme }
        ).lines
        return TerminalConfigBuilder.sanitize(user, diagnostics: diagnostics)
    }

    func testDefaultsAreAccepted() {
        XCTAssertNil(diagnostics(TerminalConfigBuilder.render([])))
    }

    /// A temporary home with `files` under `~/.config/ghostty/`.
    private func makeHome(_ files: [String: String]) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-home-\(UUID().uuidString)")
        let ghostty = home.appendingPathComponent(".config/ghostty")
        try FileManager.default.createDirectory(at: ghostty.appendingPathComponent("themes"), withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: ghostty.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home.path
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "nirux-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    func testOffSwitchIgnoresTheGhosttyConfig() throws {
        let home = try makeHome(["config": "font-size = 15\n"])
        let defaults = try makeDefaults()
        XCTAssertTrue(TerminalAppearance.currentConfig(environment: [:], home: home, defaults: defaults)
            .contains("font-size = 15"))

        defaults.set(true, forKey: TerminalAppearance.ignoreGhosttyConfigKey)
        XCTAssertEqual(
            TerminalAppearance.currentConfig(environment: [:], home: home, defaults: defaults),
            TerminalConfigBuilder.render([])
        )
    }

    func testThemeEditsReachTheNextTerminal() throws {
        let home = try makeHome(["config": "theme = Mine\n", "themes/Mine": "background = #111111\n"])
        let defaults = try makeDefaults()
        let config = { TerminalAppearance.currentConfig(environment: [:], home: home, defaults: defaults) }
        XCTAssertTrue(config().contains("background = #111111"))

        try "background = #222222\n".write(toFile: home + "/.config/ghostty/themes/Mine", atomically: true, encoding: .utf8)
        XCTAssertTrue(config().contains("background = #222222"))
    }

    func testDeprecatedAndColorspaceKeysAreAccepted() {
        let result = sanitize("bold-is-bright = true\ncursor-invert-fg-bg = true\nselection-invert-fg-bg = true\n"
            + "window-colorspace = display-p3\n")
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertNil(diagnostics(result.contents))
    }

    func testReportFormatIsUnderstood() throws {
        let report = try XCTUnwrap(diagnostics("font-size = 12\nfont-size = abc\n"))
        XCTAssertTrue(report.hasPrefix(TerminalConfigBuilder.diagnosticsPrefix))
        XCTAssertEqual(TerminalConfigBuilder.rejectedLineNumbers(in: report), [2])
    }

    func testInvalidLinesAreDroppedAndTheRestIsKept() {
        let result = sanitize("font-family = Menlo\nfont-size = abc\ncursor-style = sideways\nfont-size = 15\n")
        XCTAssertEqual(result.dropped.map(\.entry.lineNumber), [2, 3])
        XCTAssertNil(diagnostics(result.contents))
        XCTAssertTrue(result.contents.contains("font-family = Menlo\nfont-size = 15\n"))
    }

    func testInvalidThemeAndUserLinesAreDroppedIndividually() {
        let result = sanitize(
            "theme = light:T,dark:T\nfont-size = abc\nfont-family = Menlo\n",
            theme: "background = #0a0b0c\nforeground = nope\npalette = 2=#00ff00\n"
        )
        XCTAssertEqual(result.dropped.map(\.text), ["foreground = nope", "font-size = abc"])
        XCTAssertNil(diagnostics(result.contents))
        XCTAssertTrue(result.contents.contains("background = #0a0b0c\npalette = 2=#00ff00\nfont-family = Menlo\n"))
    }
}

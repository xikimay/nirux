import AppKit

/// Nirux's design tokens. Views take colors, fonts, spacing, radii and
/// symbols from here instead of literals. Tokens are named by role, never
/// by hue. ThemeGuardTests rejects literal colors outside this file.
///
/// Nirux is dark-only: windows and views set `appearance` rather than
/// naming `.darkAqua`. The web editor (EditorAssets) keeps its own CSS
/// palette, which the guard doesn't see.
enum Theme {
    static var appearance: NSAppearance? { NSAppearance(named: .darkAqua) }

    enum Color {
        // Backgrounds, deepest first.
        /// Window, Project Board, status bar, the gaps between columns.
        static let canvas = NSColor(hex: 0x16161B)
        /// Sidebar, file trees, settings windows, sheets and panels.
        static let base = NSColor(hex: 0x1B1B23)
        /// Cards, column headers, the active editor tab, find bars, toolbars.
        static let surface = NSColor(hex: 0x20202A)
        /// Above a surface: drag ghosts, menus, popovers, a toolbar's fields.
        static let raised = NSColor(hex: 0x292933)

        static let fillHover = NSColor.white.withAlphaComponent(0.05)
        static let fillPressed = NSColor.white.withAlphaComponent(0.09)
        static let fillSelected = accent.withAlphaComponent(0.16)
        static let line = NSColor.white.withAlphaComponent(0.07)
        static let lineStrong = NSColor.white.withAlphaComponent(0.12)

        static let textPrimary = NSColor(hex: 0xECECF1)
        /// Branches, subtitles.
        static let textSecondary = NSColor(hex: 0xA0A0AD)
        /// Durations, section labels, idle state.
        static let textTertiary = NSColor(hex: 0x6B6B79)
        static let textDisabled = NSColor(hex: 0x4A4A56)

        /// Focus, selection, links.
        static let accent = NSColor(hex: 0x78A3F7)

        // States: one color per state, used wherever that state shows.
        /// An agent works.
        static let working = NSColor(hex: 0x4CC38A)
        /// The same green for what went well: checks passed, secure URLs.
        /// Not for agent states: an agent that finished is idle, not green.
        static let success = working
        /// Something waits for the user's answer: an agent's permission or
        /// question, the editor's file conflict. Amber means nothing else:
        /// not warnings, not pending checks.
        static let waiting = NSColor(hex: 0xF5A623)
        /// An agent stopped on an error, a failed check, a refusal.
        static let error = NSColor(hex: 0xF0656B)
        /// A merged pull request (GitHub's merged purple).
        static let done = NSColor(hex: 0xA78BFA)
        static let idle = textTertiary

        /// `color` laid over `background` at `fraction`, opaque: a tinted
        /// surface that hides what is behind it. Mixed in sRGB, like the
        /// design values (`NSColor.blended` mixes in Generic RGB, lighter).
        static func tint(_ color: NSColor, _ fraction: CGFloat, over background: NSColor = base) -> NSColor {
            guard let top = color.usingColorSpace(.sRGB), let bottom = background.usingColorSpace(.sRGB) else {
                return background
            }
            func mix(_ under: CGFloat, _ over: CGFloat) -> CGFloat { under + (over - under) * fraction }
            return NSColor(
                srgbRed: mix(bottom.redComponent, top.redComponent),
                green: mix(bottom.greenComponent, top.greenComponent),
                blue: mix(bottom.blueComponent, top.blueComponent),
                alpha: 1
            )
        }
    }

    /// SF Pro in five sizes; SF Mono only for machine text (branches,
    /// paths, commands, SHAs, diffs). Computed: NSFont isn't Sendable.
    enum Font {
        /// Project name, panel titles.
        static var display: NSFont { NSFont.systemFont(ofSize: 15, weight: .semibold) }
        /// Card titles, palette rows.
        static var title: NSFont { NSFont.systemFont(ofSize: 13, weight: .semibold) }
        static var body: NSFont { NSFont.systemFont(ofSize: 12) }
        /// Column header titles.
        static var bodyEmphasized: NSFont { NSFont.systemFont(ofSize: 12, weight: .semibold) }
        /// Durations, counts, chips, tooltips.
        static var caption: NSFont { NSFont.systemFont(ofSize: 11) }
        /// Section labels only, uppercased and tracked by `labelKern`.
        static var label: NSFont { NSFont.systemFont(ofSize: 10, weight: .semibold) }
        static let labelKern: CGFloat = 0.6
        static var mono: NSFont { NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }
        /// Commands to approve, raw context.
        static var code: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }
    }

    /// A 4 pt grid. 2 pt stays allowed for optical alignment.
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        /// Chips, badges, key caps.
        static let chip: CGFloat = 4
        /// Buttons, fields, rows.
        static let control: CGFloat = 6
        /// Cards, columns, tiles.
        static let card: CGFloat = 8
        /// Palette, floating panels.
        static let panel: CGFloat = 12
    }

    /// SF Symbol names (regular weight; 14 pt in headers and the palette,
    /// 12 pt in chips). All exist on macOS 14.
    enum Symbol {
        static let terminal = "terminal"
        static let editor = "chevron.left.forwardslash.chevron.right"
        static let browser = "globe"
        static let projectBoard = "tablecells"
        static let newWorkspace = "plus.rectangle.on.rectangle"
        static let rename = "pencil"
        static let search = "magnifyingglass"
        static let resizeColumn = "arrow.left.and.right"
        static let diff = "plus.forwardslash.minus"
        static let webInspector = "ladybug"
        static let file = "doc.text"
        static let branch = "arrow.triangle.branch"
        static let openWorktree = "folder"
        static let cleanUp = "trash"
        static let pullRequest = "arrow.triangle.pull"
        static let merged = "arrow.triangle.merge"
        static let checksPassed = "checkmark"
        static let checksFailed = "xmark"
        static let checksRunning = "circle.dashed"
        static let sidebar = "sidebar.left"
        static let inactiveWorkspaces = "archivebox"
        static let settings = "gearshape"
        static let agentSkills = "puzzlepiece.extension"
        static let gettingStarted = "checklist"
        static let browserCookies = "key"
        static let keepAwake = "cup.and.saucer.fill"
        static let permission = "hand.raised"
        static let question = "bubble.left"
        static let agentError = "exclamationmark.triangle.fill"
        static let resume = "play.fill"
        static let more = "ellipsis"
        static let back = "chevron.left"
        static let forward = "chevron.right"
        static let reload = "arrow.clockwise"
        static let localServer = "arrow.up.right.square"
    }
}

extension NSColor {
    /// An sRGB color from 0xRRGGBB, like `NSColor(red:green:blue:alpha:)`.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// A color the user picked, as "#RRGGBB" or "RRGGBB"; nil if malformed.
    static func niruxColor(hex: String) -> NSColor? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return NSColor(hex: value)
    }
}

import AppKit

/// Nirux's design tokens. Views take colors, fonts, spacing, radii and
/// symbols from here instead of literals, so one change restyles the app.
/// Tokens are named by role, never by hue.
///
/// Nirux is dark-only: `appearance` is the one place that says so.
enum Theme {
    static var appearance: NSAppearance? { NSAppearance(named: .darkAqua) }

    enum Color {
        // Backgrounds, deepest first.
        /// Window, Project Board, status bar, the gaps between columns.
        static let canvas = NSColor(hex: 0x16161B)
        /// Sidebar, file trees, settings windows, sheets and panels.
        static let base = NSColor(hex: 0x1B1B23)
        /// Cards, column title bars, tab bars, find bars.
        static let surface = NSColor(hex: 0x20202A)
        /// What floats over content: drag ghosts, menus, popovers.
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

        // States: one color per state, the same wherever the state shows.
        /// An agent works.
        static let working = NSColor(hex: 0x4CC38A)
        /// The same green for what went well: checks passed, secure URLs.
        static let success = working
        /// An agent waits for the user. Amber means nothing else.
        static let waiting = NSColor(hex: 0xF5A623)
        /// An agent stopped on an error, a failed check, a refusal.
        static let error = NSColor(hex: 0xF0656B)
        /// A merged pull request (GitHub's merged purple).
        static let done = NSColor(hex: 0xA78BFA)
        static let idle = textTertiary

        /// `color` laid over `background` at `fraction`, opaque: a tinted
        /// surface that hides what is behind it.
        static func tint(_ color: NSColor, _ fraction: CGFloat, over background: NSColor = base) -> NSColor {
            background.blended(withFraction: fraction, of: color) ?? background
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
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
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

private extension NSColor {
    /// An sRGB color from 0xRRGGBB, like `NSColor(red:green:blue:alpha:)`.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

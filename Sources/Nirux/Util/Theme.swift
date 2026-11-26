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
        /// A chart's series, in this order: a categorical palette's dark
        /// steps (blue, orange, aqua, yellow, magenta), checked for colour
        /// blindness on `surface`. Beside a legend in a chart only: never a
        /// state's colour.
        static let chartSeries = [
            NSColor(hex: 0x3987E5), NSColor(hex: 0xD95926), NSColor(hex: 0x199E70), NSColor(hex: 0xC98500), NSColor(hex: 0xD55181)
        ]
        /// Above a surface: drag ghosts, menus, popovers, a toolbar's fields.
        static let raised = NSColor(hex: 0x292933)
        /// Over the row while the front editor column is up: dim, never blurred.
        static let frontShade = NSColor.black.withAlphaComponent(0.42)

        static let fillHover = NSColor.white.withAlphaComponent(0.05)
        static let fillPressed = NSColor.white.withAlphaComponent(0.09)
        static let fillSelected = accent.withAlphaComponent(0.16)
        /// The glass interface's selection (3.4): a pane of glass laid on the
        /// sidebar's selected row, rimmed with `line`, with `lineStrong`
        /// along its top edge.
        static let selectionGlass = NSColor.white.withAlphaComponent(0.10)
        /// An invented desktop, under the Appearance pane's miniatures.
        static let previewDesktop = [NSColor(hex: 0x3A5F8F), NSColor(hex: 0xC27A4E)]
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
        /// question. Amber means nothing else: not warnings, not pending
        /// checks, not a file conflict (`ThemeGuardTests` lists who may use it).
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
        /// What the user types in a floating panel: ⌘P, the pickers, the
        /// New sheet's description.
        static var input: NSFont { NSFont.systemFont(ofSize: 15) }
        /// Card titles, palette rows.
        static var title: NSFont { NSFont.systemFont(ofSize: 13, weight: .semibold) }
        static var body: NSFont { NSFont.systemFont(ofSize: 12) }
        /// Body text that stands out by weight, not colour: a changed file's
        /// name, a search hit's place, a done message.
        static var bodyMedium: NSFont { NSFont.systemFont(ofSize: 12, weight: .medium) }
        /// Column header titles.
        static var bodyEmphasized: NSFont { NSFont.systemFont(ofSize: 12, weight: .semibold) }
        /// Durations, counts, chips, tooltips.
        static var caption: NSFont { NSFont.systemFont(ofSize: 11) }
        /// Count badges and small headings.
        static var captionEmphasized: NSFont { NSFont.systemFont(ofSize: 11, weight: .semibold) }
        /// Times, counts and line numbers that change in place: digits of
        /// one width, so the text beside them doesn't shift.
        static var captionDigits: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
        /// Section labels only, uppercased and tracked by `labelKern`.
        static var label: NSFont { NSFont.systemFont(ofSize: 10, weight: .semibold) }
        static let labelKern: CGFloat = 0.6
        static var mono: NSFont { NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }
        /// Short codes in a chip or a badge: a file's git letter, a command
        /// to copy.
        static var monoBadge: NSFont { NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold) }
        /// Commands to approve, raw context.
        static var code: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }
        /// Titles in the glass interface's bars and lists (the command bar's
        /// task, the inbox's requests): medium, so the hierarchy comes from
        /// weight rather than colour.
        static var listTitle: NSFont { NSFont.systemFont(ofSize: 13, weight: .medium) }
        /// The glass interface's buttons (`NiruxButton`), in their two sizes.
        static var button: NSFont { NSFont.systemFont(ofSize: 12, weight: .medium) }
        static var buttonSmall: NSFont { NSFont.systemFont(ofSize: 11, weight: .medium) }
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
        /// A space's colour square in the glass interface: barely rounded,
        /// so it never reads as a state's dot.
        static let spaceMark: CGFloat = 2
        /// Buttons, fields, rows.
        static let control: CGFloat = 6
        /// Cards, tiles.
        static let card: CGFloat = 8
        /// A column's corners, circular: their clip stays within a terminal's
        /// padding (`TerminalConfigBuilder.padding`), so it cuts no cell.
        static let column: CGFloat = 10
        /// A chart bar's top, and its legend's swatches.
        static let chartBar: CGFloat = 4
        static let chartSwatch: CGFloat = 2
        /// Palette, floating panels.
        static let panel: CGFloat = 12
    }

    /// How high something lies over the window, told by its shadow
    /// (docs/design/glass-interface.md).
    enum Elevation {
        struct Level: Equatable, Sendable {
            let opacity: Float
            let radius: CGFloat
            let drop: CGFloat
            /// How far past its shape the shadow reaches.
            var reach: CGFloat { radius * 2 + drop }

            /// What floats over the work: the glass interface's floating glass.
            static let floating = Level(opacity: 0.38, radius: 16, drop: 12)
            /// A column, a card resting on the window: short enough to stay
            /// within the air around it (`WorkspaceState.columnInset`).
            static let column = Level(opacity: 0.3, radius: 2, drop: 1)
            /// The focused column, a level higher: darker, softer and further
            /// below, still within the air.
            static let focusedColumn = Level(opacity: 0.5, radius: 3, drop: 2)
            /// A control lifted under the pointer (`Relief`): short enough
            /// to stay within the rail's and the bar's edges.
            static let control = Level(opacity: 0.45, radius: 2, drop: 2)
        }

        /// Gives `layer` the shadow of `level` along the rounded rectangle
        /// `rect`, in the layer's own coordinates, its corners `radius` at
        /// most; call it again when the shape changes. With `cutOut`, then
        /// the layer's mask, the shadow falls only outside the shape, for a
        /// shape that lets it show through, as far as `cutOutReach` (the
        /// level's reach by default). The layer must not mask to its
        /// bounds, which would cut the shadow off.
        static func apply(
            _ level: Level, to layer: CALayer, roundedRect rect: CGRect, radius: CGFloat, cutOut: CAShapeLayer?, cutOutReach: CGFloat? = nil
        ) {
            let corner = max(0, min(radius, rect.width / 2, rect.height / 2))
            let shape = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = level.opacity
            layer.shadowRadius = level.radius
            // Below the shape, whichever way the layer counts y: a view's
            // backing layer is flipped exactly when the view is.
            layer.shadowOffset = CGSize(width: 0, height: layer.contentsAreFlipped() ? level.drop : -level.drop)
            layer.shadowPath = shape
            layer.mask = cutOut
            guard let cutOut else { return }
            let outside = CGMutablePath()
            let reach = cutOutReach ?? level.reach
            outside.addRect(rect.insetBy(dx: -reach, dy: -reach))
            outside.addPath(shape)
            cutOut.fillRule = .evenOdd
            cutOut.frame = layer.bounds
            cutOut.path = outside
        }
    }

    /// SF Symbol names (regular weight; 14 pt in headers and the palette,
    /// 12 pt in chips). All exist on macOS 14.
    enum Symbol {
        static let terminal = "terminal"
        static let editor = "chevron.left.forwardslash.chevron.right"
        static let browser = "globe"
        static let testBrowser = "testtube.2"
        static let projectBoard = "tablecells"
        static let branchReview = "checklist.checked"
        static let newWorkspace = "plus.rectangle.on.rectangle"
        /// The collapsed rail's "+".
        static let add = "plus"
        static let search = "magnifyingglass"
        static let diff = "plus.forwardslash.minus"
        static let webInspector = "ladybug"
        static let branch = "arrow.triangle.branch"
        static let openWorktree = "folder"
        static let pullRequest = "arrow.triangle.pull"
        static let merged = "arrow.triangle.merge"
        static let checksPassed = "checkmark"
        static let checksFailed = "xmark"
        /// Closes what the sidebar shows for a while (the catch-up card).
        static let dismiss = "xmark"
        static let checksRunning = "circle.dashed"
        static let inactiveWorkspaces = "archivebox"
        /// A space's Lead: its row and its rail tile.
        static let lead = "sparkle"
        /// The sidebar's space picker.
        static let spacePicker = "chevron.up.chevron.down"
        /// General in the space picker's menu: what has no other space.
        static let generalSpace = "tray"
        static let keepAwake = "cup.and.saucer.fill"
        static let permission = "hand.raised"
        static let prFeedback = "bubble.left"
        static let botFeedback = "cpu"
        static let agentError = "exclamationmark.triangle.fill"
        static let resume = "play.fill"
        static let interrupt = "stop.fill"
        /// Types waiting Mission messages on the user's word.
        static let typeNow = "keyboard"
        static let sessionHistory = "clock.arrow.circlepath"
        static let projectMemory = "brain"
        static let notice = "info.circle"
        static let locked = "lock.fill"
        static let more = "ellipsis"
        /// ⌘P's row standing for a folded section.
        static let unfold = "chevron.right"
        static let back = "chevron.left"
        static let forward = "chevron.right"
        static let reload = "arrow.clockwise"
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

extension CALayer {
    /// Rounds the layer's top or bottom corners as its card's, for a part of
    /// a column that reaches them. On a view's backing layer, AppKit turns
    /// the view's clipping on with it.
    func roundCardCorners(top: Bool) {
        cornerRadius = Theme.Radius.column
        // Its y runs down exactly when its contents are flipped, which its
        // superview can make so.
        maskedCorners = top == contentsAreFlipped()
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }
}

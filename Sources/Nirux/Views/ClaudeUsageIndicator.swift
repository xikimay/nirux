import AppKit

/// The binding plan limit at the trailing end of the main window's title
/// bar: the one that stops the agents first (`QuotaLimit.binding`), Claude's
/// from its status line (see `ClaudeUsageLimits`) or Codex's from its
/// rollouts (`UsageMonitor`). Hair meters for that agent's windows, then its
/// pace in words: "5h 68% · ≈ 87%", or in red "⚠︎ 5h full by 20:05" once it
/// runs out before its reset. The tooltip gives every window. While the
/// option is off or nothing is known it takes no room: the controller's
/// `isHidden` only works for top and bottom accessories, so the view hides
/// and shrinks to nothing itself. First of the trailing accessories, it
/// keeps the window's edge, at the right end of the toolbar
/// (`CommandBarToolbar`): the cup, which comes and goes with every turn,
/// appears to its left without moving it.
final class ClaudeUsageIndicator: NSTitlebarAccessoryViewController {
    private static let height: CGFloat = 22
    private static let padding: CGFloat = 6
    private static let metersWidth: CGFloat = 42
    private static let normalColor = NSColor.white.withAlphaComponent(0.45)

    let label = NSTextField(labelWithString: "")
    let meters = QuotaMeterView()
    /// Times read in the user's calendar; a test sets its own.
    var calendar = Calendar.current
    /// The limits shown, each with its forecast: the next update holds them.
    private(set) var limits: [QuotaLimit] = []
    private var claude: ClaudeUsageLimits?
    private var claudeReadings: [String: [QuotaReading]] = [:]
    private var codex: CodexRateLimits?
    private var codexReadings: [Int: [QuotaReading]] = [:]

    init() {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: Self.height))
        container.isHidden = true
        label.font = Theme.Font.captionDigits
        label.textColor = Self.normalColor
        label.lineBreakMode = .byClipping
        container.addSubview(meters)
        container.addSubview(label)
        view = container
    }

    func update(limits: ClaudeUsageLimits?, readings: [String: [QuotaReading]] = [:], now: TimeInterval) {
        claude = limits
        claudeReadings = readings
        render(now: now)
    }

    func update(codex limits: CodexRateLimits?, readings: [Int: [QuotaReading]] = [:], now: TimeInterval) {
        codex = limits
        codexReadings = readings
        render(now: now)
    }

    private func render(now: TimeInterval) {
        // Loading the view later would reset the label's colour set below.
        loadViewIfNeeded()
        defer { relayOutTitleBar() }
        limits = QuotaLimit.current(
            claude: claude, claudeReadings: claudeReadings, codex: codex, codexReadings: codexReadings, previous: limits, now: now
        )
        guard let binding = QuotaLimit.binding(limits) else {
            view.isHidden = true
            view.frame.size.width = 0
            view.toolTip = nil
            label.toolTip = nil
            label.stringValue = ""
            meters.limits = []
            return
        }
        let title = UsageText.title(binding, now: now, calendar: calendar)
        label.stringValue = title.text
        label.textColor = switch title.tone {
        case .normal: Self.normalColor
        case .warning: .niruxWarning
        case .runsOut: Theme.Color.error
        }
        meters.limits = limits.filter { $0.agent == binding.agent }.sorted { $0.length < $1.length }
        meters.now = now
        let tooltip = tooltip(now: now)
        view.toolTip = tooltip
        label.toolTip = tooltip
        label.setAccessibilityLabel(([title.text.replacingOccurrences(of: "⚠︎ ", with: "")] + limits.map { limit in
            "\(UsageText.name(of: limit)) \(Int(limit.latest.usedPercent.rounded()))% used, \(UsageText.pace(limit, now: now, calendar: calendar))"
        }).joined(separator: ". "))
        label.sizeToFit()
        // The title bar sets the height; only the width follows the text.
        view.frame.size.width = Self.padding + Self.metersWidth + Theme.Space.sm + label.frame.width + Self.padding
        layOut()
        view.isHidden = false
    }

    /// Each window shown, with its use and reset, then each one's pace, then
    /// when the latest reading came.
    private func tooltip(now: TimeInterval) -> String {
        let windows = limits.map { limit in
            "\(limit.agent == .claude ? "Claude " : "")\(UsageText.name(of: limit)): \(Int(limit.latest.usedPercent.rounded()))% used, "
                + ClaudeUsageLimits.resetText(limit.latest.resetsAt, now: now, calendar: calendar)
        }
        let read = limits.map(\.latest.time).max().map { "Last reading at \(ClaudeUsageLimits.clockText($0, now: now, calendar: calendar)). " } ?? ""
        return [
            (["Plan usage limits"] + windows).joined(separator: "\n"),
            (["At this pace"] + paceLines(now: now)).joined(separator: "\n"),
            read + "Use elsewhere (claude.ai, another Mac) counts from the next reading."
        ].joined(separator: "\n\n")
    }

    private func paceLines(now: TimeInterval) -> [String] {
        limits.map { "\(UsageText.name(of: $0)): \(UsageText.pace($0, now: now, calendar: calendar))" }
    }

    /// Showing a limit, as opposed to taking no room.
    var isShowing: Bool { !view.isHidden && view.frame.width > 0 }

    override func viewDidLayout() {
        super.viewDidLayout()
        layOut()
    }

    /// Level with the traffic lights and the keep-awake cup.
    private func layOut() {
        let meterHeight = QuotaMeterView.height(rows: max(1, meters.limits.count))
        meters.frame = NSRect(x: Self.padding, y: floor((view.bounds.height - meterHeight) / 2), width: Self.metersWidth, height: meterHeight)
        label.frame.origin = NSPoint(x: meters.frame.maxX + Theme.Space.sm, y: floor((view.bounds.height - label.frame.height) / 2))
    }
}

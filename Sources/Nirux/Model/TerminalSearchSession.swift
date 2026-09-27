import Foundation

/// A Ghostty binding action behind a terminal column's find bar. libghostty
/// runs the search itself — scrollback included — highlights the matches and
/// scrolls to the selected one; Nirux only sends these commands.
enum TerminalSearchCommand: Equatable {
    /// Replaces the active search. An empty needle cancels it.
    case search(String)
    /// Ghostty searches from the bottom: the next match is the one above
    /// the selected one (older output), the previous one is below.
    case next
    case previous
    /// Stops the search and clears its highlights.
    case end
    case scrollToBottom

    var bindingAction: String {
        switch self {
        // Ghostty takes everything after the first colon as the text, so a
        // needle may itself contain colons.
        case .search(let needle): "search:\(needle)"
        case .next: "navigate_search:next"
        case .previous: "navigate_search:previous"
        case .end: "end_search"
        case .scrollToBottom: "scroll_to_bottom"
        }
    }
}

/// One terminal column's search: turns what the user types into `search:`
/// commands and makes navigation act on the latest text.
///
/// Like Ghostty's own search bar, a needle shorter than three characters is
/// sent after a short pause: one or two letters match nearly every line of a
/// long scrollback, and the user is usually still typing.
@MainActor
final class TerminalSearchSession {
    typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    nonisolated static let shortNeedleLength = 3
    nonisolated static let shortNeedleDelay: TimeInterval = 0.3
    /// Ghostty collects matches on its search thread after a needle
    /// arrives: a navigation sent right behind it finds none and is lost.
    /// Navigating within this delay of a new needle waits it out.
    nonisolated static let navigationDelay: TimeInterval = 0.1

    private let send: (TerminalSearchCommand) -> Void
    private let schedule: Schedule
    /// Latest text from the field, sanitized.
    private(set) var needle = ""
    /// The needle Ghostty is searching for.
    private(set) var sentNeedle = ""
    /// Bumped by every edit and send, so a delayed send that an edit or a
    /// flush superseded does nothing.
    private var generation = 0
    /// Bumped by every needle sent and by `end`: a delayed navigation meant
    /// for an older search does nothing.
    private var searchGeneration = 0
    /// A needle went out less than `navigationDelay` ago.
    private var isNeedleSettling = false
    private var pendingNavigations = 0
    /// Navigation scrolled the viewport away from the prompt; cleared by
    /// `returnToPrompt`. Survives `end`: closing the bar keeps the reading
    /// position, as in Ghostty and iTerm.
    private(set) var hasNavigated = false

    init(
        send: @escaping (TerminalSearchCommand) -> Void,
        schedule: @escaping Schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { work() }
            }
        }
    ) {
        self.send = send
        self.schedule = schedule
    }

    /// The field's text changed. `immediately` skips the short-needle pause
    /// (reopening the bar on a kept needle).
    func update(_ text: String, immediately: Bool = false) {
        let needle = Self.sanitized(text)
        guard needle != self.needle else { return }
        self.needle = needle
        generation += 1
        if immediately || Self.delay(for: needle) == 0 {
            flush()
            return
        }
        let expected = generation
        schedule(Self.delay(for: needle)) { [weak self] in
            guard let self, self.generation == expected else { return }
            self.flush()
        }
    }

    func next() {
        navigate(.next)
    }

    func previous() {
        navigate(.previous)
    }

    /// Closes the search: drops a pending needle or navigation and clears
    /// Ghostty's highlights. The viewport stays where navigation left it;
    /// the next `update` starts a new search.
    func end() {
        generation += 1
        searchGeneration += 1
        isNeedleSettling = false
        needle = ""
        sentNeedle = ""
        send(.end)
    }

    /// About to send typed input to the PTY. After navigating, scroll back
    /// to the prompt first: Nirux writes keystrokes straight to the PTY, so
    /// Ghostty's own scroll-to-bottom on keystroke never runs and the input
    /// would land out of sight.
    func returnToPrompt() {
        guard hasNavigated else { return }
        hasNavigated = false
        send(.scrollToBottom)
    }

    /// Sends a needle still waiting out its pause first, so Return right
    /// after typing navigates the latest text.
    private func navigate(_ command: TerminalSearchCommand) {
        flush()
        guard !sentNeedle.isEmpty else { return }
        hasNavigated = true
        // Queued behind a navigation still waiting, to keep their order.
        guard isNeedleSettling || pendingNavigations > 0 else {
            send(command)
            return
        }
        pendingNavigations += 1
        let expected = searchGeneration
        schedule(Self.navigationDelay) { [weak self] in
            guard let self else { return }
            self.pendingNavigations -= 1
            guard self.searchGeneration == expected else { return }
            self.send(command)
        }
    }

    private func flush() {
        generation += 1
        guard needle != sentNeedle else { return }
        sentNeedle = needle
        searchGeneration += 1
        send(.search(needle))
        isNeedleSettling = true
        let expected = searchGeneration
        schedule(Self.navigationDelay) { [weak self] in
            guard let self, self.searchGeneration == expected else { return }
            self.isNeedleSettling = false
        }
    }

    nonisolated static func delay(for needle: String) -> TimeInterval {
        needle.isEmpty || needle.count >= shortNeedleLength ? 0 : shortNeedleDelay
    }

    /// Normalizes typed or pasted text. Control characters at either end
    /// are dropped — Ghostty trims each row, so a copied line's trailing
    /// newline would never match. Inside, line breaks become "\n", matched
    /// against the terminal's hard line breaks, and other control
    /// characters (tabs, escapes), which terminal cells never hold, become
    /// spaces. Format characters (the zero-width joiner in emoji) are kept.
    nonisolated static func sanitized(_ text: String) -> String {
        let scalars = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .unicodeScalars
        let isControl = { (scalar: Unicode.Scalar) in scalar.properties.generalCategory == .control }
        guard let first = scalars.firstIndex(where: { !isControl($0) }),
              let last = scalars.lastIndex(where: { !isControl($0) })
        else { return "" }
        var result = String.UnicodeScalarView()
        for scalar in scalars[first...last] {
            result.append(isControl(scalar) && scalar != "\n" ? " " : scalar)
        }
        return String(result)
    }
}

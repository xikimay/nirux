import Foundation

/// What a Claude turn's final message asks of the user. Claude reports
/// only that its turn ended (Stop); agents often end on a question written
/// in prose ("3 PRs ready, shall I merge?"), which looks the same. A
/// classifier reads the message so that only a turn that asks something
/// alerts (notification, Dock bounce and badge); a done turn stays quiet.
enum TurnEndVerdict: Equatable, Sendable {
    /// The message hands something back to the user: a question, a choice,
    /// an action only they can do, an offer waiting for a yes. With the
    /// sentence that asks when the classifier quoted one found in the
    /// message.
    case asks(TurnEndQuestion?)
    /// It reports or answers, and asks nothing.
    case done
    /// No answer (the classifier failed, refused, or can't run here): the
    /// turn alerts as every turn end did before, since a missed question
    /// costs more than an extra notification.
    case unknown
}

/// The sentence of a final message that asks the user, word for word
/// (`TurnEndText.quotes`), and whether a plain yes or no answers it.
struct TurnEndQuestion: Equatable, Sendable {
    let text: String
    let isYesNo: Bool
}

/// A Claude turn end waiting for its verdict. `turnEndedAt` (the Stop's
/// timestamp) tells it from a later turn end of the same column.
struct TurnEndRequest: Equatable, Sendable {
    /// `TurnEndText.excerpt` of the final assistant message.
    let message: String
    let turnEndedAt: TimeInterval
}

/// Reads a turn's final message. The seam for other classifiers (Apple's
/// on-device model); see `ClaudeTurnEndClassifier` for the one in use.
protocol TurnEndClassifier: Sendable {
    /// Never throws: any failure is `.unknown`. May take seconds; the
    /// caller doesn't wait on the main thread.
    func classify(_ message: String) async -> TurnEndVerdict
}

/// The final message's text as the classifier and the alert use it.
enum TurnEndText {
    /// The agent's environment (the hook's, which it inherits) sends Claude
    /// Code elsewhere than the login Nirux's own `claude -p` uses: one of
    /// the variables that run drops (`ClaudeCLI.accountVariables`: a cloud
    /// provider, an API key, a gateway, a token). Its messages are not sent
    /// to that login: its turn ends alert as before. The configuration
    /// folder, which the run keeps, is compared instead (`TurnEndMarker`).
    static func usesOtherAccount(_ environment: [String: String]) -> Bool {
        BranchReview.ClaudeCLI.accountVariables.contains { environment[$0].map { !$0.isEmpty && $0 != "0" } ?? false }
    }

    /// The agent whose hook runs with `environment` uses the login Nirux's
    /// own `claude -p` does: no account variable in its environment, the
    /// configuration folder of a running Nirux, no settings file that
    /// chooses another account. What decides both that its final message
    /// may be read (`AgentHookEvent.finalMessage`) and that a model may
    /// read its pull request's CI failure (`AgentHookEvent.onNiruxAccount`):
    /// one rule, so that the two can't drift.
    static func agentOnNiruxAccount(
        environment: [String: String], cwd: String?, home: String,
        markers directory: URL = TurnEndMarker.directory,
        running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:),
        read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) -> Bool {
        !usesOtherAccount(environment)
            && TurnEndMarker.sharesConfigDirectory(environment: environment, in: directory, running: running)
            && !settingsUseOtherAccount(environment: environment, cwd: cwd, home: home, read: read)
    }

    /// Two environments run Claude Code on the same configuration folder,
    /// as `ProjectMemory.configDirectory` reads `CLAUDE_CONFIG_DIR`.
    static func sameConfigDirectory(_ first: String?, _ second: String?, home: String) -> Bool {
        func folder(_ value: String?) -> String {
            var path = ProjectMemory.configDirectory(home: home, environment: value.map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:])
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        return folder(first) == folder(second)
    }

    /// Settings files that send Claude Code to another account than its
    /// login, though no variable says so in the hook's environment: an
    /// `apiKeyHelper` (or a cloud provider's credential helper), or account
    /// variables in an `env` block. Read: the user's settings, the
    /// project's (`CLAUDE_PROJECT_DIR`, else the agent's folder) shared and
    /// local ones, the local ones of its git checkout (a worktree's main
    /// checkout: Claude Code reads them there), the managed ones. Nirux's
    /// `claude -p` reads none of them (`--restricted`). Not covered:
    /// settings passed with `--settings`.
    static func settingsUseOtherAccount(
        environment: [String: String], cwd: String?, home: String,
        read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) -> Bool {
        let project = environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? cwd
        var paths = [
            (ProjectMemory.configDirectory(home: home, environment: environment) as NSString).appendingPathComponent("settings.json"),
            "/Library/Application Support/ClaudeCode/managed-settings.json"
        ]
        func claudeFolder(_ root: String) -> NSString {
            (root as NSString).appendingPathComponent(".claude") as NSString
        }
        if let project {
            paths += ["settings.json", "settings.local.json"].map { claudeFolder(project).appendingPathComponent($0) }
            if let checkout = checkoutRoot(from: project, read: read) {
                paths.append(claudeFolder(checkout).appendingPathComponent("settings.local.json"))
            }
        }
        return paths.contains { path in
            guard let data = read(path),
                  let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return false }
            let helpers = ["apiKeyHelper", "awsCredentialExport", "awsAuthRefresh", "gcpAuthRefresh"]
            if helpers.contains(where: { (settings[$0] as? String).map { !$0.isEmpty } ?? false }) { return true }
            // Claude Code takes numbers and booleans there as strings.
            let env = (settings["env"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
            return usesOtherAccount(env)
        }
    }

    /// The main checkout of the git repository `folder` is in, with file
    /// reads only (no `git`): the folder holding a `.git` folder, or for a
    /// worktree's `.git` file, its `gitdir`'s `commondir` parent.
    static func checkoutRoot(from folder: String, read: (String) -> Data?) -> String? {
        var current = (folder as NSString).standardizingPath
        for _ in 0..<32 {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            if let file = read(dotGit).flatMap({ String(data: $0, encoding: .utf8) }),
               let gitDir = file.split(whereSeparator: \.isNewline).first
                   .flatMap({ $0.hasPrefix("gitdir:") ? String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil }) {
                let absoluteGitDir = gitDir.hasPrefix("/") ? gitDir : (current as NSString).appendingPathComponent(gitDir)
                let common = read((absoluteGitDir as NSString).appendingPathComponent("commondir"))
                    .flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .map { $0.hasPrefix("/") ? $0 : (absoluteGitDir as NSString).appendingPathComponent($0) }
                    ?? absoluteGitDir
                return ((common as NSString).standardizingPath as NSString).deletingLastPathComponent
            }
            if read((dotGit as NSString).appendingPathComponent("HEAD")) != nil { return current }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }
            current = parent
        }
        return nil
    }

    /// The start and the end of `message`, the part a classifier reads:
    /// the whole message up to `limit` Unicode scalars (at most 4 bytes
    /// each: the hook's event line stays a few kilobytes), else its first
    /// `headLength` and its last scalars around a "[…]" line (a question
    /// usually ends the message; its start says what the turn was about).
    /// Nil for a message without visible text.
    static func excerpt(_ message: String, limit: Int = 3_000, headLength: Int = 600) -> String? {
        let scalars = message.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        guard !scalars.isEmpty else { return nil }
        guard scalars.count > limit else { return String(scalars) }
        let head = String(String.UnicodeScalarView(scalars.prefix(headLength)))
        let tail = String(String.UnicodeScalarView(scalars.suffix(max(0, limit - headLength))))
        return head + "\n[…]\n" + tail
    }

    /// `quote` is a whole sentence of `message`'s prose, give or take
    /// whitespace, Markdown marks and the quotation marks around it: the
    /// classifier quoted it, not reworded it, cut it short, or took it from
    /// code or a quoted text. A Yes button sits next to that text.
    static func quotes(_ quote: String, in message: String) -> Bool {
        let needle = normalizedForQuote(quote.trimmingCharacters(in: quotationMarks))
        let prose = proseLines(of: message).map { normalizedForQuote(String($0)) }.joined(separator: "\n")
        var start = prose.startIndex
        while let found = prose.range(of: needle, range: start..<prose.endIndex) {
            if startsSentence(at: found.lowerBound, in: prose), endsSentence(needle, at: found.upperBound, in: prose) {
                return true
            }
            start = prose.index(after: found.lowerBound)
        }
        return false
    }

    /// Around a quote: the model's, not the message's.
    static let quotationMarks = CharacterSet(charactersIn: "\"“”«» ")

    /// Markdown marks out, typographic quotes and apostrophes plain, the
    /// spaces of a line made single.
    private static func normalizedForQuote(_ text: String) -> String {
        let unmarked = String(text.unicodeScalars.filter { !"*_`>#".unicodeScalars.contains($0) }.map(Character.init))
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        return unmarked.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The message's lines outside fenced code and quoted text (`>`):
    /// fences counted from the end, as `questionLine` does.
    private static func proseLines(of message: String) -> [Substring] {
        var inFence = false
        var lines: [Substring] = []
        for line in message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence, !trimmed.hasPrefix(">") { lines.append(line) }
        }
        return lines.reversed()
    }

    /// Nothing of its sentence before it: the start of a line, or no
    /// letter or digit right before ("Done. Want…", "- Want…", "…, shall I…").
    private static func startsSentence(at index: String.Index, in text: String) -> Bool {
        guard let previous = text[..<index].last(where: { $0 != " " }) else { return true }
        return previous == "\n" || !(previous.isLetter || previous.isNumber)
    }

    /// Nothing of its sentence after it: it ends on a sentence mark (past
    /// closing quotes and brackets), or the line ends or one comes next.
    private static func endsSentence(_ needle: String, at index: String.Index, in text: String) -> Bool {
        let sentenceMarks: Set<Character> = [".", "?", "!", "…", ":", "？", "؟"]
        if let last = needle.last(where: { !")]}»\"'".contains($0) }), sentenceMarks.contains(last) { return true }
        guard index < text.endIndex else { return true }
        return text[index] == "\n" || sentenceMarks.contains(text[index])
    }

    /// The message ends on a question: its last paragraph of prose (not
    /// code, a quote, a table, a heading or a rule) holds a line ending
    /// with a question mark, past trailing quotes, brackets, markdown and
    /// emoji. Such a turn asks for sure, model or not: Haiku and Sonnet
    /// both now and then read a short one as done ("Ça te va ?", "Tu peux
    /// vérifier le VPN ?"). A rhetorical one costs an extra alert, the
    /// right side to err on.
    static func endsOnQuestion(_ message: String) -> Bool {
        questionLine(of: message) != nil
    }

    /// The line `endsOnQuestion` found, cleaned for one line of a
    /// notification (the last such line of that paragraph).
    static func questionLine(of message: String, maxLength: Int = 200) -> String? {
        var inFence = false
        var inParagraph = false
        for line in message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Counted from the end: an excerpt may have lost a block's start.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if inParagraph { return nil }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if isProse(trimmed) {
                inParagraph = true
                if endsWithQuestionMark(trimmed) { return AgentText.clean(trimmed, maxLength: maxLength) }
            } else if inParagraph {
                return nil
            }
        }
        return nil
    }

    /// Not blank, a quote, a table row, a Markdown heading (`#` to `######`
    /// and a space: "#298 is green" is prose) or a rule (`---`, `***`).
    private static func isProse(_ line: String) -> Bool {
        guard !line.isEmpty, !line.hasPrefix(">"), !line.hasPrefix("|") else { return false }
        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " || line.count == hashes { return false }
        if line.count >= 3, let first = line.first, "-*_".contains(first), line.allSatisfy({ $0 == first || $0 == " " }) {
            return false
        }
        return true
    }

    private static func endsWithQuestionMark(_ line: String) -> Bool {
        var scalars = Array(line.unicodeScalars)
        while let last = scalars.last, !isQuestionMark(last), isTrailingDecoration(last) { scalars.removeLast() }
        return scalars.last.map(isQuestionMark) ?? false
    }

    /// "?", fullwidth "？", Arabic "؟", "‽", "⁉", and the question mark
    /// emoji.
    private static func isQuestionMark(_ scalar: Unicode.Scalar) -> Bool {
        ["?", "\u{FF1F}", "\u{061F}", "\u{203D}", "\u{2049}", "\u{2753}", "\u{2754}"].contains(scalar)
    }

    /// Whitespace, "!", closing quotes and brackets (Western, German, CJK),
    /// Markdown emphasis, emoji and their joiners and variation selectors
    /// (not the ASCII digits, `#` and `*` Unicode also counts as emoji). A
    /// backtick isn't: a "?" inside inline code asks nothing.
    private static func isTrailingDecoration(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace || "!\"'»”’“‘)]}>*_~」』）】〉》".unicodeScalars.contains(scalar) { return true }
        if [0xFE0F, 0xFE0E, 0x200D, 0x20E3].contains(scalar.value) || (0xE0020...0xE007F).contains(scalar.value) { return true }
        return scalar.value > 0x7F && scalar.properties.isEmoji
    }

    /// The message's last line of prose, cleaned for one line of a
    /// notification: what a turn that asks most likely asks. Lines inside
    /// fenced code are skipped, counting fences from the end: an excerpt
    /// may have lost the start of a block, never its end.
    static func lastLine(of message: String, maxLength: Int = 200) -> String? {
        var inFence = false
        for line in message.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !inFence, let cleaned = AgentText.clean(String(line), maxLength: maxLength) { return cleaned }
        }
        return nil
    }
}

/// Tells hook receivers that a running Nirux has a use for what they
/// know of the agent's account (the turn-end option or the CI failure
/// triage is on), with which Claude configuration folder its `claude -p`
/// runs, and whether it reads final messages: one file per Nirux process,
/// so that two on one state directory (a debug build next to the app)
/// don't undo each other. Without a marker naming a Nirux still running
/// that reads them, or for an agent with another folder, receivers leave
/// the message out of the event queue: nothing would read it, and Stop
/// lines would grow for nothing.
struct TurnEndMarker: Codable, Equatable {
    let app: ProcessInstance
    /// Nirux's own `CLAUDE_CONFIG_DIR` (nil: the default), which its
    /// `claude -p` keeps (`ClaudeCLI.keptVariables`).
    let claudeConfigDir: String?
    /// False when only the CI failure triage is on. Nil in the markers of
    /// builds that wrote one for the turn-end option alone: true.
    var readsFinalMessages: Bool?

    static var directory: URL { Persistence.stateDirectory.appendingPathComponent("turn-end-readers", isDirectory: true) }

    private static func url(for app: ProcessInstance, in directory: URL) -> URL {
        directory.appendingPathComponent("\(app.pid)-\(Int(app.startedAt)).json")
    }

    /// An option that needs it is on in `app`. Markers of Nirux processes
    /// gone (a crash) go too.
    static func publish(app: ProcessInstance, environment: [String: String], readsFinalMessages: Bool = true,
                        in directory: URL = directory,
                        running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:)) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        for (url, marker) in markers(in: directory) where running(marker.app.pid) != marker.app {
            try? FileManager.default.removeItem(at: url)
        }
        let marker = TurnEndMarker(
            app: app, claudeConfigDir: environment["CLAUDE_CONFIG_DIR"], readsFinalMessages: readsFinalMessages
        )
        try? JSONEncoder().encode(marker).write(to: url(for: app, in: directory), options: .atomic)
    }

    /// Both options are off in `app`, or `app` quits.
    static func withdraw(app: ProcessInstance?, in directory: URL = directory) {
        guard let app else { return }
        try? FileManager.default.removeItem(at: url(for: app, in: directory))
    }

    /// Whether a receiver keeps the final message of an agent running with
    /// `environment` (the hook's): a running Nirux reads it, on the same
    /// configuration folder.
    static func allowsMessage(environment: [String: String], in directory: URL = directory,
                              running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:)) -> Bool {
        shares(environment: environment, in: directory, running: running) { $0.readsFinalMessages != false }
    }

    /// Whether an agent running with `environment` uses the configuration
    /// folder of a running Nirux that published a marker.
    static func sharesConfigDirectory(environment: [String: String], in directory: URL = directory,
                                      running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:)) -> Bool {
        shares(environment: environment, in: directory, running: running) { _ in true }
    }

    private static func shares(environment: [String: String], in directory: URL, running: (pid_t) -> ProcessInstance?,
                               where counts: (TurnEndMarker) -> Bool) -> Bool {
        let home = environment["HOME"] ?? NSHomeDirectory()
        return markers(in: directory).contains { _, marker in
            counts(marker) && running(marker.app.pid) == marker.app
                && TurnEndText.sameConfigDirectory(environment["CLAUDE_CONFIG_DIR"], marker.claudeConfigDir, home: home)
        }
    }

    private static func markers(in directory: URL) -> [(URL, TurnEndMarker)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TurnEndMarker.self, from: $0) }.map { (url, $0) }
        }
    }
}

import Foundation

/// A quiet hint that a working Claude may be going in circles: its
/// commands keep hanging, or one keeps failing. Grey on the task's row, in
/// place of "Working": it only tells the user, and never interrupts the
/// agent, alerts, or turns amber (amber means the agent waits on them).
///
/// Local only, by measurement on 30 days of sessions (190 active hours):
/// nobody retried one failing command more than 3 times in a row, and the
/// one agent that was stuck (27 minutes) had its commands run past their
/// time limit 7 times in one turn, which happened in no other turn more
/// than 3 times. Counting edits of a file, a long turn or time without a
/// commit fired 14 to 42 times a month, always wrongly, and a model
/// reading the same calls found nothing more: neither is used.
enum AgentCirclingHint: Hashable, Sendable {
    /// `count` commands of the turn ran past their time limit.
    case hung(count: Int)
    /// One command failed `count` times in a row: `name` is a shell
    /// command's program ("swift build") or a tool ("Edit"), nil for a
    /// command nothing names.
    case failing(name: String?, count: Int)

    /// The row's status line, short enough for the reason to show in a
    /// sidebar 260 points wide, in a sub-task's narrower row too ("May be
    /// stuck · swift build failed 5 times" lost its end there).
    /// "Timeouts", not "hung": all Nirux knows is that they ran past their
    /// time limit.
    var statusText: String {
        switch self {
        case .hung(let count):
            return "Stuck? · \(count) timeouts"
        case .failing(let name, let count):
            return "Stuck? · \(Self.display(name)) failed \(count)×"
        }
    }

    /// What the line can't hold, for its tooltip.
    var detail: String {
        let reason: String
        switch self {
        case .hung(let count):
            reason = "\(count) commands of this turn ran past their time limit, close together."
        case .failing(let name, let count):
            reason = "In this turn, \(Self.display(name)) failed \(count) times in a row."
        }
        return reason + " The agent goes on: Nirux only tells you."
    }

    /// An MCP tool by its own name, without its server's.
    private static func display(_ name: String?) -> String {
        guard let name else { return "a command" }
        return name.hasPrefix("mcp__") ? name.components(separatedBy: "__").last ?? name : name
    }
}

/// Follows the main agent's tool calls through one turn, for
/// `AgentCirclingHint`. A value inside `AgentStatusMachine`, which feeds
/// it and resets it when the turn starts or ends.
struct AgentCirclingWatch: Equatable, Sendable {
    /// Commands past their time limit in one turn. Measured: 3 fires twice
    /// a month, one of them the real case, nine minutes earlier than 4.
    static let hungThreshold = 3
    /// Failures in a row of one command. Measured: never more than 3.
    static let failureThreshold = 5
    /// Calls that end without a command hanging again: the agent got past
    /// them, and later ones count from zero. Three slow builds spread over
    /// a long turn aren't a stuck agent; the one measured had 2 to 4 calls
    /// between hung commands.
    static let callsThatClearHangs = 10
    /// Calls after which a row of failures no longer shows: the agent
    /// moved on. Its count stays, since a loop may take many calls (reads,
    /// edits) between two tries, until that command passes, the turn ends,
    /// or `callsThatEndFailures` other calls ended: a check that answers
    /// "no" by failing (`pgrep`, `lsof`), run now and then through a long
    /// turn, isn't a row.
    static let callsThatHideFailures = 15
    static let callsThatEndFailures = 60
    /// Commands followed at once; the one that failed longest ago goes.
    static let maxStreaks = 32

    private struct Streak: Equatable, Sendable {
        let key: String
        let name: String?
        var count: Int
        var lastAt: TimeInterval
        var callsSince = 0
    }

    private var hungCount = 0
    private var lastHungAt: TimeInterval = 0
    private var callsSinceHang = 0
    private var streaks: [Streak] = []

    /// A tool call of the main agent ended: `end` nil, it ran. `key` tells
    /// what ran from the rest (a shell command's program, a tool; nil: no
    /// telling), `name` says it to people.
    mutating func noteCallEnded(key: String?, name: String?, end: AgentToolEnd?, at time: TimeInterval) {
        switch end {
        case .interrupted?, .waited?:
            // The user's doing, or waiting for something: it says nothing
            // of an agent going in circles, either way.
            return
        case .hung?:
            // Neither a failure nor a success of its command.
            hungCount += 1
            lastHungAt = time
            callsSinceHang = 0
            return
        case .failed?, nil:
            break
        }
        if hungCount > 0 {
            callsSinceHang += 1
            if callsSinceHang >= Self.callsThatClearHangs { hungCount = 0 }
        }
        for index in streaks.indices where streaks[index].key != key { streaks[index].callsSince += 1 }
        streaks.removeAll { $0.callsSince >= Self.callsThatEndFailures }
        guard let key else { return }
        let index = streaks.firstIndex { $0.key == key }
        guard end == .failed else {
            if let index { streaks.remove(at: index) }
            return
        }
        if let index {
            streaks[index].count += 1
            streaks[index].lastAt = time
            streaks[index].callsSince = 0
        } else {
            if streaks.count >= Self.maxStreaks, let oldest = streaks.indices.min(by: { streaks[$0].lastAt < streaks[$1].lastAt }) {
                streaks.remove(at: oldest)
            }
            streaks.append(Streak(key: key, name: name, count: 1, lastAt: time))
        }
    }

    /// The turn started or ended, or the conversation changed.
    mutating func reset() {
        self = AgentCirclingWatch()
    }

    /// What to say, if anything: of commands hanging and one failing, the
    /// one that happened last.
    var hint: AgentCirclingHint? {
        let failing = streaks.filter { $0.count >= Self.failureThreshold && $0.callsSince < Self.callsThatHideFailures }
            .max { $0.lastAt < $1.lastAt }
        let hung = hungCount >= Self.hungThreshold
        if let failing, !hung || failing.lastAt > lastHungAt {
            return .failing(name: failing.name, count: failing.count)
        }
        return hung ? .hung(count: hungCount) : nil
    }
}

/// How a tool call ended when it didn't simply run. Raw values travel in
/// the hook event queue (`AgentHookEvent.toolEnd`).
enum AgentToolEnd: String, Sendable {
    /// It failed by itself.
    case failed
    /// A shell command ran past its time limit.
    case hung
    /// The user interrupted it (Esc), or something stopped it.
    case interrupted
    /// A command that waits (`AgentShellCommand.isWait`) came back with a
    /// failure, or outlasted its time limit: neither.
    case waited
}

/// What the end of a tool call tells `AgentCirclingWatch`, read by the hook
/// receiver from Claude's PostToolUse and PostToolUseFailure payloads. Only
/// how it ended and a program's name leave the receiver: never the command,
/// its output or the error.
enum AgentToolOutcome {
    /// Bookkeeping of background commands and tasks (a poll for output, a
    /// stop): it says nothing of an agent going round, and it isn't a call
    /// that moves on either. TaskOutput and BashOutput came back as
    /// successes even when their wait timed out (Claude Code 2.1.1xx; gone
    /// in 2.1.321).
    static let taskTools: Set<String> = [
        "TaskOutput", "BashOutput", "BashOutputTool", "AgentOutput", "AgentOutputTool", "TaskStop", "KillShell", "KillBash",
        "Monitor"
    ]

    /// Nil: the call ran, or answered "no". `command`: a shell tool's, nil
    /// for other tools.
    ///
    /// A shell command past its time limit is hung. An interactive Claude
    /// moves it to the background and goes on; a headless one kills it and
    /// reports a failure. A command that Esc or a stop killed comes back as
    /// a result marked `interrupted` (exit 137), never a timeout's. Read
    /// from Claude Code 2.1.321 and a month of results (2.1.111 to 2.1.321).
    static func end(hookName: String, payload: [String: Any], command: AgentShellCommand?) -> AgentToolEnd? {
        let failure = hookName == "PostToolUseFailure"
        let response = payload["tool_response"] as? [String: Any]
        if failure && payload["is_interrupt"] as? Bool == true { return .interrupted }
        guard let command else { return failure ? .failed : nil }
        let pastItsLimit = failure ? wasKilledAtItsLimit(payload) : wasMovedToTheBackground(payload)
        // A `sleep 600` outlasting its limit is meant to (12 of the month's
        // 43), and a poll that finds nothing yet isn't a try.
        if command.isWait { return failure || pastItsLimit ? .waited : nil }
        if pastItsLimit { return .hung }
        guard failure else { return nil }
        switch exitCode(payload) {
        // grep found nothing, files differ, a test is false: an answer.
        // Claude Code says so itself for a bare grep, not after `&&`, nor
        // for test, which or cmp.
        // `gh pr checks`: checks still running.
        default: return .failed
        }
    }

    /// `backgroundTaskId` in a result nobody asked to run in the
    /// background: not the agent with `run_in_background`, and not for a
    /// reason Claude gives (`backgroundedByUser`,
    /// `backgroundedToDeliverMessage`, `backgroundedByTurnAbort`,
    /// `assistantAutoBackgrounded`, or one a later version adds).
    private static func wasMovedToTheBackground(_ payload: [String: Any]) -> Bool {
        guard let response = payload["tool_response"] as? [String: Any],
              let task = response["backgroundTaskId"] as? String, !task.isEmpty,
              (payload["tool_input"] as? [String: Any])?["run_in_background"] as? Bool != true
        else { return false }
        return !response.contains { $0.key.lowercased().contains("backgrounded") && $0.value as? Bool == true }
    }

    /// "Exit code 143", then "Command timed out after 2s": Claude's own
    /// first lines of the error, before the command's output (which may
    /// hold the same words: a test log, a grep of this file).
    private static func wasKilledAtItsLimit(_ payload: [String: Any]) -> Bool {
        if payload["is_timeout"] as? Bool == true { return true }
        let lines = errorStart(payload)
        let notice = "Command timed out after"
        guard let first = lines.first else { return false }
        return first.hasPrefix(notice) || first.hasPrefix("Exit code ") && lines.dropFirst().first?.hasPrefix(notice) == true
    }

    /// "Exit code 1", Claude's first line of a failed command's error.
    private static func exitCode(_ payload: [String: Any]) -> Int? {
        guard let first = errorStart(payload).first, first.hasPrefix("Exit code ") else { return nil }
        return Int(first.dropFirst("Exit code ".count).prefix { $0.isNumber })
    }

    /// The error's first lines, cut in scalars.
    private static func errorStart(_ payload: [String: Any]) -> [Substring] {
        guard let error = payload["error"] as? String else { return [] }
        let start = String(String.UnicodeScalarView(error.unicodeScalars.prefix(200)))
        return start.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
    }
}

/// What a shell command is, as far as its text says: the program it runs
/// and whether it waits. A label for people and a key to count by, not a
/// shell parser: quotes, `$(…)` and comments are followed only to find
/// where commands and words end, in the first 2,000 characters.
struct AgentShellCommand: Equatable, Sendable {
    /// "swift build", "gh pr checks", "python3": the program, with its
    /// subcommand for the tools that have one, past `cd … &&`, variables,
    /// wrappers and preparations. Nil when nothing names the command (a
    /// loop, a path held in a variable, `[ -f x ]`).
    let family: String?
    /// The command counts with its exact repeats only, not with the other
    /// runs of its program: nothing names it, or its program runs
    /// whatever it is given (`python3 a.py` and `python3 b.py` are two
    /// commands; `swift build` is one).
    var countsByText: Bool { family == nil }
    /// What tells a command from another by its text alone, so a
    /// description or a time limit that changes between two tries doesn't
    /// make it another command.
    var repeatKey: String { AgentToolInput.shortHash(Data(text.utf8)) }
    private let text: String

    /// The command is nothing but waiting: it only sleeps (`sleep 300`), it
    /// is a loop that sleeps (`until curl -sf :3000; do sleep 2; done`), it
    /// is one of GitHub's commands that exit non-zero while checks run, or
    /// Nirux's own Mission command, which says "run me again" with a
    /// failure while the other agent is busy. Coming back with a failure,
    /// or running past its time limit, is then part of waiting (for CI, a
    /// server, an agent). A wait followed by a program (`sleep 5; swift
    /// build`, `git push && gh pr checks --watch`) counts as that program.
    let isWait: Bool
    /// The command waits at some point, before anything else or as a
    /// watch: running past its time limit is then the wait's doing, not a
    /// command hanging. A sleep after a program, or after clearing its way
    /// (`pkill -f app; sleep 1; swift run`), doesn't make it one.
    let mayRunLong: Bool
    /// Exit 1 of the command's last program is its answer, not a failure:
    /// grep found nothing, files differ, a test is false, `which` found
    /// nothing. Not when a program before it in an `&&` chain may have
    /// failed instead (`swift build && grep -q ok log`).
    let exitOneAnswers: Bool
    /// The command runs `gh pr checks`, whose exit 8 means "still running".
    let runsChecks: Bool

    init(_ text: String) {
        self.text = text
        var family: String?
        var isNamed = false
        var preparation: String?
        var hasCleared = false
        var leadingSleep = false
        var sleeps = false
        var waitParts = 0
        var otherParts = 0
        var runsChecks = false
        // A loop or an `if`, from its keyword to its `done`, `fi`, `esac`.
        var depth = 0
        var compoundWaits = false
        // For the exit code: whether a program that may fail came earlier
        // in the current `&&` chain, and what the last program says.
        var chainHasProgram = false
        var pipelineGated = false
        var lastAnswers = false
        for (words, separator) in Self.simpleCommands(in: text) {
            switch separator {
            case .sequence: (chainHasProgram, pipelineGated) = (false, false)
            case .and: pipelineGated = chainHasProgram
            case .pipe: break
            }
            guard let (name, arguments) = Self.program(in: words) else { continue }
            let named = ([name] + Self.subcommands(of: name, in: arguments)).joined(separator: " ")
            let waits = name == "sleep" || Self.waitingCommands.contains(named) || arguments.contains("--mission")
            if depth > 0 {
                if Self.compoundOpeners.contains(name) { depth += 1 }
                compoundWaits = compoundWaits || waits
                if depth == 0 {
                    // A loop that sleeps is a poll; any other one runs things.
                    if compoundWaits { waitParts += 1 } else { otherParts += 1 }
                    lastAnswers = false
                    chainHasProgram = true
                }
                continue
            }
            // `cd` hardly fails; `pkill` answers "none" with exit 1.
            let mayFail = !Self.housekeeping.contains(name) || Self.clearsTheWay.contains(name)
            defer { if mayFail { chainHasProgram = true } }
            lastAnswers = (Self.answeringPrograms.contains(name) || Self.answeringPrograms.contains(named))
            if Self.waitingCommands.contains(named) || arguments.contains("--mission") {
                waitParts += 1
                runsChecks = runsChecks || named == "gh pr checks"
                if !isNamed { (isNamed, family) = (true, Self.isProgramName(name) ? named : nil) }
                continue
            }
            if name == "sleep" {
                sleeps = true
                if !isNamed && !hasCleared { leadingSleep = true }
            }
            if Self.clearsTheWay.contains(name) { hasCleared = true }
            if Self.housekeeping.contains(name) {
                if !isNamed { preparation = preparation ?? name }
                continue
            }
            if Self.compoundOpeners.contains(name) {
                (depth, compoundWaits) = (1, false)
                if !isNamed { isNamed = true }
                continue
            }
            otherParts += 1
            guard !Self.compound.contains(name), Self.isProgramName(name) else {
                // A path held in a variable: nothing names it.
                if !isNamed { isNamed = true }
                continue
            }
            if Self.preparations.contains(named) {
                if !isNamed { preparation = preparation ?? named }
            } else if !isNamed {
                (isNamed, family) = (true, named)
            }
        }
        // A loop the scan cut before its end.
        if depth > 0 { if compoundWaits { waitParts += 1 } else { otherParts += 1 } }
        // `[`, `.`: no name a person reads.
        self.family = (isNamed ? family : preparation).flatMap { $0 }
        isWait = sleeps || waitParts > 0
        mayRunLong = leadingSleep || waitParts > 0
        exitOneAnswers = lastAnswers
        self.runsChecks = runsChecks
    }

    /// Programs whose first plain argument says what they do.
    private static let programsWithSubcommands: Set<String> = [
        "git", "gh", "swift", "npm", "pnpm", "yarn", "bun", "npx", "cargo", "go", "make", "docker", "kubectl", "brew",
        "xcrun", "uv", "pip", "pip3"
    ]
    /// Those that take two (`gh pr checks`, `xcrun simctl list`), and the
    /// subcommands that run something else (`npm run build`, `docker
    /// compose up`): `npm run test` and `npm run lint` aren't one command.
    private static let programsWithTwoSubcommands: Set<String> = ["gh", "xcrun"]
    private static let subcommandsWithAnother: Set<String> = ["run", "compose"]
    /// Their options that take the next argument as a value, and those
    /// known to take none. After any other option the next word may be
    /// its value (a token, a user name): nothing more is read.
    private static let optionsWithValue: Set<String> = [
        "-C", "-c", "-f", "-R", "-n", "-H", "--repo", "--git-dir", "--work-tree", "--prefix", "--cwd", "--filter",
        "--manifest-path", "--context", "--namespace", "--kubeconfig", "--directory", "--project", "--package-path"
    ]
    private static let optionsWithoutValue: Set<String> = [
        "--no-pager", "--paginate", "--bare", "--silent", "--quiet", "--verbose", "--debug", "--offline", "--yes",
        "--no-color", "-q", "-s", "-v", "-y", "-D"
    ]
    /// What runs a command rather than being one.
    private static let wrappers: Set<String> = ["time", "sudo", "env", "nohup", "command", "exec", "nice", "caffeinate", "timeout", "gtimeout"]
    private static let wrapperOptionsWithValue: Set<String> = ["-u", "-k", "-s", "-n", "-g", "-C"]
    /// The shell's own housekeeping and what clears the way: the command
    /// that follows is the one to name. Alone, they name themselves.
    private static let housekeeping: Set<String> = clearsTheWay.union([
        "cd", "pushd", "popd", "export", "set", "unset", "source", ".", "echo", "printf", "mkdir", "true", ":", "sleep",
        "wait", "test", "[", "[[", "umask", "ulimit", "trap", "local", "declare", "exit", "return", "break", "continue"
    ])
    private static let clearsTheWay: Set<String> = ["rm", "touch", "chmod", "kill", "pkill", "killall"]
    /// The same for a program's subcommand: `git add -A && git commit`.
    private static let preparations: Set<String> = ["git add"]
    private static let compound: Set<String> = ["for", "while", "until", "if", "case", "select", "function"]
    private static let compoundOpeners: Set<String> = ["for", "while", "until", "if", "case", "select"]
    private static let compoundClosers: Set<String> = ["done", "fi", "esac"]
    /// Programs whose exit 1 is an answer: grep found nothing, files
    /// differ, a test is false, nothing found.
    private static let answeringPrograms: Set<String> = [
        "grep", "egrep", "fgrep", "rg", "git grep", "diff", "cmp", "git diff", "test", "[", "[[", "which", "pgrep", "lsof"
    ]
    /// Programs that run whatever they are given: their runs count by
    /// their exact text (`countsByText`).
    private static let genericRunners: Set<String> = [
        "python", "python3", "node", "bash", "sh", "zsh", "ruby", "perl", "php", "deno", "osascript", "swift", "curl",
        "wget", "npx", "bunx", "uv run", "bun run", "go run"
    ]
    /// GitHub's commands that exit non-zero while checks run, and once
    /// they failed: repeated on purpose.
    private static let waitingCommands: Set<String> = ["gh pr checks", "gh run watch"]
    /// Quotes, and where a subshell or a group opens and closes.
    private static let punctuation = CharacterSet(charactersIn: "\"'`(){}")

    /// The program a simple command runs and its arguments, past what
    /// comes before it: `!`, `{`, variables, wrappers with their own
    /// options, the shell's `do` and `then`. Nil for what a redirection
    /// left behind (`> log`, the `1` of `2>&1`).
    private static func program(in words: [String]) -> (name: String, arguments: ArraySlice<String>)? {
        var words = words[...]
        while let first = words.first {
            if ["!", "do", "then", "else"].contains(first) || isAssignment(first)
                || first.trimmingCharacters(in: punctuation).isEmpty {
                words = words.dropFirst()
            } else if wrappers.contains(name(of: first)) {
                words = words.dropFirst()
                // Its own options and durations: `timeout -k 5 120 swift
                // build`, `env -u NAME node x.js`.
                while let next = words.first, next.hasPrefix("-") || isDuration(next) || isAssignment(next) {
                    words = words.dropFirst(wrapperOptionsWithValue.contains(next) ? 2 : 1)
                }
            } else {
                break
            }
        }
        guard let first = words.first, !first.hasPrefix(">"), !first.hasPrefix("<"), !first.allSatisfy(\.isNumber) else { return nil }
        return (name(of: first), words.dropFirst())
    }

    /// What comes before a simple command: `;`, a line's end, `||` or a
    /// lone `&` (a new chain), `&&` (it runs only if the chain so far
    /// passed), `|` (the same pipeline, whose exit is its last command's).
    private enum Separator {
        case sequence, and, pipe
    }

    /// The words of each simple command, of the first ones in a long
    /// script, and what came before it: commands end at `;`, `&`, `|` and
    /// line ends, words at spaces, both outside quotes and `$(…)`; a `#`
    /// starts a comment.
    private static func simpleCommands(in text: String) -> [(words: [String], separator: Separator)] {
        var commands: [(words: [String], separator: Separator)] = []
        var words: [String] = []
        var word = ""
        var separator = Separator.sequence
        var quote: Character?
        var substitutionDepth = 0
        var escaped = false
        var inComment = false
        var previous: Character = " "
        func endWord() {
            if !word.isEmpty { words.append(word) }
            word = ""
        }
        func endCommand(before next: Separator) {
            endWord()
            if !words.isEmpty {
                commands.append((words, separator))
                separator = next
            } else if next != .sequence || separator == .sequence {
                // `a &&⏎ b` goes on; `a & & b` reads as `a && b`.
                separator = next
            }
            words = []
        }
        // Bounded in scalars: one character can hold any number of them.
        for character in String(String.UnicodeScalarView(text.unicodeScalars.prefix(2_000))) {
            if commands.count >= 12 { return commands }
            defer { previous = character }
            if inComment {
                if character.isNewline { inComment = false }
            } else if escaped {
                escaped = false
                // A backslash at a line's end carries the command on.
                if character.isNewline { word.removeLast() } else { word.append(character) }
            } else if character == "\\", quote != "'" {
                escaped = true
                word.append(character)
            } else if let open = quote {
                if character == open { quote = nil }
                word.append(character)
            } else if character == "'" || character == "\"" || character == "`" {
                quote = character
                word.append(character)
            } else if substitutionDepth > 0 {
                if character == "(" { substitutionDepth += 1 }
                if character == ")" { substitutionDepth -= 1 }
                word.append(character)
            } else if character == "(", previous == "$" {
                substitutionDepth = 1
                word.append(character)
            } else if character == "#", word.isEmpty {
                inComment = true
                endCommand(before: .sequence)
            } else if character == "|" {
                endCommand(before: previous == "|" ? .sequence : .pipe)
            } else if character == "&", previous != ">" {
                endCommand(before: previous == "&" ? .and : .sequence)
            } else if character == ";" || character.isNewline {
                endCommand(before: .sequence)
            } else if character.isWhitespace {
                endWord()
            } else {
                word.append(character)
            }
        }
        endCommand(before: .sequence)
        return commands
    }

    private static func subcommands(of program: String, in arguments: ArraySlice<String>) -> [String] {
        guard programsWithSubcommands.contains(program) else { return [] }
        var found: [String] = []
        var arguments = arguments
        while let word = arguments.first {
            let wanted = programsWithTwoSubcommands.contains(program) || found.first.map(subcommandsWithAnother.contains) == true ? 2 : 1
            guard found.count < wanted else { break }
            arguments = arguments.dropFirst()
            // `(cd sub && make test)`: the subshell's end isn't the word's.
            let argument = word.trimmingCharacters(in: punctuation)
            if optionsWithValue.contains(argument) {
                arguments = arguments.dropFirst()
            } else if argument.hasPrefix("+") || argument.hasPrefix("-") && isWholeOption(argument) {
                continue
            } else if argument.hasPrefix("-") || !isSubcommand(argument) {
                break
            } else {
                found.append(argument)
            }
        }
        return found
    }

    /// An option that carries its value or takes none: `--color=never`,
    /// `-j8`, `--no-pager`.
    private static func isWholeOption(_ option: String) -> Bool {
        option.contains("=") || optionsWithoutValue.contains(option) || !option.hasPrefix("--") && option.count > 2
    }

    /// `build`, `pr`, `test:unit`: lowercase, short, no path or value.
    private static func isSubcommand(_ word: String) -> Bool {
        word.count <= 24 && word.first?.isLowercase == true
            && word.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-_:".contains($0)) }
    }

    /// `/usr/bin/swift` → `swift`, quotes around a path dropped.
    private static func name(of word: String) -> String {
        (word.trimmingCharacters(in: punctuation) as NSString).lastPathComponent
    }

    private static func isProgramName(_ name: String) -> Bool {
        (1...32).contains(name.count) && name.contains(where: \.isLetter)
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.+-".contains($0)) }
    }

    /// `NAME=value` before a command.
    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        return name.first?.isNumber == false && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// `120`, `2.5`, `90s`, `5m`: a wrapper's duration, not `7z`.
    private static func isDuration(_ word: String) -> Bool {
        let digits = word.last.map { "smhd".contains($0) } == true ? word.dropLast() : word[...]
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber || $0 == "." }
    }
}

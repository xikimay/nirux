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
    /// sidebar 260 points wide.
    var statusText: String {
        switch self {
        case .hung(let count):
            return "May be stuck · \(count) commands hung"
        case .failing(let name, let count):
            return "May be stuck · \(Self.display(name)) failed \(count)×"
        }
    }

    /// What the line can't hold, for its tooltip.
    var detail: String {
        let reason: String
        switch self {
        case .hung(let count):
            reason = "\(count) commands of this turn ran past their time limit."
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
    /// Calls that end without a command hanging again, or without that
    /// command failing again: the agent moved on. What happens later
    /// counts from zero, and the hint goes. (The stuck agent measured had
    /// 2 to 4 calls between hung commands.)
    static let callsThatClear = 15

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
    /// Commands failing in a row. At most `callsThatClear` of them: each
    /// goes once that many other calls ended since it last failed.
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
            if callsSinceHang >= Self.callsThatClear { hungCount = 0 }
        }
        for index in streaks.indices where streaks[index].key != key { streaks[index].callsSince += 1 }
        streaks.removeAll { $0.callsSince >= Self.callsThatClear }
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
        let failing = streaks.filter { $0.count >= Self.failureThreshold }.max { $0.lastAt < $1.lastAt }
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
    /// The user interrupted it (Esc).
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
    static let shellTools: Set<String> = ["Bash", "PowerShell"]

    /// Nil: the call ran. `command`: a shell tool's, nil for other tools.
    ///
    /// A shell command past its time limit is hung. An interactive Claude
    /// moves it to the background and goes on; a headless one kills it and
    /// reports a failure. Read from Claude Code 2.1.321's hook payloads and
    /// a month of results (2.1.111 to 2.1.321).
    static func end(hookName: String, payload: [String: Any], command: AgentShellCommand?) -> AgentToolEnd? {
        let failure = hookName == "PostToolUseFailure"
        if failure, payload["is_interrupt"] as? Bool == true { return .interrupted }
        guard let command else { return failure ? .failed : nil }
        let pastItsLimit = failure ? wasKilledAtItsLimit(payload) : wasMovedToTheBackground(payload)
        // A `sleep 600` outlasting its limit is meant to (12 of the month's
        // 43), and a poll that finds nothing yet isn't an attempt.
        if command.isWait { return failure || pastItsLimit ? .waited : nil }
        if pastItsLimit { return .hung }
        return failure ? .failed : nil
    }

    /// `backgroundTaskId` in a result nobody asked to run in the
    /// background: not the agent with `run_in_background`, nor the user, a
    /// message that had to get through, or assistant mode's own budget.
    private static func wasMovedToTheBackground(_ payload: [String: Any]) -> Bool {
        guard let response = payload["tool_response"] as? [String: Any],
              let task = response["backgroundTaskId"] as? String, !task.isEmpty,
              (payload["tool_input"] as? [String: Any])?["run_in_background"] as? Bool != true
        else { return false }
        let otherReasons = ["backgroundedByUser", "backgroundedToDeliverMessage", "backgroundedByTurnAbort", "assistantAutoBackgrounded"]
        return !otherReasons.contains { response[$0] as? Bool == true }
    }

    /// "Exit code 143", then "Command timed out after 2s": Claude's own
    /// first lines of the error, before the command's output (which may
    /// hold the same words: a test log, a grep of this file).
    private static func wasKilledAtItsLimit(_ payload: [String: Any]) -> Bool {
        if payload["is_timeout"] as? Bool == true { return true }
        guard let error = payload["error"] as? String else { return false }
        let lines = error.prefix(200).split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        let notice = "Command timed out after"
        guard let first = lines.first else { return false }
        return first.hasPrefix(notice) || first.hasPrefix("Exit code ") && lines.dropFirst().first?.hasPrefix(notice) == true
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
    /// loop, a path held in a variable).
    let family: String?
    /// The command waits for something: it starts by sleeping (a poll:
    /// `sleep 60; gh run view 9`), it is a loop that sleeps (`until curl
    /// -sf :3000; do sleep 2; done`), or one of GitHub's that exit non-zero
    /// while checks run. Coming back with a failure, or running past its
    /// time limit, is then part of waiting (for CI, a server).
    let isWait: Bool

    init(_ text: String) {
        let commands = Self.simpleCommands(in: text)
        var preparation: String?
        var sleeps = false
        for (index, words) in commands.enumerated() {
            guard let (name, arguments) = Self.program(in: words) else { continue }
            if name == "sleep" { sleeps = true }
            if Self.housekeeping.contains(name) {
                preparation = preparation ?? name
                continue
            }
            if Self.compound.contains(name) {
                family = nil
                isWait = sleeps || commands[index...].contains { Self.program(in: $0)?.name == "sleep" }
                return
            }
            guard Self.isProgramName(name) else {
                family = nil
                isWait = sleeps
                return
            }
            let named = ([name] + Self.subcommands(of: name, in: arguments)).joined(separator: " ")
            if Self.preparations.contains(named) {
                preparation = preparation ?? named
                continue
            }
            family = named
            isWait = sleeps || Self.waitingCommands.contains(named)
            return
        }
        family = preparation
        isWait = sleeps
    }

    /// Programs whose first plain argument says what they do.
    private static let programsWithSubcommands: Set<String> = [
        "git", "gh", "swift", "npm", "pnpm", "yarn", "bun", "npx", "cargo", "go", "make", "docker", "kubectl", "brew",
        "xcrun", "uv", "pip", "pip3"
    ]
    /// Their options that take the next argument as a value.
    private static let optionsWithValue: Set<String> = [
        "-C", "-c", "-f", "-R", "-n", "-H", "--repo", "--git-dir", "--work-tree", "--prefix", "--cwd", "--filter",
        "--manifest-path", "--context", "--namespace", "--kubeconfig", "--directory", "--project", "--package-path"
    ]
    /// What runs a command rather than being one.
    private static let wrappers: Set<String> = ["time", "sudo", "env", "nohup", "command", "exec", "nice", "caffeinate", "timeout", "gtimeout"]
    private static let wrapperOptionsWithValue: Set<String> = ["-u", "-k", "-s", "-n", "-g", "-C"]
    /// The shell's own housekeeping and what clears the way: the command
    /// that follows is the one to name. Alone, they name themselves.
    private static let housekeeping: Set<String> = [
        "cd", "pushd", "popd", "export", "set", "unset", "source", ".", "echo", "printf", "mkdir", "true", ":", "sleep",
        "wait", "test", "[", "[[", "umask", "ulimit", "trap", "local", "declare", "rm", "touch", "chmod", "kill", "pkill",
        "killall"
    ]
    /// The same for a program's subcommand: `git add -A && git commit`.
    private static let preparations: Set<String> = ["git add"]
    private static let compound: Set<String> = ["for", "while", "until", "if", "case", "select", "function"]
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

    /// The words of each simple command, of the first ones in a long
    /// script: commands end at `;`, `&`, `|` and line ends, words at
    /// spaces, both outside quotes and `$(…)`; a `#` starts a comment.
    private static func simpleCommands(in text: String) -> [[String]] {
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var quote: Character?
        var substitutionDepth = 0
        var escaped = false
        var inComment = false
        var previous: Character = " "
        func endWord() {
            if !word.isEmpty { words.append(word) }
            word = ""
        }
        func endCommand() {
            endWord()
            if !words.isEmpty { commands.append(words) }
            words = []
        }
        for character in text.prefix(2_000) {
            if commands.count >= 12 { return commands }
            defer { previous = character }
            if inComment {
                if character.isNewline { inComment = false }
            } else if escaped {
                escaped = false
                word.append(character)
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
                endCommand()
            } else if character == ";" || character == "|" || character.isNewline || character == "&" && previous != ">" {
                endCommand()
            } else if character.isWhitespace {
                endWord()
            } else {
                word.append(character)
            }
        }
        endCommand()
        return commands
    }

    private static func subcommands(of program: String, in arguments: ArraySlice<String>) -> [String] {
        guard programsWithSubcommands.contains(program) else { return [] }
        var found: [String] = []
        var arguments = arguments
        // `gh pr checks`: two words say what gh does.
        while found.count < (program == "gh" ? 2 : 1), let word = arguments.first {
            arguments = arguments.dropFirst()
            // `(cd sub && make test)`: the subshell's end isn't the word's.
            let argument = word.trimmingCharacters(in: punctuation)
            if argument.hasPrefix("-") || argument.hasPrefix("+") {
                if optionsWithValue.contains(argument) { arguments = arguments.dropFirst() }
                continue
            }
            guard argument.count <= 24, argument.first?.isLowercase == true,
                  argument.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
            else { break }
            found.append(argument)
        }
        return found
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

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
    /// `what` failed `count` times in a row: a shell command's program
    /// ("swift build"), else the tool ("Edit").
    case failing(what: String, count: Int)

    /// The row's status line.
    var statusText: String {
        switch self {
        case .hung(let count):
            return "May be stuck · \(count) commands hung"
        case .failing(let what, let count):
            return "May be going in circles · \(Self.subject(what, count: count))"
        }
    }

    /// What the line can't hold, for its tooltip.
    var detail: String {
        let reason: String
        switch self {
        case .hung(let count):
            reason = "\(count) commands of this turn ran past their time limit."
        case .failing(let what, let count):
            reason = "In this turn, \(Self.subject(what, count: count)) in a row."
        }
        return reason + " The agent goes on: Nirux only tells you."
    }

    /// "swift build failed 5 times"; a command Nirux couldn't name, "5
    /// commands failed"; an MCP tool by its own name.
    private static func subject(_ what: String, count: Int) -> String {
        if AgentToolOutcome.shellTools.contains(what) { return "\(count) commands failed" }
        let name = what.hasPrefix("mcp__") ? what.components(separatedBy: "__").last ?? what : what
        return "\(name) failed \(count) times"
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
    /// Calls ending after a hung command without another one: the agent
    /// got past it, and a later one starts the count again.
    static let callsThatClearHangs = 10
    /// Commands followed at once; the one that failed longest ago goes.
    static let maxStreaks = 16

    private struct Streak: Equatable, Sendable {
        let what: String
        var count: Int
        var lastAt: TimeInterval
    }

    private var hungCount = 0
    private var lastHungAt: TimeInterval = 0
    private var callsSinceHang = 0
    private var streaks: [Streak] = []

    /// A tool call of the main agent ended: `end` nil, it ran. `what`
    /// names what ran: a shell command's program, else the tool.
    mutating func noteCallEnded(what: String, end: AgentToolEnd?, at time: TimeInterval) {
        switch end {
        case .interrupted?:
            // The user's doing: it says nothing of the agent.
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
        let index = streaks.firstIndex { $0.what == what }
        guard end == .failed else {
            if let index { streaks.remove(at: index) }
            return
        }
        if let index {
            streaks[index].count += 1
            streaks[index].lastAt = time
        } else {
            if streaks.count >= Self.maxStreaks, let oldest = streaks.indices.min(by: { streaks[$0].lastAt < streaks[$1].lastAt }) {
                streaks.remove(at: oldest)
            }
            streaks.append(Streak(what: what, count: 1, lastAt: time))
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
            return .failing(what: failing.what, count: failing.count)
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
}

/// What the end of a tool call tells `AgentCirclingWatch`, read by the hook
/// receiver from Claude's PostToolUse and PostToolUseFailure payloads. Only
/// how it ended and a program's name leave the receiver: never the command,
/// its output or the error.
enum AgentToolOutcome {
    static let shellTools: Set<String> = ["Bash", "PowerShell"]

    /// Nil: the call ran, or a command that waits (`isWait`) came back
    /// with nothing yet, or outlasted its time limit.
    static func end(toolName: String, hookName: String, payload: [String: Any]) -> AgentToolEnd? {
        if hung(toolName: toolName, hookName: hookName, payload: payload) { return .hung }
        guard hookName == "PostToolUseFailure" else { return nil }
        if payload["is_interrupt"] as? Bool == true { return .interrupted }
        if shellTools.contains(toolName), let command = (payload["tool_input"] as? [String: Any])?["command"] as? String,
           isWait(command: command) {
            return nil
        }
        return .failed
    }

    /// A shell command ran past its time limit. An interactive Claude
    /// moves it to the background and goes on (`backgroundTaskId` in a
    /// result nobody asked to run in the background: not the agent with
    /// `run_in_background`, nor the user, a message that had to get
    /// through, or assistant mode's own budget); a headless one kills it
    /// and reports a failure whose error says so. Read from Claude Code
    /// 2.1.321's hook payloads and a month of results (2.1.111 to 2.1.321).
    /// Not a command that waits (`isWait`): a `sleep 600` outlasting its
    /// limit is meant to, and was 12 of the month's 43.
    static func hung(toolName: String, hookName: String, payload: [String: Any]) -> Bool {
        guard shellTools.contains(toolName) else { return false }
        if let command = (payload["tool_input"] as? [String: Any])?["command"] as? String, isWait(command: command) { return false }
        if hookName == "PostToolUseFailure" {
            // Esc on a command that would have timed out is still the user's.
            guard payload["is_interrupt"] as? Bool != true else { return false }
            if payload["is_timeout"] as? Bool == true { return true }
            return (payload["error"] as? String).map { $0.prefix(400).contains("Command timed out after") } ?? false
        }
        guard let response = payload["tool_response"] as? [String: Any],
              let task = response["backgroundTaskId"] as? String, !task.isEmpty,
              (payload["tool_input"] as? [String: Any])?["run_in_background"] as? Bool != true
        else { return false }
        let otherReasons = ["backgroundedByUser", "backgroundedToDeliverMessage", "backgroundedByTurnAbort", "assistantAutoBackgrounded"]
        return !otherReasons.contains { response[$0] as? Bool == true }
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
    /// What runs a command rather than being one, and the shell's own
    /// housekeeping: the command that follows is the one to name.
    private static let wrappers: Set<String> = ["time", "sudo", "env", "nohup", "command", "exec", "nice", "caffeinate", "timeout", "gtimeout"]
    private static let wrapperOptionsWithValue: Set<String> = ["-u", "-k", "-s", "-n", "-g", "-C"]
    private static let housekeeping: Set<String> = [
        "cd", "pushd", "popd", "export", "set", "unset", "source", ".", "echo", "printf", "mkdir", "true", ":", "sleep",
        "wait", "test", "[", "[[", "umask", "ulimit", "trap", "local", "declare"
    ]
    private static let compound: Set<String> = ["for", "while", "until", "if", "case", "select", "function"]

    /// GitHub's commands that exit non-zero while checks run, and once
    /// they failed: repeated on purpose.
    private static let waitingCommands: Set<String> = ["gh pr checks", "gh run watch"]

    /// "swift build", "gh pr checks", "python3": the program a shell
    /// command runs, with its subcommand for the tools that have one, past
    /// `cd … &&`, variables and wrappers. Nil when nothing names it (a
    /// loop, a path held in a variable): the caller says "commands". A
    /// label for people and a key to count by, not a parser: quotes are
    /// followed only to find where a command ends.
    static func family(ofCommand command: String) -> String? {
        var housekeepingFound: String?
        for words in simpleCommands(in: command) {
            guard let (name, arguments) = program(in: words) else { continue }
            if housekeeping.contains(name) {
                housekeepingFound = housekeepingFound ?? name
                continue
            }
            guard !compound.contains(name), isProgramName(name) else { return nil }
            return ([name] + subcommands(of: name, in: arguments)).joined(separator: " ")
        }
        return housekeepingFound
    }

    /// The command waits for something: it sleeps (a poll: `sleep 60; gh
    /// run view 9`, `until curl -sf :3000; do sleep 2; done`), or it is one
    /// of `waitingCommands`. Coming back with a failure, or running past
    /// its time limit, is then part of waiting (for CI, a server): neither
    /// an attempt that failed nor a command that hung.
    static func isWait(command: String) -> Bool {
        simpleCommands(in: command).contains { program(in: $0)?.name == "sleep" }
            || family(ofCommand: command).map(waitingCommands.contains) ?? false
    }

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
                while let next = words.first, next.hasPrefix("-") || next.first?.isNumber == true || isAssignment(next) {
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
    /// script: split at `;`, `&`, `|` and line ends outside quotes, then at
    /// spaces.
    private static func simpleCommands(in command: String) -> [[String]] {
        var commands: [[String]] = []
        var current = ""
        var quote: Character?
        var escaped = false
        func close() {
            let words = current.split(whereSeparator: \.isWhitespace).map(String.init)
            if !words.isEmpty { commands.append(words) }
            current = ""
        }
        for character in command.prefix(2_000) {
            if commands.count >= 12 { return commands }
            if escaped {
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == ";" || character == "|" || character.isNewline || character == "&" && current.last != ">" {
                close()
                continue
            }
            current.append(character)
        }
        close()
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

    /// Quotes, and where a subshell or a group opens and closes.
    private static let punctuation = CharacterSet(charactersIn: "\"'(){}")

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
}

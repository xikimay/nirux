// A stand-in for claude, codex and agy in the canary's world: linked under
// the agent's name, since Nirux knows agents by their process name. It logs
// how it was launched and every byte typed into it, and plays one turn per
// line through that agent's own hooks and OSC 7501 status. No model, no
// network. A line's prefix picks the turn: "ask:", "permission:",
// "background:" and "hold:" wait for the next line; "exit" quits.
import Foundation

let name = (CommandLine.arguments[0] as NSString).lastPathComponent
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment
let cwd = FileManager.default.currentDirectoryPath

func value(after flags: Set<String>) -> String? {
    guard let index = arguments.firstIndex(where: flags.contains), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let resumedID = value(after: ["--resume", "-r", "--conversation", "resume"])
let continues = arguments.contains { ["--continue", "-c", "--last"].contains($0) }
let sessionID = resumedID ?? UUID().uuidString.lowercased()

func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
}

func log(_ fields: [String: Any]) {
    guard let path = environment["NIRUX_CANARY_AGENT_LOG"] else { return }
    let base: [String: Any] = ["agent": name, "pid": Int(getpid()), "agentUUID": environment["NIRUX_AGENT_UUID"] ?? ""]
    var line = json(base.merging(fields) { _, new in new })
    line.append(0x0A)
    guard let handle = FileHandle(forWritingAtPath: path) ?? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }() else { return }
    handle.seekToEndOfFile()
    handle.write(line)
    try? handle.close()
}

func show(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

/// Codex and agy say their state in the terminal; Claude Code doesn't to Nirux.
func status(_ state: String, kind: String? = nil, message: String? = nil) {
    guard let app = ["agy": "antigravity", "codex": "codex"][name] else { return }
    var fields = ["state=" + state] + (kind.map { ["kind=" + $0] } ?? []) + ["app=" + app]
    if let message { fields.append("msg=" + Data(message.utf8).base64EncodedString()) }
    show("\u{1b}]7501;" + fields.joined(separator: ":") + "\u{07}")
}

/// Hands a hook event to Nirux the way the real agent's installed hook does.
func hook(_ event: String, _ fields: [String: Any] = [:]) {
    guard let cli = environment["NIRUX_CLI_PATH"] else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cli)
    let payload: Data
    switch name {
    case "codex":
        payload = json(["type": event, "thread-id": sessionID, "cwd": cwd].merging(fields) { _, new in new })
        process.arguments = ["--hook", "codex", String(decoding: payload, as: UTF8.self)]
    case "agy":
        payload = json(["hookEventName": event, "conversationId": sessionID, "cwd": cwd].merging(fields) { _, new in new })
        process.arguments = ["--hook", "claude", "--agy"]
    default:
        payload = json(["hook_event_name": event, "session_id": sessionID, "cwd": cwd].merging(fields) { _, new in new })
        process.arguments = ["--hook", "claude"]
    }
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return log(["event": "hook", "hook": event, "error": "\(error)"]) }
    if name != "codex" { input.fileHandleForWriting.write(payload) }
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
    log(["event": "hook", "hook": event, "status": Int(process.terminationStatus)])
}

func startTurn(_ prompt: String) {
    show("\r\n> " + prompt + "\r\n")
    switch name {
    case "claude": hook("UserPromptSubmit", ["prompt": prompt, "prompt_id": UUID().uuidString.lowercased()])
    default: status("working")
    }
}

func endTurn(_ prompt: String, saying message: String) {
    show("* " + message + "\r\n")
    switch name {
    case "claude": hook("Stop", ["last_assistant_message": message, "stop_hook_active": false])
    case "agy": hook("Stop", ["fullyIdle": true]); status("done", message: message)
    default: hook("agent-turn-complete", ["last-assistant-message": message, "input-messages": [prompt]]); status("done", message: message)
    }
}

func block(kind: String, message: String) {
    show("? " + message + "\r\n")
    switch name {
    case "claude" where kind == "permission":
        hook("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
    case "claude": hook("Stop", ["last_assistant_message": message, "stop_hook_active": false])
    default: status("blocked", kind: kind, message: message)
    }
}

/// A turn waiting for the next line: what it asked, and what it says then.
var waiting: (prompt: String, answer: String)?

func play(_ line: String) {
    if let pending = waiting {
        waiting = nil
        if name != "claude" { status("working") }
        return endTurn(pending.prompt, saying: pending.answer + " (" + line + ")")
    }
    let verb = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    if line == "exit" {
        if name == "claude" { hook("SessionEnd", ["reason": "prompt_input_exit"]) }
        log(["event": "exit"])
        exit(0)
    }
    startTurn(line)
    switch verb {
    case "ask":
        block(kind: "question", message: "Which one do you want: A or B?")
        waiting = (line, "Going with it")
    case "permission":
        block(kind: "permission", message: "Bash: rm -rf build")
        waiting = (line, "Ran it")
    case "background":
        // A stop while a build it started runs on, then more work.
        endTurn(line, saying: "Waiting for swift build to finish")
        if name != "claude" { status("working") }
        waiting = (line, "Build finished")
    case "hold":
        waiting = (line, "Done")
    default:
        endTurn(line, saying: "Done: " + line)
    }
}

var original = termios()
let isTerminal = isatty(STDIN_FILENO) == 1
if isTerminal {
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    raw.c_iflag &= ~tcflag_t(ICRNL)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}
show("fake " + name + " " + arguments.joined(separator: " ") + " · session " + sessionID + "\r\n")
log(["event": "start", "argv": arguments, "cwd": cwd, "session": sessionID, "resumed": resumedID != nil || continues])
switch name {
case "claude": hook("SessionStart", ["source": resumedID != nil || continues ? "resume" : "startup"])
case "agy" where resumedID == nil: hook("SessionStart"); status("idle")
default: status("idle")
}

var line = ""
var buffer = [UInt8](repeating: 0, count: 4096)
while true {
    let count = read(STDIN_FILENO, &buffer, buffer.count)
    guard count > 0 else { break }
    let chunk = String(decoding: buffer[0..<count], as: UTF8.self)
    log(["event": "input", "text": chunk])
    for character in chunk.replacingOccurrences(of: "\u{1b}[200~", with: "").replacingOccurrences(of: "\u{1b}[201~", with: "") {
        switch character {
        case "\r", "\r\n":
            if !line.isEmpty { play(line) }
            line = ""
        // Ctrl-J: a new line in the prompt, as in Claude Code.
        case "\n": line.append("\n")
        case "\u{7f}": if !line.isEmpty { line.removeLast() }
        default: line.append(character)
        }
    }
}
if isTerminal { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
log(["event": "exit"])

import AppKit
import GhosttyTerminal
import XCTest
@testable import Nirux

// Throwaway diagnostics for the Search Everywhere flake: never merged.

final class ZZDebugLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    static func start() -> ZZDebugLog {
        let log = ZZDebugLog()
        TerminalDebugLog.sink = { line in log.add(line) }
        TerminalDebugLog.enable([.lifecycle, .metrics, .input, .output, .actions])
        return log
    }

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 8000 { lines.removeFirst(2000) }
        lock.unlock()
    }

    func tail(_ count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(count))
    }
}

@MainActor
enum ZZDiag {
    static func field(_ name: String, of subject: Any) -> Any? {
        Mirror(reflecting: subject).children.first { $0.label == name }?.value
    }

    static func state(_ session: InMemoryTerminalSession, needle: String) -> String {
        let access = field("surfaceAccess", of: session)
        let active = access.flatMap { field("activeOperations", of: $0) }.map { "\($0)" } ?? "?"
        let drain = access.flatMap { field("isDrainScheduled", of: $0) }.map { "\($0)" } ?? "?"
        let surface = access.flatMap { field("surface", of: $0) }.map { "\($0)" } ?? "?"
        let whole = TerminalScreenText.wholeScreen(session)
        let has = TerminalScreenText.read(session)?.contains(needle) == true
        let wholeTail = String((whole ?? "").suffix(600)).debugDescription
        let viewportTail = String((session.readViewportText() ?? "nil").suffix(300)).debugDescription
        return "has=\(has) pending=\(session.pendingOutputByteCount) activeOps=\(active) drainScheduled=\(drain) surface=\(surface) wholeNil=\(whole == nil) wholeTail=\(wholeTail) viewportTail=\(viewportTail)"
    }

    static func sample() -> String {
        let path = NSTemporaryDirectory() + "zz-sample-\(getpid()).txt"
        for (tool, args) in [("/usr/bin/sudo", ["-n", "/usr/bin/sample"]), ("/usr/bin/sample", [])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args + [String(getpid()), "1", "-mayDie", "-file", path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0, let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
        }
        return "(no sample)"
    }

    /// Printed when the wait for the new matches runs out.
    static func dump(session: InMemoryTerminalSession, column: ColumnState, harness: UIFlowHarness, log: ZZDebugLog, needle: String) -> String {
        var out: [String] = ["ZZDIAG begin"]
        out.append("ZZDIAG state: \(state(session, needle: needle))")
        let pty = column.pty
        out.append("ZZDIAG pty: exited=\(pty?.hasExited ?? true) shellPID=\(String(describing: pty?.shellPID)) readsKeysAsTyped=\(pty?.readsKeysAsTyped ?? false) sameSession=\(pty?.terminalSession === session) appActive=\(NSApp.isActive) windowVisible=\(harness.shell.window?.occlusionState.contains(.visible) ?? false) terminalInWindow=\(column.terminalView?.window != nil)")
        out.append("ZZDIAG log tail:")
        out.append(contentsOf: log.tail(400).map { "ZZLOG \($0)" })
        print(out.joined(separator: "\n"))
        out = []
        print("ZZDIAG sample:\n" + sample())
        usleep(300_000)
        out.append("ZZDIAG after 0.3 s, no run loop: \(state(session, needle: needle))")
        column.terminalView?.controller?.tick()
        usleep(300_000)
        out.append("ZZDIAG after one tick: \(state(session, needle: needle))")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        out.append("ZZDIAG after 1 s of run loop: \(state(session, needle: needle))")
        out.append("ZZDIAG log since:")
        out.append(contentsOf: log.tail(60).map { "ZZLOG \($0)" })
        out.append("ZZDIAG end")
        print(out.joined(separator: "\n"))
        return "(ZZDIAG above)"
    }
}

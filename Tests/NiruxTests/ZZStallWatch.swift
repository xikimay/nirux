import AppKit
import XCTest

/// DO NOT MERGE. What a flaky test's process went through: a dated trace,
/// the longest time the main queue went unserved, the longest time a
/// background thread went unscheduled (the whole process starved), and a
/// sample of the process the first time the main queue stalls.
final class ZZStallWatch: @unchecked Sendable {
    static let processStart = CACurrentMediaTime()

    private let lock = NSLock()
    private let label: String
    private let sampleAfter: Double
    private let start = CACurrentMediaTime()
    private var lines: [String] = []
    private var lastMainTick = CACurrentMediaTime()
    private var longestMainGap = 0.0
    private var longestMainGapEndedAt = 0.0
    private var longestThreadGap = 0.0
    private var longestThreadGapEndedAt = 0.0
    private var stopped = false
    private var samplePath: String?
    private var timer: DispatchSourceTimer?

    init(label: String, sampleAfter: Double = 0.7) {
        self.label = label
        self.sampleAfter = sampleAfter
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.mainTicked() }
        timer.resume()
        self.timer = timer
        let body: @Sendable () -> Void = { [weak self] in
            var last = CACurrentMediaTime()
            while true {
                usleep(5_000)
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.lock.lock()
                if self.stopped { self.lock.unlock(); return }
                if now - last > self.longestThreadGap {
                    self.longestThreadGap = now - last
                    self.longestThreadGapEndedAt = now - self.start
                }
                let mainSilent = now - self.lastMainTick
                let samples = mainSilent > self.sampleAfter && self.samplePath == nil
                if samples { self.samplePath = NSTemporaryDirectory() + "zz-sample-\(getpid())-\(UUID().uuidString).txt" }
                let path = self.samplePath
                self.lock.unlock()
                if samples, let path {
                    self.log("main queue silent for \(Self.ms(mainSilent)): sampling")
                    Self.sample(to: path)
                    self.log("sampled")
                }
                last = CACurrentMediaTime()
            }
        }
        let thread = Thread(block: body)
        thread.start()
    }

    private static func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1_000) }

    private func mainTicked() {
        let now = CACurrentMediaTime()
        lock.lock()
        if now - lastMainTick > longestMainGap {
            longestMainGap = now - lastMainTick
            longestMainGapEndedAt = now - start
        }
        lastMainTick = now
        lock.unlock()
    }

    /// The main thread says it is alive without waiting for its queue.
    func tick() { mainTicked() }

    func log(_ line: String) {
        let now = CACurrentMediaTime()
        lock.lock()
        lines.append(String(format: "%8.3f %@", now - start, line))
        lock.unlock()
    }

    private static func sample(to path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(getpid())", "1", "10", "-mayDie", "-file", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? "sample did not run: \(error)".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// One line always; the trace and the sample when `full`.
    func finish(_ summary: String, full: Bool) {
        lock.lock()
        stopped = true
        let lines = self.lines
        let path = samplePath
        let report = String(
            format: "ZZ %@: %@ · took %.3f s · started %.1f s into the process · main queue unserved at most %.0f ms (ended at %.3f) · a thread unscheduled at most %.0f ms (ended at %.3f)",
            label, summary, CACurrentMediaTime() - start, start - Self.processStart, longestMainGap * 1_000,
            longestMainGapEndedAt, longestThreadGap * 1_000, longestThreadGapEndedAt
        )
        lock.unlock()
        timer?.cancel()
        print(report)
        guard full else { return }
        print("ZZ \(label) trace:")
        lines.forEach { print("ZZ   \($0)") }
        if let path, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            // The main thread's part of the call graph.
            let all = text.components(separatedBy: "\n")
            let from = all.firstIndex { $0.contains("Call graph:") } ?? 0
            print("ZZ \(label) sample (\(all.count) lines):")
            all[from...].prefix(90).forEach { print("ZZ   | \($0)") }
        } else if path != nil {
            print("ZZ \(label): no sample file")
        }
    }

    /// The caller's stack, short.
    static func stack(skip: Int = 2, frames: Int = 22) -> String {
        Thread.callStackSymbols.dropFirst(skip).prefix(frames).map { symbol in
            let parts = symbol.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            let name = parts.count > 3 ? String(parts[3]) : symbol
            return String((name.components(separatedBy: " + ").first ?? "").prefix(90))
        }.joined(separator: " < ")
    }
}

/// DO NOT MERGE. The preferred scroller style, and each time it changes in
/// this process.
@MainActor
enum ZZScrollerStyle {
    private static var observer: NSObjectProtocol?

    static func note(_ test: String) {
        if observer == nil {
            _ = ZZStallWatch.processStart
            print("ZZ scroller style: watching, AppleShowScrollBars \(UserDefaults.standard.string(forKey: "AppleShowScrollBars") ?? "-")")
            observer = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: nil
            ) { _ in
                let stack = ZZStallWatch.stack()
                let at = CACurrentMediaTime() - ZZStallWatch.processStart
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        print(String(format: "ZZ scroller style: CHANGED %.3f s into the process, preferred now %ld :: %@", at, NSScroller.preferredScrollerStyle.rawValue, stack))
                    }
                } else {
                    print(String(format: "ZZ scroller style: CHANGED off the main thread %.3f s into the process :: %@", at, stack))
                }
            }
        }
        print(String(format: "ZZ scroller style: %@ starts %.3f s into the process, preferred %ld", test, CACurrentMediaTime() - ZZStallWatch.processStart, NSScroller.preferredScrollerStyle.rawValue))
    }
}

import Foundation

/// The first line of a macOS crash report (`.ips`): a one-line JSON object
/// that names the app, its version and the report. Every field is optional,
/// macOS versions add and drop them.
struct CrashReportHeader: Equatable, Sendable {
    /// `bug_type` of a crash; hang and resource reports use other values.
    static let crashBugType = "309"

    var bugType: String?
    var bundleID: String?
    var appName: String?
    var appVersion: String?
    var buildVersion: String?
    var osVersion: String?
    var incidentID: String?
    /// When the report was written, not when the app crashed: ReportCrash
    /// writes it seconds later, several crashes can share one.
    var timestamp: Date?

    var isCrash: Bool { bugType == nil || bugType == Self.crashBugType }
}

/// What a crash report says about the crash. Parsed leniently: a report
/// ReportCrash is still writing is truncated, and a field of the wrong type
/// reads as absent instead of failing the whole report.
struct CrashReport: Equatable, Sendable {
    struct Frame: Equatable, Sendable {
        var image: String?
        var symbol: String?
        /// Offset into `symbol` (`symbolLocation`).
        var symbolOffset: Int?
        /// Offset into `image`, for frames without a symbol.
        var imageOffset: Int?
    }

    /// `procRole` of a process running as an app. `Nirux --hook` /
    /// `--mission`, which Claude Code and Codex spawn on every event, run as
    /// command-line tools: "Unspecified" (seen on their reports), "Default"
    /// or "Non UI".
    static let appRoles: Set<String> = ["Foreground", "Background"]

    var header: CrashReportHeader
    /// False when only the header could be read.
    var hasBody = false
    var processName: String?
    var processRole: String?
    /// `parentProc`: "launchd" for an app opened from the Dock, Finder or
    /// `open`; the agent or a shell for the hook receiver.
    var parentProcess: String?
    var exceptionType: String?
    var signal: String?
    /// "KERN_INVALID_ADDRESS at 0x…" for bad accesses.
    var exceptionSubtype: String?
    /// "Trace/BPT trap: 5".
    var termination: String?
    /// When the app crashed, as the report prints it.
    var crashTime: String?
    var faultingThread: Int?
    var faultingQueue: String?
    /// The crashed thread's frames, innermost first.
    var frames: [Frame] = []
    /// Where an uncaught Objective-C exception was thrown; the crashed
    /// thread then only shows the abort that followed.
    var exceptionBacktrace: [Frame] = []
    /// Application Specific Information, e.g. "Fatal error: Index out of range".
    var messages: [String] = []

    /// A crash of the hook or mission receiver, not of the app: neither run
    /// as an app nor opened by launchd. Unknown (a truncated report) counts
    /// as the app.
    var isCommandLineRun: Bool {
        guard let processRole else { return false }
        return !Self.appRoles.contains(processRole) && parentProcess != "launchd"
    }

    /// The first frame in the app's own binary: where the crash happened,
    /// below the runtime's checks that trapped. An uncaught exception's
    /// backtrace comes first: the crashed thread only shows the abort.
    var appFrame: Frame? {
        guard let processName else { return nil }
        return (exceptionBacktrace + frames).first { $0.image == processName && $0.symbol != nil }
    }
}

enum CrashReportParser {
    /// Reads the header from the report's first line. Nil when that line
    /// isn't a JSON object.
    static func header(from data: Data) -> CrashReportHeader? {
        let firstLine = data.firstIndex(of: UInt8(ascii: "\n")).map { data[..<$0] } ?? data[...]
        guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any] else {
            return nil
        }
        return CrashReportHeader(
            bugType: string(object["bug_type"]),
            bundleID: string(object["bundleID"]),
            appName: string(object["app_name"]),
            appVersion: string(object["app_version"]),
            buildVersion: string(object["build_version"]),
            osVersion: string(object["os_version"]),
            incidentID: string(object["incident_id"]),
            timestamp: string(object["timestamp"]).flatMap(date(from:))
        )
    }

    /// The whole report; nil only when the header is unreadable. A missing
    /// or truncated body leaves `hasBody` false.
    static func report(from data: Data) -> CrashReport? {
        guard let header = header(from: data) else { return nil }
        var report = CrashReport(header: header)
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let body = try? JSONSerialization.jsonObject(with: Data(data[data.index(after: newline)...]))
                as? [String: Any]
        else { return report }

        report.hasBody = true
        report.processName = string(body["procName"]) ?? header.appName
        report.processRole = string(body["procRole"])
        report.parentProcess = string(body["parentProc"])
        let exception = body["exception"] as? [String: Any]
        report.exceptionType = string(exception?["type"])
        report.signal = string(exception?["signal"])
        report.exceptionSubtype = string(exception?["subtype"])
        report.termination = string((body["termination"] as? [String: Any])?["indicator"])
        report.crashTime = string(body["captureTime"])

        let images = (body["usedImages"] as? [Any])?.map { image in
            string((image as? [String: Any])?["name"])
        } ?? []
        let threads = body["threads"] as? [Any] ?? []
        let declared = int(body["faultingThread"])
        let faultingIndex = declared.flatMap { threads.indices.contains($0) ? $0 : nil }
            ?? threads.firstIndex { ($0 as? [String: Any])?["triggered"] as? Bool == true }
        report.faultingThread = faultingIndex ?? declared
        if let faultingIndex, let thread = threads[safe: faultingIndex] as? [String: Any] {
            report.faultingQueue = string(thread["queue"])
            report.frames = frames(thread["frames"], images: images)
        }
        report.exceptionBacktrace = frames(body["lastExceptionBacktrace"], images: images)
        report.messages = messages(body["asi"])
        return report
    }

    private static func frames(_ value: Any?, images: [String?]) -> [CrashReport.Frame] {
        (value as? [Any] ?? []).compactMap { frame in
            guard let frame = frame as? [String: Any] else { return nil }
            let imageIndex = int(frame["imageIndex"])
            let image = imageIndex.flatMap { images[safe: $0] ?? nil }
            return CrashReport.Frame(
                image: image,
                symbol: string(frame["symbol"]),
                symbolOffset: int(frame["symbolLocation"]),
                imageOffset: int(frame["imageOffset"])
            )
        }
    }

    /// `asi` maps an image name to its messages.
    private static func messages(_ value: Any?) -> [String] {
        guard let asi = value as? [String: Any] else { return [] }
        return asi.keys.sorted().flatMap { key -> [String] in
            if let lines = asi[key] as? [Any] { return lines.compactMap(string) }
            return string(asi[key]).map { [$0] } ?? []
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// JSON numbers arrive as NSNumber; a Bool is one too, and not an index.
    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    /// "2026-09-27 11:14:48.00 +0200", with any number of fraction digits.
    /// Nil for anything else: a report file is input, and a trap here would
    /// crash every launch while the file is there.
    static func date(from text: String) -> Date? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let clock = parts[1].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let seconds = clock.first, !seconds.isEmpty else { return nil }
        var fraction: TimeInterval = 0
        if clock.count == 2 {
            let digits = clock[1]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Double("0." + digits)
            else { return nil }
            fraction = value
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: "\(parts[0]) \(seconds) \(parts[2])")?.addingTimeInterval(fraction)
    }
}

/// The text the crash notice shows and copies.
enum CrashReportSummary {
    static let maxFrames = 15
    static let maxMessages = 3
    static let maxLineLength = 200
    static let maxLength = 4000

    /// One line for the status bar: "EXC_BREAKPOINT in NiruxShellView.inspectForPanel".
    static func headline(for report: CrashReport) -> String {
        let location = (report.appFrame?.symbol).map(shortSymbol)
        switch (report.exceptionType ?? report.signal, location) {
        case let (type?, location?): return "\(type) in \(location)"
        case let (type?, nil): return type
        case let (nil, location?): return "in \(location)"
        case (nil, nil): return "no details in the report"
        }
    }

    /// "closure #1 in NiruxShellView.inspectForPanel(_:panel:queue:)" →
    /// "NiruxShellView.inspectForPanel". Objective-C symbols stay whole.
    static func shortSymbol(_ symbol: String) -> String {
        if symbol.hasPrefix("-[") || symbol.hasPrefix("+[") { return symbol }
        var name = Substring(symbol)
        let wrappers = ["partial apply for ", "thunk for ", "specialized ", "merged ", "@objc ", "static "]
        // "closure #1 in", or with its signature: "closure #1 (Int) -> () in".
        let patterns = [#"^(implicit )?closure #\d+ (.*? )?in "#, #"^\(extension in [^)]*\):"#]
        var stripped = true
        while stripped {
            stripped = false
            for wrapper in wrappers where name.hasPrefix(wrapper) {
                name = name.dropFirst(wrapper.count)
                stripped = true
            }
            for pattern in patterns {
                if let range = name.range(of: pattern, options: .regularExpression) {
                    name = name[range.upperBound...]
                    stripped = true
                }
            }
        }
        name = name[..<argumentListStart(of: name)]
        let short = name.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? symbol : short
    }

    /// The first "(" outside generic arguments: `Foo<(Int) -> Int>.bar()`
    /// keeps its generics.
    private static func argumentListStart(of name: Substring) -> Substring.Index {
        var depth = 0
        var previous: Character?
        for index in name.indices {
            switch name[index] {
            case "<": depth += 1
            case ">" where previous != "-": depth = max(0, depth - 1)
            case "(" where depth == 0: return index
            default: break
            }
            previous = name[index]
        }
        return name.endIndex
    }

    /// Plain text for an agent: what crashed, where, and in which build.
    /// Bounded in frames, line length and total length; the report's path
    /// is never cut.
    static func text(for report: CrashReport, reportPath: String, otherReportCount: Int = 0) -> String {
        let appName = report.processName ?? report.header.appName ?? "Nirux"
        var lines = ["\(appName) crashed: \(exceptionLine(for: report))"]
        if let version = report.header.appVersion {
            let build = report.header.buildVersion.map { " (\($0))" } ?? ""
            lines.append("Version: \(version)\(build)")
        }
        if let time = report.crashTime { lines.append("Crashed at: \(time)") }
        if let os = report.header.osVersion { lines.append("OS: \(os)") }
        if let termination = report.termination { lines.append("Termination: \(termination)") }
        for message in report.messages.prefix(maxMessages) {
            lines.append("Message: \(message)")
        }

        if !report.exceptionBacktrace.isEmpty {
            lines.append("")
            lines.append("Last exception backtrace:")
            lines += frameLines(report.exceptionBacktrace)
        }
        if !report.frames.isEmpty {
            lines.append("")
            let thread = report.faultingThread.map { "Thread \($0) crashed" } ?? "Crashed thread"
            let queue = report.faultingQueue.map { " (queue: \($0))" } ?? ""
            lines.append("\(thread)\(queue):")
            lines += frameLines(report.frames)
        }
        if !report.hasBody {
            lines.append("")
            lines.append("The report is truncated or unreadable: only its header was parsed.")
        }

        var footer = [""]
        if otherReportCount > 0 {
            let plural = otherReportCount == 1 ? "" : "s"
            footer.append(oneLine("\(otherReportCount) earlier crash report\(plural) in the same folder."))
        }
        footer.append("Report: " + oneLine(reportPath, limit: .max))

        let body = lines.map { oneLine($0) }.joined(separator: "\n")
        let tail = footer.joined(separator: "\n")
        return bounded(body, to: maxLength - tail.count - 1) + "\n" + tail
    }

    private static func exceptionLine(for report: CrashReport) -> String {
        var parts: [String] = []
        if let type = report.exceptionType {
            parts.append(report.signal.map { "\(type) (\($0))" } ?? type)
        } else if let signal = report.signal {
            parts.append(signal)
        }
        if let subtype = report.exceptionSubtype { parts.append(subtype) }
        return parts.isEmpty ? "unknown exception" : parts.joined(separator: ", ")
    }

    private static func frameLines(_ frames: [CrashReport.Frame]) -> [String] {
        let shown = frames.prefix(maxFrames)
        let imageWidth = min(30, shown.map { ($0.image ?? "???").count }.max() ?? 0)
        var lines = shown.enumerated().map { index, frame in
            let number = String(index).leftPadded(to: 2)
            let image = (frame.image ?? "???").rightPadded(to: imageWidth)
            return "\(number)  \(image)  \(location(of: frame))"
        }
        if frames.count > shown.count {
            lines.append("    … \(frames.count - shown.count) more frames in the report")
        }
        return lines
    }

    private static func location(of frame: CrashReport.Frame) -> String {
        if let symbol = frame.symbol {
            return frame.symbolOffset.map { "\(symbol) + \($0)" } ?? symbol
        }
        return frame.imageOffset.map { "0x" + String($0, radix: 16) } ?? "???"
    }

    /// No control characters or line breaks (a message can span lines), at
    /// most `limit` characters.
    private static func oneLine(_ text: String, limit: Int = maxLineLength) -> String {
        let breaks = CharacterSet.controlCharacters.union(.newlines)
        let scalars = text.unicodeScalars.map { breaks.contains($0) ? " " : $0 }
        let line = String(String.UnicodeScalarView(scalars))
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// Cuts at a line boundary and marks the cut.
    private static func bounded(_ text: String, to length: Int) -> String {
        guard text.count > length else { return text }
        let cut = text.prefix(max(0, length - 2))
        let lastLine = cut.lastIndex(of: "\n") ?? cut.startIndex
        return String(cut[..<lastLine]) + "\n…"
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

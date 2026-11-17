import Foundation

/// The permission prompts and questions of each space's Claude sessions,
/// from the PermissionRequest hooks Nirux already receives (Space Settings
/// › Safety, "Where you're still in the loop"). A line holds the time, the
/// tool, what the prompt was about (`AgentHookEvent.promptTarget`) and the
/// permission mode: never a command's text, a file's contents or a
/// question.
///
/// File: `<state dir>/projects/<space id>/loop.jsonl`, 0600. Lines older
/// than `keptDays` go at launch and at the next append once the oldest is
/// past it; what is kept then starts a day later, so the file is rewritten
/// at most once a day. A line this build can't read is dropped then.
enum LoopLog {
    static let fileName = "loop.jsonl"
    static let keptDays = 30
    /// A larger file, or anything but a regular file, isn't read.
    static let maxFileBytes = 4_000_000
    private static let day: TimeInterval = 86_400

    struct Entry: Codable, Equatable, Sendable {
        var time: TimeInterval
        var tool: String
        var target: String?
        var mode: String?

        enum CodingKeys: String, CodingKey { case time = "t", tool, target, mode }
    }

    static func fileURL(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(fileName)
    }

    /// The prompt an event reports, or nil.
    static func entry(of event: AgentHookEvent) -> Entry? {
        guard event.kind == .claude, event.name == .permissionRequest, let tool = event.toolName else { return nil }
        return Entry(time: event.timestamp, tool: tool, target: event.promptTarget, mode: event.permissionMode)
    }

    static func append(_ entry: Entry, spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              var line = try? JSONEncoder().encode(entry) else { return }
        trim(spaceID: spaceID, now: entry.time, stateDirectory: stateDirectory)
        line.append(UInt8(ascii: "\n"))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).write(contentsOf: line)
        } catch {
            NiruxDebugLog.log("LoopLog: could not append to \(url.path): \(error)")
        }
    }

    /// The lines it can read, in the order they came.
    static func load(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> [Entry] {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              case .data(let data) = BoardConfigStore.read(url, maxBytes: maxFileBytes) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Entry.self, from: $0) }
    }

    /// Reads only the first line, unless it is past `keptDays` (or can't be
    /// read): lines come in time order, but for a queue replayed late.
    static func trim(spaceID: String, now: TimeInterval = Date().timeIntervalSince1970, stateDirectory: URL = Persistence.stateDirectory) {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        let head = (try? handle.read(upToCount: 4096)) ?? nil
        try? handle.close()
        guard let first = head?.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first else { return }
        let firstTime = (try? JSONDecoder().decode(Entry.self, from: first))?.time ?? -.infinity
        guard firstTime < now - Double(keptDays) * day else { return }
        let kept = load(spaceID: spaceID, stateDirectory: stateDirectory).filter { $0.time >= now - Double(keptDays - 1) * day }
        let lines = kept.compactMap { try? JSONEncoder().encode($0) }.map { $0 + Data("\n".utf8) }
        do {
            try SpaceDefaultsStore.writePrivately(lines.reduce(Data(), +), to: url)
        } catch {
            NiruxDebugLog.log("LoopLog: could not trim \(url.path): \(error)")
        }
    }
}

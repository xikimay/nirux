import Foundation

/// Lines a space keeps for a while, one JSON object each, in the order
/// they came: `<state dir>/projects/<space id>/<fileName>`, 0600. Lines
/// older than `keptDays` go at launch and at the next append once the
/// oldest is past it; what is kept then starts a day later, so the file is
/// rewritten at most once a day. A line this build can't read is dropped
/// then; a file it can't read is never rewritten. Past `maxFileBytes`
/// nothing is added until old lines go (`isFull`).
struct SpaceLog<Entry: Codable & Sendable>: Sendable {
    let fileName: String
    let keptDays: Int
    /// Appends stop there; a file past it by more than a line, or anything
    /// but a regular file, isn't read.
    let maxFileBytes: Int
    let time: @Sendable (Entry) -> TimeInterval
    /// Appends and their trims, off the main thread, in order.
    let queue: DispatchQueue

    private var readLimit: Int { maxFileBytes + 65_536 }
    private static var day: TimeInterval { 86_400 }

    init(fileName: String, keptDays: Int, maxFileBytes: Int, time: @escaping @Sendable (Entry) -> TimeInterval) {
        self.fileName = fileName
        self.keptDays = keptDays
        self.maxFileBytes = maxFileBytes
        self.time = time
        queue = DispatchQueue(label: "nirux.space-log.\(fileName)")
    }

    func fileURL(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(fileName)
    }

    /// `append` on `queue`.
    func appendInBackground(_ entry: Entry, spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        queue.async { append(entry, spaceID: spaceID, stateDirectory: stateDirectory) }
    }

    /// `trim` for each space on `queue`, after the appends already on it.
    func trimInBackground(spaceIDs: [String], stateDirectory: URL = Persistence.stateDirectory) {
        queue.async { for spaceID in spaceIDs { trim(spaceID: spaceID, stateDirectory: stateDirectory) } }
    }

    /// The file reached `maxFileBytes`: nothing more is added.
    func isFull(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> Bool {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { return false }
        return size >= maxFileBytes
    }

    func append(_ entry: Entry, spaceID: String, stateDirectory: URL = Persistence.stateDirectory) {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              var line = try? JSONEncoder().encode(entry) else { return }
        trim(spaceID: spaceID, now: time(entry), stateDirectory: stateDirectory)
        guard !isFull(spaceID: spaceID, stateDirectory: stateDirectory) else { return }
        line.append(UInt8(ascii: "\n"))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).write(contentsOf: line)
        } catch {
            NiruxDebugLog.log("\(fileName): could not append to \(url.path): \(error)")
        }
    }

    /// The lines it can read, in the order they came.
    func load(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> [Entry] {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              case .data(let data) = BoardConfigStore.read(url, maxBytes: readLimit) else { return [] }
        return decode(data)
    }

    private func decode(_ data: Data) -> [Entry] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Entry.self, from: $0) }
    }

    /// Reads only the first line, unless it is past `keptDays` (or can't be
    /// read): lines come in time order, but for a queue replayed late.
    func trim(spaceID: String, now: TimeInterval = Date().timeIntervalSince1970, stateDirectory: URL = Persistence.stateDirectory) {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        let head = (try? handle.read(upToCount: 4096)) ?? nil
        try? handle.close()
        guard let first = head?.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first else { return }
        let firstTime = (try? JSONDecoder().decode(Entry.self, from: first)).map(time) ?? -.infinity
        guard firstTime < now - Double(keptDays) * Self.day else { return }
        // Never over a file it couldn't read.
        guard case .data(let data) = BoardConfigStore.read(url, maxBytes: readLimit) else { return }
        let kept = decode(data).filter { time($0) >= now - Double(keptDays - 1) * Self.day }
        let lines = kept.compactMap { try? JSONEncoder().encode($0) }.map { $0 + Data("\n".utf8) }
        do {
            try SpaceDefaultsStore.writePrivately(lines.reduce(Data(), +), to: url)
        } catch {
            NiruxDebugLog.log("\(fileName): could not trim \(url.path): \(error)")
        }
    }
}

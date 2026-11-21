import Foundation

extension TaskThread {
    /// The JSONL files for one space. Callers serialize mutations and supply its threads folder.
    public struct Store: Sendable {
        public let folder: URL

        public init(folder: URL) {
            self.folder = folder
        }

        public static let keptAfterClose: TimeInterval = 183 * 86_400
        public static let maxSpaceBytes = 20_000_000
        /// Appends stop there, but for the close.
        public static let maxFileBytes = 2_000_000
        public static let maxRequestLength = 65_536
        public static let maxTextLength = 8_000

        /// Nil for an id that could name another file: workspace ids are UUIDs.
        public func fileURL(workspaceID: String) -> URL? {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard !workspaceID.isEmpty, workspaceID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            return folder.appendingPathComponent("\(workspaceID).jsonl")
        }

        /// Skips unreadable lines, including a partial final record from an interrupted append.
        public static func load(from url: URL) -> [Event] {
            guard case .data(let data) = RegularFileRead.read(url, maxBytes: maxFileBytes + 65_536) else { return [] }
            let decoder = JSONDecoder()
            return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Event.self, from: $0) }
        }

        /// Consult the task's previous location only if its file is missing from this folder.
        @discardableResult
        public func append(_ events: [Event], workspaceID: String, movingFrom previousFile: () -> URL? = { nil }) throws -> Int {
            guard !events.isEmpty, let url = fileURL(workspaceID: workspaceID) else { return 0 }
            let manager = FileManager.default
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path), let previous = previousFile() {
                try manager.moveItem(at: previous, to: url)
            }
            return try Self.write(events, to: url, create: true)
        }

        /// A late reply from GitHub can only enrich a retained, closed thread.
        public func appendHistory(
            _ events: [Event], workspaceID: String, keeping open: Set<String>, now: TimeInterval,
            onPruneError: (URL, Error) -> Void = { _, _ in }
        ) throws {
            guard !events.isEmpty, !open.contains(workspaceID), let url = fileURL(workspaceID: workspaceID),
                  Self.load(from: url).contains(where: { $0.kind == .closed }) else { return }
            if try Self.write(events, to: url, create: false) > 0 {
                prune(keeping: open, now: now, onError: onPruneError)
            }
        }

        private static func write(_ events: [Event], to url: URL, create: Bool) throws -> Int {
            let flags = O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            let descriptor = open(url.path, create ? flags | O_CREAT : flags, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
            var size = Int(status.st_size)
            var lines = Data()
            // A line a crash cut keeps its end: the next one starts on its own.
            var last: UInt8 = 0
            if size > 0, pread(descriptor, &last, 1, off_t(size - 1)) == 1, last != UInt8(ascii: "\n") {
                lines.append(UInt8(ascii: "\n"))
            }
            var written = 0
            for event in events {
                guard var line = try? JSONEncoder().encode(capped(event)) else { continue }
                line.append(UInt8(ascii: "\n"))
                guard event.kind == .closed || size + line.count <= maxFileBytes else { continue }
                lines.append(line)
                size += line.count
                written += 1
            }
            try handle.write(contentsOf: lines)
            return written
        }

        /// Removes the threads `open` doesn't list that were last written
        /// six months before `now`, then the oldest of them while they hold
        /// more than `maxSpaceBytes`.
        public func prune(keeping open: Set<String>, now: TimeInterval, onError: (URL, Error) -> Void = { _, _ in }) {
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
            var total = 0
            var ownerless: [(url: URL, writtenAt: TimeInterval, size: Int)] = []
            for name in names where name.hasSuffix(".jsonl") && !open.contains(String(name.dropLast(".jsonl".count))) {
                let url = folder.appendingPathComponent(name)
                guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? Int else { continue }
                total += size
                let writtenAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -.infinity
                ownerless.append((url, writtenAt, size))
            }
            for file in ownerless.sorted(by: { $0.writtenAt < $1.writtenAt })
            where file.writtenAt < now - Self.keptAfterClose || total > Self.maxSpaceBytes {
                do {
                    try manager.removeItem(at: file.url)
                    total -= file.size
                } catch {
                    onError(file.url, error)
                }
            }
        }

        private static func capped(_ event: Event) -> Event {
            var event = event
            let limit = event.kind == .request ? maxRequestLength : maxTextLength
            event.text = event.text.map { String($0.prefix(limit)) }
            event.note = event.note.map { String($0.prefix(maxTextLength)) }
            return event
        }
    }
}

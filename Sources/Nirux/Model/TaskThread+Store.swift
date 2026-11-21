import Foundation

extension TaskThread {
    /// One file per task, `<state dir>/projects/<space id>/threads/<workspace id>.jsonl`,
    /// 0600, only appended to; it follows its task into another space. A
    /// thread no open task owns goes six months after it was last written,
    /// and the oldest of them go first past 20 MB a space (`prune`); an
    /// open task's stays, under its own 2 MB.
    enum Store {
        static let folderName = "threads"
        static let keptAfterClose: TimeInterval = 183 * 86_400
        static let maxSpaceBytes = 20_000_000
        /// Appends stop there, but for the close.
        static let maxFileBytes = 2_000_000
        static let maxRequestLength = 65_536
        static let maxTextLength = 8_000
        /// Appends, freezes and prunes, in order, off the main thread.
        static let queue = DispatchQueue(label: "nirux.task-thread")

        static func folder(spaceID: String, stateDirectory: URL) -> URL? {
            SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(folderName, isDirectory: true)
        }

        /// Nil for an id that could name another file: workspace ids are UUIDs.
        static func fileURL(workspaceID: String, spaceID: String, stateDirectory: URL) -> URL? {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard !workspaceID.isEmpty, workspaceID.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            return folder(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent("\(workspaceID).jsonl")
        }

        /// The task's file, in whichever space holds it.
        static func locate(workspaceID: String, stateDirectory: URL) -> URL? {
            let projects = stateDirectory.appendingPathComponent("projects", isDirectory: true)
            let spaces = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
            return spaces.lazy.compactMap { fileURL(workspaceID: workspaceID, spaceID: $0, stateDirectory: stateDirectory) }
                .first { isRegularFile($0) }
        }

        /// The lines it can read, in the order they came.
        static func load(workspaceID: String, stateDirectory: URL) -> [Event] {
            guard let url = locate(workspaceID: workspaceID, stateDirectory: stateDirectory),
                  case .data(let data) = BoardConfigStore.read(url, maxBytes: maxFileBytes + 65_536)
            else { return [] }
            let decoder = JSONDecoder()
            return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(Event.self, from: $0) }
        }

        /// Appends in order what fits, the close always, first moving the
        /// file from another space; returns how many it wrote.
        @discardableResult
        static func append(
            _ events: [Event], workspaceID: String, spaceID: String, stateDirectory: URL
        ) -> Int {
            guard !events.isEmpty, let url = fileURL(workspaceID: workspaceID, spaceID: spaceID, stateDirectory: stateDirectory) else { return 0 }
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !manager.fileExists(atPath: url.path),
                   let elsewhere = locate(workspaceID: workspaceID, stateDirectory: stateDirectory) {
                    try manager.moveItem(at: elsewhere, to: url)
                }
                let descriptor = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
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
            } catch {
                NiruxDebugLog.log("TaskThread: could not append to \(url.path): \(error)")
                return 0
            }
        }

        /// `prune` in every space's folder, a deleted space's too.
        static func pruneAll(keeping open: Set<String>, now: TimeInterval, stateDirectory: URL) {
            let projects = stateDirectory.appendingPathComponent("projects", isDirectory: true)
            for spaceID in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
                prune(spaceID: spaceID, keeping: open, now: now, stateDirectory: stateDirectory)
            }
        }

        /// Removes the threads `open` doesn't list that were last written
        /// six months before `now`, then the oldest of them while they hold
        /// more than `maxSpaceBytes`.
        static func prune(spaceID: String, keeping open: Set<String>, now: TimeInterval, stateDirectory: URL) {
            let manager = FileManager.default
            guard let folder = folder(spaceID: spaceID, stateDirectory: stateDirectory),
                  let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
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
            where file.writtenAt < now - keptAfterClose || total > maxSpaceBytes {
                do {
                    try manager.removeItem(at: file.url)
                    total -= file.size
                } catch {
                    NiruxDebugLog.log("TaskThread: could not remove \(file.url.path): \(error)")
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

        private static func isRegularFile(_ url: URL) -> Bool {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
        }
    }
}

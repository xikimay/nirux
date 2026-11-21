import Foundation

extension TaskThread.Store {
    /// Appends, freezes and prunes, in order, off the main thread.
    static let queue = DispatchQueue(label: "nirux.task-thread")

    private static func store(spaceID: String, stateDirectory: URL) -> Self? {
        folder(spaceID: spaceID, stateDirectory: stateDirectory).map(Self.init(folder:))
    }

    static func folder(spaceID: String, stateDirectory: URL) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent("threads", isDirectory: true)
    }

    static func fileURL(workspaceID: String, spaceID: String, stateDirectory: URL) -> URL? {
        store(spaceID: spaceID, stateDirectory: stateDirectory)?.fileURL(workspaceID: workspaceID)
    }

    /// The task's file, in whichever space holds it.
    static func locate(workspaceID: String, stateDirectory: URL) -> URL? {
        let projects = stateDirectory.appendingPathComponent("projects", isDirectory: true)
        let spaces = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return spaces.lazy.compactMap { fileURL(workspaceID: workspaceID, spaceID: $0, stateDirectory: stateDirectory) }
            .first { isRegularFile($0) }
    }

    /// The lines it can read, in the order they came.
    static func load(workspaceID: String, stateDirectory: URL) -> [TaskThread.Event] {
        guard let url = locate(workspaceID: workspaceID, stateDirectory: stateDirectory) else { return [] }
        return load(from: url)
    }

    @discardableResult
    static func append(_ events: [TaskThread.Event], workspaceID: String, spaceID: String, stateDirectory: URL) -> Int {
        guard let store = store(spaceID: spaceID, stateDirectory: stateDirectory) else { return 0 }
        do {
            return try store.append(events, workspaceID: workspaceID) {
                locate(workspaceID: workspaceID, stateDirectory: stateDirectory)
            }
        } catch {
            NiruxDebugLog.log("TaskThread: could not append \(workspaceID) in \(store.folder.path): \(error)")
            return 0
        }
    }

    static func appendHistory(
        _ events: [TaskThread.Event], workspaceID: String, spaceID: String, keeping open: Set<String>, stateDirectory: URL
    ) {
        guard let store = store(spaceID: spaceID, stateDirectory: stateDirectory) else { return }
        do {
            try store.appendHistory(events, workspaceID: workspaceID, keeping: open, now: Date().timeIntervalSince1970, onPruneError: logPruneError)
        } catch {
            NiruxDebugLog.log("TaskThread: could not append history for \(workspaceID) in \(store.folder.path): \(error)")
        }
    }

    /// `prune` in every space's folder, a deleted space's too.
    static func pruneAll(keeping open: Set<String>, now: TimeInterval, stateDirectory: URL) {
        let projects = stateDirectory.appendingPathComponent("projects", isDirectory: true)
        for spaceID in (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [] {
            prune(spaceID: spaceID, keeping: open, now: now, stateDirectory: stateDirectory)
        }
    }

    static func prune(spaceID: String, keeping open: Set<String>, now: TimeInterval, stateDirectory: URL) {
        store(spaceID: spaceID, stateDirectory: stateDirectory)?.prune(keeping: open, now: now, onError: logPruneError)
    }

    private static func logPruneError(_ url: URL, _ error: Error) {
        NiruxDebugLog.log("TaskThread: could not remove \(url.path): \(error)")
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }
}

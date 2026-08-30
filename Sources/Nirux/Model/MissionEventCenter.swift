import Foundation

/// Watches and drains the explicit mission-event queue using the same
/// rename-aside JSONL pattern as AgentHookCenter.
@MainActor
final class MissionEventCenter {
    static let shared = MissionEventCenter(store: .shared)

    nonisolated static var defaultEventsURL: URL {
        Persistence.stateDirectory.appendingPathComponent("mission-events.jsonl")
    }

    private let store: MissionStore
    private let eventsURL: URL
    private let isEnabled: () -> Bool
    private let initialRetryDelay: TimeInterval
    private let maximumRetryDelay: TimeInterval
    /// Return true only after the event is durably represented to the user.
    var onEvent: ((Mission, MissionEvent) -> Bool)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirFd: Int32 = -1
    private var pendingDrain: DispatchWorkItem?
    private var nextRetryDelay: TimeInterval
    private var started = false

    init(
        store: MissionStore,
        eventsURL: URL = MissionEventCenter.defaultEventsURL,
        initialRetryDelay: TimeInterval = 0.5,
        maximumRetryDelay: TimeInterval = 30,
        isEnabled: @escaping () -> Bool = {
            Persistence.load()?.settings?.missionHandoffsEnabled == true
        }
    ) {
        let retryDelay = max(0.01, initialRetryDelay)
        self.store = store
        self.eventsURL = eventsURL
        self.isEnabled = isEnabled
        self.initialRetryDelay = retryDelay
        self.maximumRetryDelay = max(retryDelay, maximumRetryDelay)
        nextRetryDelay = retryDelay
    }

    func start() {
        guard !started else { return }
        started = true

        let dirPath = eventsURL.deletingLastPathComponent().path
        dirFd = open(dirPath, O_RDONLY | O_DIRECTORY)
        if dirFd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.watchEventsFileIfPresent()
                self?.scheduleDrain()
            }
            source.setCancelHandler { [dirFd] in close(dirFd) }
            source.resume()
            dirSource = source
        } else {
            NSLog("[MissionEvents] cannot watch state dir %@", dirPath)
        }
        watchEventsFileIfPresent()
        drain()
    }

    private func watchEventsFileIfPresent() {
        guard fileSource == nil else { return }
        let fd = open(eventsURL.path, O_RDONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                self.fileSource?.cancel()
                self.fileSource = nil
                return
            }
            self.scheduleDrain()
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        fileSource = source
    }

    private func scheduleDrain(after delay: TimeInterval = 0.15) {
        guard pendingDrain == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingDrain = nil
            self?.drain()
        }
        pendingDrain = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleRetry() {
        let delay = nextRetryDelay
        nextRetryDelay = min(maximumRetryDelay, nextRetryDelay * 2)
        scheduleDrain(after: delay)
    }

    private func resetRetryDelay() {
        nextRetryDelay = initialRetryDelay
    }

    func drain() {
        pendingDrain?.cancel()
        pendingDrain = nil
        guard store.ensureLoaded() else {
            scheduleRetry()
            return
        }
        let aside = eventsURL.deletingPathExtension().appendingPathExtension("processing")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: aside.path), !process(aside, fileManager: fileManager) {
            scheduleRetry()
            return
        }
        do {
            try fileManager.moveItem(at: eventsURL, to: aside)
        } catch {
            resetRetryDelay()
            deliverPendingEvents()
            return
        }
        guard process(aside, fileManager: fileManager) else {
            scheduleRetry()
            return
        }
        resetRetryDelay()
        deliverPendingEvents()
    }

    private func process(_ source: URL, fileManager: FileManager) -> Bool {
        guard let data = try? Data(contentsOf: source) else { return false }
        let decoder = JSONDecoder()
        var persistenceFailed = false
        for line in data.split(separator: 0x0A) {
            guard let incoming = try? decoder.decode(MissionEvent.self, from: Data(line)) else {
                continue
            }
            switch store.process(incoming, enabled: isEnabled()) {
            case .rejected:
                continue
            case .persistenceFailed:
                persistenceFailed = true
            case let .accepted(accepted):
                if let accepted { deliver(accepted) }
            }
        }
        guard !persistenceFailed else { return false }
        do {
            try fileManager.removeItem(at: source)
            return true
        } catch {
            return false
        }
    }

    func deliverPendingEvents() {
        guard store.ensureLoaded(), isEnabled() else { return }
        for pending in store.pendingEvents() {
            deliver(pending)
        }
    }

    private func deliver(_ accepted: MissionStore.AcceptedEvent) {
        guard onEvent?(accepted.mission, accepted.event) == true else { return }
        store.markDelivered(eventID: accepted.event.id)
    }

    func stop() {
        pendingDrain?.cancel()
        pendingDrain = nil
        resetRetryDelay()
        dirSource?.cancel()
        dirSource = nil
        dirFd = -1
        fileSource?.cancel()
        fileSource = nil
        started = false
    }
}

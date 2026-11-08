import Foundation

/// The app's side of `LeadChannel`: watches the requests folder, hands each
/// request to `handler` (the shell, which checks and acts), and writes the
/// answer it gives back, now or once its work ends.
@MainActor
final class LeadRequestCenter {
    static let shared = LeadRequestCenter()

    typealias Handler = @MainActor (LeadChannel.Request, @escaping @MainActor (_ text: String, _ isError: Bool) -> Void) -> Void

    var handler: Handler?
    /// Whether a request comes from this Nirux's own workspace: another
    /// Nirux on the same state directory leaves it to the one that has it.
    var owns: @MainActor (LeadChannel.Request) -> Bool = { _ in true }
    private var source: DispatchSourceFileSystemObject?
    private var pendingDrain: DispatchWorkItem?
    private var stateDirectory: URL?
    /// Requests older than this launch came from terminals of an earlier
    /// one, which quit with it: nobody waits for them.
    private var startedAt: TimeInterval = 0

    /// Starts watching `<state dir>/lead/requests/`, after sweeping what an
    /// earlier run left behind and taking what waits.
    func start(stateDirectory: URL = Persistence.stateDirectory) {
        guard source == nil else { return }
        self.stateDirectory = stateDirectory
        startedAt = Date().timeIntervalSince1970
        LeadChannel.sweep(stateDirectory: stateDirectory)
        let folder = LeadChannel.requestsFolder(stateDirectory: stateDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .rename], queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleDrain() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.source = source
        } else {
            NSLog("[Lead] cannot watch %@", folder.path)
        }
        drain()
    }

    func stop() {
        pendingDrain?.cancel()
        pendingDrain = nil
        source?.cancel()
        source = nil
    }

    private func scheduleDrain() {
        guard pendingDrain == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingDrain = nil
            self?.drain()
        }
        pendingDrain = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// Hands every waiting request over; one nobody handles is answered so.
    func drain() {
        guard let stateDirectory else { return }
        for request in LeadChannel.waitingRequests(stateDirectory: stateDirectory)
        where owns(request) && LeadChannel.claim(request, stateDirectory: stateDirectory) {
            guard request.createdAt >= startedAt else { continue }
            let answer: @MainActor (String, Bool) -> Void = { text, isError in
                LeadChannel.respond(LeadChannel.Response(id: request.id, text: text, isError: isError), stateDirectory: stateDirectory)
            }
            guard let handler else {
                answer("Nirux isn't ready yet: try again in a moment.", true)
                continue
            }
            handler(request, answer)
        }
    }
}

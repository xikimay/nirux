import Foundation

/// A project's merge queue (docs/project-board.md, section 3.6): one per
/// project, owned by the shell, so closing the board doesn't stop it. It
/// runs the queue through a `MergeQueueDriver`, holds the repository's
/// lock while a live queue runs, keeps App Nap from throttling its polls,
/// journals every step and saves the queue after each one. The board's
/// Start opens the confirmation sheet, which starts it.
@MainActor
final class MergeQueueController {
    enum StartRefusal: Error, Equatable {
        case alreadyRunning
        case nothingToQueue
        case invalidEntry(String)
        /// Settings `BoardConfig.problems` refuses: never made by `queueSettings`.
        case invalidSettings([String])
        /// Another project's queue in this Nirux works on the repository.
        case repositoryBusy
        /// Another Nirux runs a queue on the repository.
        case lockedElsewhere
        case noProjectFolder

        var message: String {
            switch self {
            case .alreadyRunning: return "This project’s merge queue is already running."
            case .nothingToQueue: return "Add pull requests to the queue first."
            case .invalidEntry(let problem): return problem
            case .invalidSettings(let problems): return problems.joined(separator: "\n")
            case .repositoryBusy: return "Another project’s merge queue is running on this repository."
            case .lockedElsewhere:
                return "Another Nirux is running a merge queue on this repository (or its lock can’t be taken)."
            case .noProjectFolder: return "This project has no folder for its queue’s files."
            }
        }
    }

    let projectID: String
    let client: any MergeQueueGitHub
    /// Nil for a project id that isn't a plain name.
    let files: MergeQueue.Files?
    private let lockFolder: URL
    private var lock: MergeQueueLock?
    private(set) var driver: MergeQueueDriver?
    /// The last queue as saved: this launch's, or one a quit interrupted.
    private(set) var saved: MergeQueue.SavedQueue?
    /// A queue saved as running whose repository another Nirux locks.
    private(set) var runsElsewhere = false
    private var activity: NSObjectProtocol?
    /// A call just sent, journaled after the notes of the step that sent it.
    private var sentLines: [MergeQueue.Journal.Line] = []
    /// The pull requests the next Start proposes, in order: those added
    /// with "Add to Queue", or left over from the last queue. In memory:
    /// a relaunch proposes the saved queue's.
    private(set) var selection: [Int] = []
    /// The user's order from a confirmation sheet: additions go at the
    /// end, not by number.
    private var isSelectionReordered = false
    /// When the saved queue was last read again for `runsElsewhere`.
    private var savedReadAt: TimeInterval?

    var local: MergeQueueLocalAccess
    var clock = MergeQueueClock()
    /// Whether another project's queue in this Nirux runs on a repository.
    var isRepositoryBusy: (GitHubRepository) -> Bool = { _ in false }
    /// While a queue runs, App Nap mustn't throttle its polls; idle sleep
    /// stays the keep-awake setting's business.
    var beginActivity: () -> NSObjectProtocol? = {
        ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "A merge queue is running")
    }
    var endActivity: (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    /// After every step: the board draws the queue again.
    var onChange: (() -> Void)?

    var isDryRun: Bool { client.isDryRun }
    var engine: MergeQueue.Engine? { driver?.engine }
    var isRunning: Bool { engine?.phase.isActive == true }
    var repository: GitHubRepository? { engine?.settings.gitHubRepository }

    init(
        projectID: String,
        client: any MergeQueueGitHub,
        local: MergeQueueLocalAccess,
        stateDirectory: URL = Persistence.stateDirectory,
        lockFolder: URL = MergeQueueLock.defaultFolder
    ) {
        self.projectID = projectID
        self.client = client
        self.local = local
        self.lockFolder = lockFolder
        files = MergeQueue.Files(projectID: projectID, stateDirectory: stateDirectory, dryRun: client.isDryRun)
        restore()
        selection = leftOver(saved)
    }

    /// Reads the saved queue again, when none runs here: the board asks
    /// whether a queue another Nirux ran is still running.
    func reloadSaved() {
        guard !isRunning else { return }
        runsElsewhere = false
        saved = nil
        restore()
        if selection.isEmpty, !runsElsewhere { selection = leftOver(saved) }
    }

    /// While another Nirux runs the queue, the board asks now and then
    /// (`interval` seconds of `clock`) whether it ended.
    func reloadSavedIfStale(interval: TimeInterval = 30) {
        guard runsElsewhere else { return }
        let now = clock.now()
        if let savedReadAt, now - savedReadAt < interval { return }
        savedReadAt = now
        reloadSaved()
        if !runsElsewhere { onChange?() }
    }

    /// The pull requests a stopped queue didn't merge, in its order.
    private func leftOver(_ saved: MergeQueue.SavedQueue?) -> [Int] {
        guard let saved, !saved.isRunning else { return [] }
        return saved.entries.filter { $0.step != .done }.map(\.number)
    }

    // MARK: The next Start's list

    /// "Add to Queue": by number, oldest first, until the user reorders.
    func addToSelection(_ number: Int) {
        guard !isRunning, !selection.contains(number) else { return }
        selection.append(number)
        if !isSelectionReordered { selection.sort() }
        onChange?()
    }

    func removeFromSelection(_ number: Int) {
        guard !isRunning, selection.contains(number) else { return }
        selection.removeAll { $0 == number }
        onChange?()
    }

    /// The list a sheet confirmed, in its order: the pull requests it left
    /// out leave the list too.
    private func confirmSelection(_ numbers: [Int]) {
        selection = numbers
        isSelectionReordered = numbers != numbers.sorted()
    }

    /// A queue saved as running when Nirux quit never resumes: it reads as
    /// interrupted, unless another Nirux still runs it.
    private func restore() {
        guard let files, let saved = MergeQueue.SavedQueue.load(from: files.state) else { return }
        guard saved.isRunning, !saved.dryRun, BoardConfig.isValidRepository(saved.repository) else { return settle(saved) }
        let parts = saved.repository.split(separator: "/")
        let repository = GitHubRepository(owner: String(parts[0]), name: String(parts[1]))
        // A queue of this Nirux holds the repository: the saved one runs nowhere.
        if isRepositoryBusy(repository) { return settle(saved) }
        // Held while the file is read again and rewritten: a Nirux that
        // ended that queue meanwhile wrote its last state before letting go.
        guard let lock = MergeQueueLock.acquire(repository: repository, folder: lockFolder) else {
            runsElsewhere = true
            self.saved = saved
            return
        }
        settle(MergeQueue.SavedQueue.load(from: files.state) ?? saved)
        Self.waitForFiles()
        lock.release()
    }

    /// A saved queue as the board shows it: one saved as running reads,
    /// and is saved, as interrupted.
    private func settle(_ saved: MergeQueue.SavedQueue) {
        guard saved.isRunning else {
            self.saved = saved
            return
        }
        let interrupted = saved.interrupted()
        self.saved = interrupted
        let note = MergeQueue.Note(number: nil, step: "queue", message: interrupted.stopReason?.message ?? "Interrupted")
        write(lines: [MergeQueue.Journal.line(note, at: clock.date())], saved: interrupted)
    }

    // MARK: Start and Stop

    /// Starts the confirmed list with the settings the confirmation showed.
    /// Returns why not, if it can't.
    @discardableResult
    func start(settings: BoardConfig.QueueSettings, entries: [MergeQueue.ConfirmedEntry]) -> StartRefusal? {
        guard !isRunning else { return .alreadyRunning }
        guard files != nil else { return .noProjectFolder }
        guard !entries.isEmpty else { return .nothingToQueue }
        if let problem = Self.problem(with: entries) { return .invalidEntry(problem) }
        let settingsProblems = Self.problems(with: settings)
        guard settingsProblems.isEmpty else { return .invalidSettings(settingsProblems) }
        guard !isRepositoryBusy(settings.gitHubRepository) else { return .repositoryBusy }
        if !isDryRun {
            // A queue that just ended here lets go of its lock after its
            // last write.
            Self.waitForFiles()
            guard let lock = MergeQueueLock.acquire(repository: settings.gitHubRepository, folder: lockFolder) else {
                return .lockedElsewhere
            }
            self.lock = lock
        }
        runsElsewhere = false
        let driver = MergeQueueDriver(
            engine: MergeQueue.Engine(settings: settings, entries: entries), client: client, local: local, clock: clock
        )
        driver.onUpdate = { [weak self] engine, notes in self?.update(engine, notes: notes) }
        driver.onMutation = { [weak self] mutation, command, result in
            self?.journal(mutation, command: command, result: result)
        }
        self.driver = driver
        confirmSelection(entries.map(\.number))
        activity = beginActivity()
        driver.start()
        return nil
    }

    /// Stops before the next command; a call already sent finishes.
    func stop() {
        driver?.stop()
    }

    /// `queueSettings` only makes valid settings; this checks them again
    /// where they are used: no required check would make every head green.
    static func problems(with settings: BoardConfig.QueueSettings) -> [String] {
        let config = BoardConfig(
            repository: settings.repository,
            baseBranch: settings.baseBranch,
            requiredChecks: settings.requiredChecks,
            postMergeWorkflow: settings.postMergeWorkflow.map { .workflow($0) } ?? .noWorkflow,
            mergeMethod: settings.mergeMethod,
            checksTimeoutMinutes: settings.checksTimeoutMinutes,
            postMergeTimeoutMinutes: settings.postMergeTimeoutMinutes
        )
        var problems = config.problems
        if config.gitHubRepository != settings.gitHubRepository {
            problems.append("The repository and its GitHub name don’t match.")
        }
        return problems
    }

    nonisolated static func problem(with entries: [MergeQueue.ConfirmedEntry]) -> String? {
        guard Set(entries.map(\.number)).count == entries.count else { return "A pull request is in the list twice." }
        for entry in entries {
            guard entry.number > 0 else { return "#\(entry.number) isn’t a pull request number." }
            guard MergeQueue.objectID(entry.head) != nil else { return "#\(entry.number) has no confirmed head commit." }
            guard BoardConfig.isValidBranchName(entry.branch) else {
                return "#\(entry.number)’s branch “\(entry.branch)” isn’t a branch name Nirux reads."
            }
        }
        return nil
    }

    // MARK: Steps

    private func update(_ engine: MergeQueue.Engine, notes: [MergeQueue.Note]) {
        let date = clock.date()
        let saved = MergeQueue.SavedQueue(engine: engine, dryRun: isDryRun, savedAt: date)
        // A poll that changed nothing leaves the file as it is.
        let changed = !saved.isSame(as: self.saved)
        self.saved = saved
        let merged = Set(engine.entries.filter { $0.step == .done }.map(\.number))
        selection.removeAll { merged.contains($0) }
        // The step's notes, then the call it just sent.
        write(lines: notes.map { MergeQueue.Journal.line($0, at: date) } + sentLines, saved: changed ? saved : nil)
        sentLines = []
        if !engine.phase.isActive { finish() }
        onChange?()
    }

    private func finish() {
        // Let go after the last write, on the file queue: another Nirux
        // taking the lock then reads the queue as it ended.
        let lock = self.lock
        self.lock = nil
        Self.writeOffMain { lock?.release() }
        if let activity { endActivity(activity) }
        activity = nil
    }

    private func journal(_ mutation: MergeQueue.Mutation, command: String, result: MergeQueue.MutationResult?) {
        let entry = engine?.currentEntry
        let line = MergeQueue.Journal.line(
            number: entry?.number,
            step: entry.map { MergeQueue.Engine.stepName($0.step) } ?? "queue",
            command: command,
            result: result.map(MergeQueue.Engine.describe)
                ?? (isDryRun ? "handed to the dry run, which doesn’t send it" : "sent, waiting for the answer"),
            at: clock.date()
        )
        if result == nil {
            sentLines.append(line)
        } else {
            write(lines: [line], saved: nil)
        }
    }

    // MARK: Files

    /// The journal and the state are written in order, off the main thread.
    nonisolated private static let fileQueue = DispatchQueue(label: "MergeQueue.files", qos: .utility)

    private func write(lines: [MergeQueue.Journal.Line], saved: MergeQueue.SavedQueue?) {
        guard let files, !lines.isEmpty || saved != nil else { return }
        let journal = MergeQueue.Journal(url: files.journal)
        let stateURL = files.state
        Self.writeOffMain {
            journal.append(lines)
            saved?.save(to: stateURL)
        }
    }

    nonisolated private static func writeOffMain(_ work: @escaping @Sendable () -> Void) {
        fileQueue.async(execute: work)
    }

    /// Returns once everything asked so far is written (tests).
    nonisolated static func waitForFiles() {
        fileQueue.sync {}
    }
}

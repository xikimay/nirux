import Foundation

/// The app's side of a space's bricks (docs/design/knowledge-bricks.md):
/// where they live, what a recheck reads, and the pass that rechecks them.
enum SpaceKnowledge {
    static func store(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> KnowledgeStore? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory).map(KnowledgeStore.init(spaceFolder:))
    }

    static var macOS: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// The pass that reads pages too, trims the uses and drops old sessions.
    static let dailyInterval: TimeInterval = 20 * 3600

    /// What the hook receiver prints for a Claude or agy hook in a terminal
    /// of `environment`'s space, recording the bricks it hands over and the
    /// corrections it sees; nil for nothing.
    static func hookOutput(
        kind: CodingAgent, payload: [String: Any], environment: [String: String], now: TimeInterval,
        stateDirectory: URL = Persistence.stateDirectory
    ) -> Data? {
        let agent: KnowledgeHook.Agent
        switch kind {
        case .claude: agent = .claude
        case .agy: agent = .agy
        case .codex, .gemini, .opencode: return nil
        }
        guard let spaceID = environment["NIRUX_PROFILE_ID"], let store = store(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        let answer = KnowledgeHook.answer(
            agent: agent, payload: payload, store: store, task: environment["NIRUX_WORKSPACE_ID"], now: now, macOS: macOS
        )
        if !answer.uses.isEmpty { KnowledgeUse.append(answer.uses, in: store) }
        return answer.output
    }

    // MARK: Reading a repository

    private static let gitEnvironment = GitDetect.readOnlyEnvironment.merging(["GIT_NO_LAZY_FETCH": "1"]) { _, new in new }
    static let maxFileBytes = 2 << 20

    private static func git(_ arguments: [String], in folder: String, maxBytes: Int = 1 << 20) -> BoundedProcessResult? {
        BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: ["--literal-pathspecs"] + arguments,
            currentDirectoryURL: URL(fileURLWithPath: folder), environment: gitEnvironment, timeout: 15, captureStandardError: true,
            maxStandardOutputBytes: maxBytes
        )
    }

    /// The tip of the base branch as last fetched: origin's default branch,
    /// else the checkout's HEAD for a repository without one.
    static func baseTip(folder: String) -> String? {
        for ref in ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master", "HEAD"] {
            guard let result = git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], in: folder), result.terminationStatus == 0 else { continue }
            let sha = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if sha.count == 40 { return sha }
        }
        return nil
    }

    /// For a Codex launch in `launchDirectory`: when the space serves bricks
    /// about files its branch already changes, a file of the task's own
    /// holding the brief (`withBrief`) then those bricks, as Codex's
    /// `developer_instructions`; nil otherwise. Codex opens files through
    /// its shell, where Nirux doesn't see them: it gets its bricks at its
    /// start (docs/design/knowledge-bricks.md).
    static func codexInstructions(
        spaceID: String, task: String, launchDirectory: String, withBrief: Bool,
        now: TimeInterval = Date().timeIntervalSince1970, stateDirectory: URL = Persistence.stateDirectory
    ) -> String? {
        guard let store = store(spaceID: spaceID, stateDirectory: stateDirectory),
              let served = ServedKnowledge.read(store.servedURL), !served.bricks.isEmpty,
              let repository = KnowledgeLocation.repository(of: (launchDirectory as NSString).appendingPathComponent("launch"))
        else { return nil }
        let picked = KnowledgeDelivery.pick(served, anchor: repository.anchor, paths: changedFiles(in: launchDirectory), now: now, macOS: macOS)
        guard !picked.isEmpty else { return nil }
        var text = KnowledgeDelivery.text(picked, about: KnowledgeDelivery.branchFiles)
        if withBrief, let briefURL = SpaceBrief.briefURL(spaceID: spaceID, stateDirectory: stateDirectory),
           let brief = SpaceBrief.readBrief(at: briefURL).flatMap(SpaceBrief.body(of:)) {
            text = SpaceBrief.injectedText(body: brief, briefPath: briefURL.path) + "\n\n" + text
        }
        let file = store.folder.appendingPathComponent("codex/\(task).toml")
        do {
            try KnowledgeStore.writePrivately(Data(SpaceBrief.tomlBasicString(text).utf8), to: file)
        } catch {
            NiruxDebugLog.log("SpaceKnowledge: could not write Codex's instructions: \(error)")
            return nil
        }
        KnowledgeUse.append(picked.map { KnowledgeUse(time: now, brick: $0.id, kind: .got, task: task, agent: "codex") }, in: store)
        return file.path
    }

    /// The files the checkout holding `folder` changes from where its branch
    /// left the base branch, committed or not, new ones included; relative
    /// to its top. Bounded: a launch waits on it.
    static func changedFiles(in folder: String) -> [String] {
        guard let top = git(["rev-parse", "--show-toplevel"], in: folder, maxBytes: 4096), top.terminationStatus == 0 else { return [] }
        let root = String(decoding: top.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tip = baseTip(folder: root),
              let base = git(["merge-base", "HEAD", tip], in: root, maxBytes: 4096), base.terminationStatus == 0
        else { return [] }
        let fork = String(decoding: base.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let lists = [["diff", "--name-only", "-z", fork], ["ls-files", "-z", "--others", "--exclude-standard"]]
        return lists.flatMap { arguments -> [String] in
            guard let result = git(arguments, in: root), result.terminationStatus == 0 else { return [] }
            return result.standardOutput.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// What a check reads of the repository whose main checkout is `folder`,
    /// at `tip`: git's objects only, never the working tree.
    static func repositorySource(folder: String, tip: String, readsPages: Bool) -> KnowledgeSource {
        KnowledgeSource(
            tip: tip,
            file: { path in
                guard let listed = git(["ls-tree", "--name-only", tip, "--", path], in: folder), listed.terminationStatus == 0 else {
                    return .unknown("git couldn’t list \(path).")
                }
                guard !listed.standardOutput.isEmpty else { return .missing }
                guard let blob = git(["cat-file", "-p", "\(tip):\(path)"], in: folder, maxBytes: maxFileBytes), blob.terminationStatus == 0 else {
                    return .unknown("git couldn’t read \(path).")
                }
                return .data(blob.standardOutput)
            },
            hasPullRequest: { number in
                let merged = git([
                    "log", "-1", "--format=%H", "-E", "--grep=^Merge pull request #\(number)( |$)", "--grep=\\(#\(number)\\)$", tip
                ], in: folder)
                guard let merged, merged.terminationStatus == 0 else { return nil }
                return !merged.standardOutput.isEmpty
            },
            hasCommit: { sha in
                switch git(["merge-base", "--is-ancestor", sha, tip], in: folder)?.terminationStatus {
                case 0?: return true
                case 1?: return false
                default:
                    // An unknown commit isn't on the branch.
                    return git(["cat-file", "-e", sha + "^{commit}"], in: folder)?.terminationStatus == 128 ? false : nil
                }
            },
            page: readsPages ? page : nil
        )
    }

    /// What a check reads of a folder: its files as they are.
    static func folderSource(path root: String, readsPages: Bool) -> KnowledgeSource {
        KnowledgeSource(
            tip: nil,
            file: { path in
                switch RegularFileRead.read(URL(fileURLWithPath: root).appendingPathComponent(path), maxBytes: maxFileBytes) {
                case .missing: return .missing
                case .data(let data): return .data(data)
                case .notARegularFile:
                    var isFolder: ObjCBool = false
                    return FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &isFolder) && isFolder.boolValue
                        ? .data(Data()) : .unknown("\(path) isn’t a regular file.")
                case .tooLarge, .unreadableBytes: return .unknown("\(path) can’t be read.")
                }
            },
            hasPullRequest: { _ in nil }, hasCommit: { _ in nil },
            page: readsPages ? page : nil
        )
    }

    /// A page as fetched now: gone on 404 or 410, unknown on anything else
    /// that isn't a page.
    @Sendable static func page(_ address: String) -> KnowledgeSource.Read {
        guard let url = URL(string: address), url.scheme == "https" else { return .unknown("Not an https page.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Nirux", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        let answer = PageAnswer(.unknown("\(url.host ?? address) didn’t answer."))
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let status = (response as? HTTPURLResponse)?.statusCode else { return }
            if [404, 410].contains(status) { return answer.set(.missing) }
            guard (200..<300).contains(status), let data, data.count <= maxFileBytes else {
                return answer.set(.unknown("\(url.host ?? address) answered \(status)."))
            }
            answer.set(.data(data))
        }
        task.resume()
        if done.wait(timeout: .now() + 25) == .timedOut { task.cancel() }
        return answer.value
    }

    private final class PageAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var read: KnowledgeSource.Read

        init(_ read: KnowledgeSource.Read) { self.read = read }

        func set(_ read: KnowledgeSource.Read) { lock.withLock { self.read = read } }
        var value: KnowledgeSource.Read { lock.withLock { read } }
    }

    // MARK: The pass

    struct Pass: Equatable, Sendable {
        var closed: [String] = []
        var suspected: [String] = []
    }

    /// Makes suspect the bricks a correction followed since they were last
    /// confirmed; checks each standing brick again where its base branch
    /// moved since its last check, every one once a day (pages then too);
    /// writes the state when it changed, and what agents get. With the
    /// space's switch off (`serves`), only takes back what agents get.
    @discardableResult
    static func recheck(
        spaceID: String, serves: Bool, now: TimeInterval = Date().timeIntervalSince1970,
        stateDirectory: URL = Persistence.stateDirectory
    ) -> Pass {
        guard let store = store(spaceID: spaceID, stateDirectory: stateDirectory),
              FileManager.default.fileExists(atPath: store.folder.path)
        else { return Pass() }
        guard serves else {
            try? serve(KnowledgeStore.Loaded(), in: store, serves: false, now: now)
            return Pass()
        }
        var loaded = store.load()
        guard loaded.readOnlyReason == nil else { return Pass() }
        let before = loaded.state
        var pass = Pass()
        for use in KnowledgeUse.load(in: store) where use.kind == .corrected {
            guard let brick = loaded.bricks[use.brick], use.time > (loaded.state(of: use.brick).reconfirmedAt ?? 0) else { continue }
            if loaded.suspect(use.brick, because: "You wrote about “\(brick.subject)” in a task that had received it.", now: now) {
                pass.suspected.append(use.brick)
            }
        }
        let daily = now - (loaded.state.dailyCheckAt ?? 0) >= dailyInterval
        let standing = loaded.ordered.filter { loaded.state(of: $0.id).closedAt == nil }
        for (key, bricks) in Dictionary(grouping: standing, by: \.brick.scope.anchor) {
            guard let anchor = anchor(key: key) else { continue }
            let source: KnowledgeSource
            switch anchor.kind {
            case .gitRepository:
                guard let folder = anchor.folder, let tip = baseTip(folder: folder) else { continue }
                guard daily || loaded.state.checkedTips[key] != tip else { continue }
                source = repositorySource(folder: folder, tip: tip, readsPages: daily)
            case .folder(let path):
                guard daily else { continue }
                source = folderSource(path: path, readsPages: true)
            case .unknown:
                continue
            }
            let results = Dictionary(uniqueKeysWithValues: bricks.map { ($0.id, $0.brick.check(in: source)) })
            pass.closed += loaded.record(results, tip: source.tip, now: now)
            if let tip = source.tip { loaded.state.checkedTips[key] = tip }
        }
        if daily {
            loaded.state.dailyCheckAt = now
            KnowledgeUse.trim(in: store, now: now)
            store.removeSessions(olderThan: 7, now: now)
        }
        do {
            if loaded.state != before { try store.save(loaded.state, now: now) }
            try serve(loaded, in: store, serves: serves, now: now)
        } catch {
            NiruxDebugLog.log("SpaceKnowledge: could not save \(spaceID)'s knowledge: \(error)")
        }
        return pass
    }

    /// Why `brick`'s proofs don't all hold now, at the base branch's tip
    /// (pages read too), or nil: no brick without a proof.
    static func proofProblem(of brick: KnowledgeBrick, anchor: SpaceAnchor, now: TimeInterval) -> String? {
        let source: KnowledgeSource
        switch anchor.kind {
        case .gitRepository:
            guard let folder = anchor.folder, let tip = baseTip(folder: folder) else {
                return "Nirux can’t read \(anchor.name)’s base branch to check the proofs."
            }
            source = repositorySource(folder: folder, tip: tip, readsPages: true)
        case .folder(let path):
            source = folderSource(path: path, readsPages: true)
        case .unknown:
            return "Nirux can’t check proofs in this repository."
        }
        for (proof, check) in zip(brick.proofs, brick.check(in: source)) {
            switch check {
            case .holds, .skipped: continue
            case .fails(let why): return "Nirux checked \(proof.label): \(why) A brick needs proofs that hold now."
            case .unknown(let why): return "Nirux couldn’t check \(proof.label): \(why) Try again later."
            }
        }
        for case .said(_, let day) in brick.proofs {
            guard let date = dayFormatter.date(from: day), date.timeIntervalSince1970 <= now else {
                return "A said proof’s day (\(day)) must be a past day."
            }
        }
        return nil
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The repository or folder a brick's scope names, from its key.
    static func anchor(key: String) -> SpaceAnchor? {
        if key.hasPrefix("git:") { return .repository(commonDir: String(key.dropFirst(4)), topLevel: nil) }
        if key.hasPrefix("folder:") { return .folder(String(key.dropFirst(7))) }
        return nil
    }

    /// Writes what agents get from `loaded`, unless it says so already.
    static func serve(_ loaded: KnowledgeStore.Loaded, in store: KnowledgeStore, serves: Bool, now: TimeInterval) throws {
        let served = serves ? ServedKnowledge.compile(loaded, now: now, macOS: macOS) : nil
        let current = ServedKnowledge.read(store.servedURL)
        guard current != served, !(current == nil && served?.bricks.isEmpty != false) else { return }
        try store.writeServed(served)
    }
}

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
    /// Tasks a correction followed in, since the brick was last confirmed,
    /// that stop serving it.
    static let correctionsToSuspect = 2

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
            agent: agent, payload: payload, store: store, task: environment["NIRUX_WORKSPACE_ID"], now: now, macOS: macOS,
            typedByNirux: isTypedByNirux
        )
        if !answer.uses.isEmpty { KnowledgeUse.append(answer.uses, in: store) }
        return answer.output
    }

    /// The prompts Nirux types into an agent: a Mission's or a restarted
    /// Lead's line, a pull request round (CI, conflict, review feedback).
    static func isTypedByNirux(_ prompt: String) -> Bool {
        prompt.hasPrefix("[Nirux") || prompt.hasPrefix("CI failed on PR #") || prompt.hasPrefix("/receiving-code-review ")
            || prompt.range(of: #"^PR #\d+ conflicts with "#, options: .regularExpression) != nil
    }

    // MARK: Reading a repository

    private static let gitEnvironment = GitDetect.readOnlyEnvironment.merging(["GIT_NO_LAZY_FETCH": "1"]) { _, new in new }
    static let maxFileBytes = 2 << 20

    /// git in `folder`, or on the repository whose git dir is `gitDir`:
    /// a check reads objects only, a bare repository's too.
    /// How long one git call may take: every caller runs off the main thread.
    static let gitTimeout: TimeInterval = 15

    private static func git(
        _ arguments: [String], in folder: String, gitDir: String? = nil, maxBytes: Int = 1 << 20, timeout: TimeInterval = gitTimeout
    ) -> BoundedProcessResult? {
        BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: (gitDir.map { ["--git-dir=" + $0] } ?? []) + ["--literal-pathspecs"] + arguments,
            currentDirectoryURL: URL(fileURLWithPath: gitDir ?? folder), environment: gitEnvironment, timeout: timeout, captureStandardError: true,
            maxStandardOutputBytes: maxBytes
        )
    }

    /// The tip of the base branch as last fetched: origin's default branch,
    /// else the local main or master. Never a checkout's HEAD, which follows
    /// whatever branch it is on; a bare repository's HEAD names its default.
    static func baseTip(gitDir: String, timeout: TimeInterval = gitTimeout) -> String? {
        let refs = ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        guard let listed = git(["for-each-ref", "--format=%(refname) %(objectname)"] + refs, in: gitDir, gitDir: gitDir, timeout: timeout),
              listed.terminationStatus == 0
        else { return nil }
        let tips = Dictionary(String(decoding: listed.standardOutput, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[1].count == 40 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { first, _ in first })
        if let tip = refs.lazy.compactMap({ tips[$0] }).first { return tip }
        guard let bare = git(["rev-parse", "--is-bare-repository", "--verify", "--quiet", "HEAD^{commit}"], in: gitDir, gitDir: gitDir, timeout: timeout),
              bare.terminationStatus == 0
        else { return nil }
        let answer = String(decoding: bare.standardOutput, as: UTF8.self).split(separator: "\n").map(String.init)
        return answer.count == 2 && answer[0] == "true" && answer[1].count == 40 ? answer[1] : nil
    }

    /// Where a Codex launch of `task` finds its instructions.
    static func codexFile(in store: KnowledgeStore, task: String) -> URL {
        store.folder.appendingPathComponent("codex/\(task).toml")
    }

    /// The space's brief as Codex's instructions get it ("" for none).
    static func codexBrief(in store: KnowledgeStore) -> String {
        let briefURL = store.folder.deletingLastPathComponent().appendingPathComponent("brief.md")
        return SpaceBrief.readBrief(at: briefURL).flatMap(SpaceBrief.body(of:)).map { SpaceBrief.injectedText(body: $0, briefPath: briefURL.path) } ?? ""
    }

    /// Writes Codex's instructions for a launch of `task` in `launchDirectory`:
    /// the brief (`withBrief`), then the served bricks about the files its
    /// branch already changes, if any. Codex opens files through its shell,
    /// where Nirux doesn't see them: it gets its bricks at its start
    /// (docs/design/knowledge-bricks.md). Runs git: never on the main
    /// thread. Returns the bricks it gave.
    @discardableResult
    static func writeCodexInstructions(
        spaceID: String, task: String, launchDirectory: String, withBrief: Bool, gitTimeout: TimeInterval = SpaceKnowledge.gitTimeout,
        now: TimeInterval = Date().timeIntervalSince1970, stateDirectory: URL = Persistence.stateDirectory
    ) -> [String] {
        guard let store = store(spaceID: spaceID, stateDirectory: stateDirectory) else { return [] }
        var picked: [ServedKnowledge.Brick] = []
        if let served = ServedKnowledge.read(store.servedURL),
           let repository = KnowledgeLocation.repository(of: (launchDirectory as NSString).appendingPathComponent("launch")),
           served.bricks.contains(where: { $0.anchor == repository.anchor }) {
            let changed = changedFiles(in: launchDirectory, timeout: gitTimeout)
            picked = KnowledgeDelivery.pick(served, anchor: repository.anchor, paths: changed, now: now, macOS: macOS)
        }
        let brief = withBrief ? codexBrief(in: store) : ""
        let bricks = picked.isEmpty ? "" : KnowledgeDelivery.text(picked, about: KnowledgeDelivery.branchFiles)
        let text = [brief, bricks].filter { !$0.isEmpty }.joined(separator: "\n\n")
        do {
            try KnowledgeStore.writePrivately(Data(SpaceBrief.tomlBasicString(text).utf8), to: codexFile(in: store, task: task))
        } catch {
            NiruxDebugLog.log("SpaceKnowledge: could not write Codex's instructions: \(error)")
            return []
        }
        if !picked.isEmpty {
            KnowledgeUse.append(picked.map { KnowledgeUse(time: now, brick: $0.id, kind: .got, task: task, agent: "codex") }, in: store)
        }
        return picked.map(\.id)
    }

    /// The files the checkout holding `folder` changes from where its branch
    /// left the base branch, committed or not, new ones included; relative
    /// to its top. Runs off the main thread: a slow git (a loaded machine,
    /// a busy volume) gets the time any git read here gets.
    static func changedFiles(in folder: String, timeout: TimeInterval = gitTimeout) -> [String] {
        func output(_ arguments: [String], in folder: String, gitDir: String? = nil) -> Data? {
            guard let result = git(arguments, in: folder, gitDir: gitDir, timeout: timeout), result.terminationStatus == 0 else { return nil }
            return result.standardOutput
        }
        func line(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
        guard let paths = line(output(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"], in: folder))?
                .components(separatedBy: "\n"), paths.count == 2,
              let tip = baseTip(gitDir: paths[1], timeout: timeout),
              let fork = line(output(["merge-base", "HEAD", tip], in: paths[0]))
        else { return [] }
        let lists = [["diff", "--name-only", "-z", fork], ["ls-files", "-z", "--others", "--exclude-standard"]]
        return lists.flatMap { arguments -> [String] in
            (output(arguments, in: paths[0]) ?? Data()).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        }
    }

    /// What a check reads of the repository whose git dir is `gitDir`, at
    /// `tip`: git's objects only, never a working tree.
    static func repositorySource(gitDir: String, tip: String, readsPages: Bool) -> KnowledgeSource {
        @Sendable func run(_ arguments: [String], maxBytes: Int = 1 << 20) -> BoundedProcessResult? {
            git(arguments, in: gitDir, gitDir: gitDir, maxBytes: maxBytes)
        }
        return KnowledgeSource(
            tip: tip,
            file: { path in
                guard let listed = run(["ls-tree", "--name-only", tip, "--", path]), listed.terminationStatus == 0 else {
                    return .unknown("git couldn’t list \(path).")
                }
                guard !listed.standardOutput.isEmpty else { return .missing }
                guard let blob = run(["cat-file", "-p", "\(tip):\(path)"], maxBytes: maxFileBytes), blob.terminationStatus == 0 else {
                    return .unknown("git couldn’t read \(path).")
                }
                return .data(blob.standardOutput)
            },
            hasPullRequest: { number in
                // Merged alone, squashed, or through a merge train.
                let merged = run([
                    "log", "-1", "--format=%H", "-E", "--grep=^Merge pull request #\(number)( |$)", "--grep=\\(#\(number)\\)$",
                    "--grep=^Merge #\(number) \\(", tip
                ])
                guard let merged, merged.terminationStatus == 0 else { return nil }
                return !merged.standardOutput.isEmpty
            },
            hasCommit: { sha in
                switch run(["merge-base", "--is-ancestor", sha, tip])?.terminationStatus {
                case 0?: return true
                case 1?: return false
                default:
                    // Missing from the store, it isn't on the branch; any other
                    // error (git exits 128 for all) says nothing.
                    return run(["rev-parse", "--verify", "--quiet", sha + "^{commit}"])?.terminationStatus == 1 ? false : nil
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
        /// Failing since this pass.
        var failing: [String] = []
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
        // One correction, or one agent's flag saying a brick is wrong, is
        // recorded and shown on it; such signals from two tasks since it was
        // last confirmed stop serving it.
        // An agent's flag counts from a task that had received the brick.
        let uses = KnowledgeUse.load(in: store)
        let received = Set(uses.filter { $0.kind == .got }.map { "\($0.brick)\n\($0.task ?? "")" })
        let signals = uses.filter { $0.kind == .corrected }.map { (brick: $0.brick, time: $0.time, task: $0.task, byUser: true) }
            + KnowledgeFlag.load(in: store).filter { $0.faultsItsBrick && received.contains("\($0.brick ?? "")\n\($0.task ?? "")") }
                .map { (brick: $0.brick ?? "", time: $0.time, task: $0.task, byUser: false) }
        for (id, signals) in Dictionary(grouping: signals, by: \.brick).sorted(by: { $0.key < $1.key }) {
            guard let brick = loaded.bricks[id] else { continue }
            let since = loaded.state(of: id).reconfirmedAt ?? 0
            let recent = signals.filter { $0.time > since }
            let tasks = Set(recent.map { $0.task ?? "" })
            // Agents alone may share one misreading (a Lead and its task, one
            // CI failure in a train): they need one task more.
            let needed = recent.contains(where: \.byUser) ? correctionsToSuspect : correctionsToSuspect + 1
            guard tasks.count >= needed else { continue }
            let who = Set(recent.map(\.byUser)).count == 2 ? "You and agents" : recent[0].byUser ? "You" : "Agents"
            if loaded.suspect(id, because: "\(who) said “\(brick.subject)” was wrong in \(tasks.count) tasks that had received it.", now: now) {
                pass.suspected.append(id)
            }
        }
        let housekeeping = now - (loaded.state.dailyCheckAt ?? 0) >= dailyInterval
        let standing = loaded.ordered.filter { loaded.state(of: $0.id).closedAt == nil }
        for (key, bricks) in Dictionary(grouping: standing, by: \.brick.scope.anchor) {
            guard let anchor = anchor(key: key) else { continue }
            let daily = now - (loaded.state.dailyChecks?[key] ?? 0) >= dailyInterval
            let source: KnowledgeSource
            switch anchor.kind {
            case .gitRepository(let gitDir):
                guard let tip = baseTip(gitDir: gitDir) else { continue }
                guard daily || loaded.state.checkedTips[key] != tip else { continue }
                source = repositorySource(gitDir: gitDir, tip: tip, readsPages: daily)
            case .folder(let path):
                guard daily else { continue }
                source = folderSource(path: path, readsPages: true)
            case .unknown:
                continue
            }
            let results = Dictionary(uniqueKeysWithValues: bricks.map { ($0.id, $0.brick.check(in: source)) })
            let wasFailing = Set(bricks.map(\.id).filter { loaded.state(of: $0).failedAt != nil })
            pass.closed += loaded.record(results, tip: source.tip, now: now)
            pass.failing += bricks.map(\.id).filter { !wasFailing.contains($0) && loaded.state(of: $0).failedAt != nil && loaded.state(of: $0).closedAt == nil }
            // A check git or the network didn't answer is tried again at the next pass.
            let decided = results.values.allSatisfy { checks in !checks.contains { if case .unknown = $0 { return true } else { return false } } }
            guard decided else { continue }
            if let tip = source.tip { loaded.state.checkedTips[key] = tip }
            if daily { loaded.state.dailyChecks = (loaded.state.dailyChecks ?? [:]).merging([key: now]) { $1 } }
        }
        if housekeeping {
            loaded.state.dailyCheckAt = now
            KnowledgeUse.trim(in: store, now: now)
            KnowledgeFlag.trim(in: store, now: now)
            // Dismissals of flags that aged out go with them, once the file read.
            if let live = KnowledgeFlag.loadIfReadable(in: store).map({ Set($0.map(\.id)) }) {
                loaded.state.dismissedFlags = loaded.state.dismissedFlags.map { $0.filter(live.contains) }
            }
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

    /// `brick` with each commit proof's SHA in full, as the repository of
    /// `anchor` resolves it; one it can't resolve stays as given (its check
    /// then refuses it).
    static func resolvingCommits(of brick: KnowledgeBrick, anchor: SpaceAnchor) -> KnowledgeBrick {
        guard case .gitRepository(let gitDir) = anchor.kind else { return brick }
        var resolved = brick
        resolved.proofs = brick.proofs.map { proof in
            guard case .commit(let sha) = proof,
                  let result = git(["rev-parse", "--verify", "--quiet", sha + "^{commit}"], in: gitDir, gitDir: gitDir), result.terminationStatus == 0
            else { return proof }
            let full = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return full.count == 40 ? .commit(full) : proof
        }
        return resolved
    }

    /// Why `brick`'s proofs don't all hold now, at the base branch's tip
    /// (pages read too), or nil: no brick without a proof.
    static func proofProblem(of brick: KnowledgeBrick, anchor: SpaceAnchor, now: TimeInterval) -> String? {
        let source: KnowledgeSource
        switch anchor.kind {
        case .gitRepository(let gitDir):
            guard let tip = baseTip(gitDir: gitDir) else {
                return "Nirux finds no base branch in \(anchor.name) to check the proofs at: origin’s default branch, or main or master."
            }
            source = repositorySource(gitDir: gitDir, tip: tip, readsPages: true)
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
    /// A Codex column restarted replays its launch, which names its file:
    /// what it was given then goes back to the brief alone.
    static func serve(_ loaded: KnowledgeStore.Loaded, in store: KnowledgeStore, serves: Bool, now: TimeInterval) throws {
        let served = serves ? ServedKnowledge.compile(loaded, now: now, macOS: macOS) : nil
        let current = ServedKnowledge.read(store.servedURL)
        guard current != served, !(current == nil && served?.bricks.isEmpty != false) else { return }
        try store.writeServed(served)
        let codex = store.folder.appendingPathComponent("codex")
        let brief = codexBrief(in: store)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: codex.path)) ?? [] where name.hasSuffix(".toml") {
            try? KnowledgeStore.writePrivately(Data(SpaceBrief.tomlBasicString(brief).utf8), to: codex.appendingPathComponent(name))
        }
    }
}

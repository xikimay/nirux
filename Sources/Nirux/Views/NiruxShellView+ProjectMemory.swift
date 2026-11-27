import AppKit

// MARK: - Space Memory (Space Settings › Memory; ⌘P › Space Memory…)

extension NiruxShellView {
    /// What a Project Memory read needs, kept for the reads after a write.
    struct ProjectMemoryContext: Sendable {
        let folder: String
        let brief: URL?
        let spaceID: String
        let home: String
        let environment: [String: String]
        let managed: ProjectMemory.ManagedFolders
    }

    /// Which item to select once a write is read back.
    enum ProjectMemorySelection: Sendable {
        case memory(fileName: String)
        case rule(text: String)
        case missingFile(fileName: String)
        case brick(id: String)
        case none

        /// The item a write acts on, kept selected when it fails.
        init(_ target: ProjectMemory.Target) {
            switch target {
            case .memory(let memory, _): self = .memory(fileName: memory.fileName)
            case .briefRule(let rule, _): self = .rule(text: rule.text)
            case .missingFile(let line, _): self = .missingFile(fileName: line.fileName)
            }
        }
    }

    /// Space Settings on its Memory tab, for the active space or the one
    /// whose menu was used.
    func showProjectMemory(profileID: String? = nil) {
        showSpaceSettings(profileID: profileID ?? activeProfileID, tab: .memory)
    }

    /// Fills the Memory tab: what agents know about the repository of the
    /// space's workspace (see `projectMemoryWorkspace`), else of its default
    /// repository or folder. The workspace's own folder decides, not where
    /// its focused terminal has `cd`'d.
    func loadProjectMemoryTab(spaceID: String) {
        guard let settings = spaceSettings, settings.spaceID == spaceID else { return }
        let workspace = projectMemoryWorkspace(inProject: spaceID)
        guard let folder = workspace?.cwd ?? profiles.first(where: { $0.id == spaceID })?.defaultFolder else {
            settings.showMemoryPlaceholder(
                "Open a workspace in this space, or add a repository in General, to see what agents know."
            )
            return
        }
        let context = ProjectMemoryContext(
            folder: folder,
            brief: SpaceBrief.briefURL(spaceID: spaceID),
            spaceID: spaceID,
            home: sideEffects.homeDirectory(),
            environment: ProcessInfo.processInfo.environment,
            managed: sideEffects.claudeManagedSettings()
        )
        // A read that hangs (a stalled network volume) never blocks the
        // next request; only the latest one shows.
        projectMemoryRequest += 1
        let request = projectMemoryRequest
        Self.readProjectMemory(context) { [weak self, weak workspace] model in
            guard let self, request == projectMemoryRequest else { return }
            presentProjectMemory(model, context: context, workspace: workspace, spaceID: spaceID)
        }
    }

    /// From a project's menu: its active workspace when it is the active
    /// project, else its first one.
    func projectMemoryWorkspace(inProject profileID: String) -> WorkspaceState? {
        if let active = activeWorkspace, active.profileID == profileID, !active.isClosing { return active }
        return projectWorkspaces(of: profileID).first
    }

    private func presentProjectMemory(
        _ model: ProjectMemoryPanel.Model, context: ProjectMemoryContext, workspace: WorkspaceState?, spaceID: String
    ) {
        guard let settings = spaceSettings, settings.spaceID == spaceID else { return }
        settings.hideMemoryPlaceholder()
        if projectMemoryPanel == nil { projectMemoryPanel = ProjectMemoryPanel() }
        settings.memoryPanel = projectMemoryPanel
        projectMemoryPanel?.show(
            in: settings.memoryHost, model: model,
            actions: projectMemoryActions(context: context, workspace: workspace, spaceID: spaceID)
        )
    }

    // MARK: - Actions

    private func projectMemoryActions(
        context: ProjectMemoryContext, workspace: WorkspaceState?, spaceID: String
    ) -> ProjectMemoryPanel.Actions {
        let trash = sideEffects.trash
        var actions = ProjectMemoryPanel.Actions()
        // An item's file opens in the editor of the workspace it was read
        // for, brought forward, as the space brief opens in the
        // workspace's.
        actions.open = { [weak self, weak workspace] url, line in
            guard let self else { return }
            // In front of Space Settings, which stays open behind it.
            window?.makeKeyAndOrderFront(nil)
            let target = workspace.flatMap { workspace in
                workspace.isClosing ? nil : workspaces.firstIndex { $0 === workspace }
            }
            if let target, workspaces[target] !== activeWorkspace { switchToWorkspace(target) }
            openInEditorColumn(path: url.path, line: line, in: target.map { workspaces[$0] })
        }
        actions.confirm = { [weak self] alert in self?.runModal(alert) == .alertFirstButtonReturn }
        let limit = SpaceBrief.maxCharacters
        actions.move = { [weak self] target, scope in
            guard let self, !briefHasUnsavedText() else { return false }
            switch (target, scope) {
            case (.memory(let memory, let directory), .always):
                guard let brief = ensureProjectBrief(spaceID: spaceID) else { return false }
                return writeProjectMemory(context, keeping: .init(target)) {
                    .rule(text: try ProjectMemory.moveMemoryToRule(memory, in: directory, to: brief, maxCharacters: limit, trash: trash))
                }
            case (.briefRule(let rule, let brief), .whenRelevant):
                guard let directory = projectMemoryPanel?.model?.location.directory else { return false }
                return writeProjectMemory(context, keeping: .init(target)) {
                    .memory(fileName: try ProjectMemory.moveRuleToMemory(rule, from: brief, to: directory))
                }
            default:
                return false
            }
        }
        actions.save = { [weak self] target, text in
            guard let self else { return false }
            if case .briefRule = target, briefHasUnsavedText() { return false }
            switch target {
            case .memory(let memory, let directory):
                return writeProjectMemory(context, keeping: .init(target)) {
                    try ProjectMemory.replaceMemoryText(fileName: memory.fileName, in: directory, expected: memory.body, with: text)
                    return .memory(fileName: memory.fileName)
                }
            case .briefRule(let rule, let brief):
                return writeProjectMemory(context, keeping: .init(target)) {
                    try ProjectMemory.replaceRule(rule, in: brief, with: text, maxCharacters: limit)
                    return .rule(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case .missingFile:
                return false
            }
        }
        actions.add = { [weak self] item in
            guard let self else { return false }
            if item.scope == .always {
                guard !briefHasUnsavedText() else { return false }
                guard let brief = ensureProjectBrief(spaceID: spaceID) else { return false }
                let text = "**\(item.title)** \(item.text)"
                return writeProjectMemory(context) {
                    try ProjectMemory.appendRule(text, to: brief, maxCharacters: limit)
                    return .rule(text: text)
                }
            }
            guard let directory = projectMemoryPanel?.model?.location.directory else { return false }
            return writeProjectMemory(context) {
                .memory(fileName: try ProjectMemory.addMemory(
                    title: item.title, description: item.description, text: item.text, type: item.type, in: directory
                ))
            }
        }
        actions.delete = { [weak self] target in
            guard let self else { return false }
            if case .briefRule = target, briefHasUnsavedText() { return false }
            switch target {
            case .memory(let memory, let directory):
                return writeProjectMemory(context, keeping: .init(target)) {
                    try ProjectMemory.deleteMemory(fileName: memory.fileName, in: directory, trash: trash)
                    return .none
                }
            case .missingFile(let line, let directory):
                return writeProjectMemory(context, keeping: .init(target)) {
                    // Back since the panel read it: its line stays.
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent(line.fileName).path) {
                        throw ProjectMemory.WriteError.changed(line.fileName)
                    }
                    try ProjectMemory.removeIndexLines(of: line.fileName, in: directory)
                    return .none
                }
            case .briefRule(let rule, let brief):
                return writeProjectMemory(context, keeping: .init(target)) {
                    try ProjectMemory.replaceRule(rule, in: brief, with: nil)
                    return .none
                }
            }
        }
        actions.brick = { [weak self] id, action in
            guard let self else { return false }
            return writeBrick(context, id: id, action: action)
        }
        return actions
    }

    /// Writes the user's decision about a brick on the knowledge queue, then
    /// reads everything back into the open panel, the brick selected. A
    /// proposal is validated only on proofs that still hold.
    private func writeBrick(_ context: ProjectMemoryContext, id: String, action: ProjectMemoryPreview.BrickAction) -> Bool {
        let request = projectMemoryRequest
        let opening = projectMemoryPanel?.opening ?? 0
        changeKnowledge(inSpace: context.spaceID, { loaded, store, now in
            switch action {
            case .validate:
                guard let proposal = loaded.pending.first(where: { $0.id == id }) else { throw ProjectMemory.WriteError.failed("It was decided meanwhile.") }
                guard let anchor = SpaceKnowledge.anchor(key: proposal.brick.scope.anchor) else { throw ProjectMemory.WriteError.failed("Its repository is unknown.") }
                if let problem = SpaceKnowledge.proofProblem(of: proposal.brick, anchor: anchor, now: now) {
                    throw ProjectMemory.WriteError.failed(problem)
                }
                if let refusal = loaded.refusal(of: proposal.brick, now: now, macOS: SpaceKnowledge.macOS, validating: true) {
                    throw ProjectMemory.WriteError.failed(Self.text(of: refusal))
                }
                guard let brick = loaded.validate(id, now: now) else { throw ProjectMemory.WriteError.failed("It was decided meanwhile.") }
                // The brick's file first: a state naming a brick without one shows nothing.
                try store.add(brick)
            case .dismiss where id.hasPrefix("f-"):
                _ = loaded.dismissFlag(id)
            case .dismiss:
                guard loaded.dismiss(id, now: now) else { throw ProjectMemory.WriteError.failed("It was decided meanwhile.") }
            case .reconfirm:
                guard loaded.reconfirm(id, now: now, macOS: SpaceKnowledge.macOS) else { throw ProjectMemory.WriteError.failed("It is closed.") }
            case .close:
                guard loaded.close(id, because: "Closed by you.", now: now) else { throw ProjectMemory.WriteError.failed("It is closed already.") }
            }
        }, completion: { [weak self] failure in
            guard let self else { return }
            Self.readProjectMemory(context) { [weak self] model in
                guard let self, let panel = projectMemoryPanel else { return }
                guard request == projectMemoryRequest else {
                    panel.writeEnded(opening: opening)
                    if let failure { showToast(failure, tone: .error) }
                    return
                }
                let picks: (ProjectMemory.Entry) -> Bool = { model.knowledge.brick(of: $0)?.id == id }
                if let failure {
                    panel.writeFailed(failure, model: model, selecting: picks)
                } else {
                    panel.update(model: model, selecting: picks)
                }
            }
        })
        return true
    }

    /// The Brief tab holds typed text: a write to the brief now would be
    /// lost, or replace it, when that text is saved. Says so in the panel.
    private func briefHasUnsavedText() -> Bool {
        guard spaceSettings?.brief.isDirty == true else { return false }
        projectMemoryPanel?.writeFailed("Save or revert the text typed in the Brief tab first: this changes the brief.")
        return true
    }

    /// The project's brief, created on first use as Space Settings › Brief
    /// does; nil with a toast when it can't be.
    private func ensureProjectBrief(spaceID: String) -> URL? {
        let name = workspaceStore.profiles.first { $0.id == spaceID }?.name ?? spaceID
        do {
            if let url = try SpaceBrief.ensureBriefFile(spaceID: spaceID, spaceName: name) { return url }
        } catch {
            NiruxDebugLog.log("ProjectMemory: could not create the brief file: \(error)")
        }
        projectMemoryPanel?.writeFailed("Couldn’t create the space’s brief")
        return nil
    }

    /// Runs `work` on the writes' queue, one after the other, then reads
    /// everything back into the open panel, the written item selected. A
    /// failure says why in the panel (an edit stays as typed), or in a toast
    /// once the panel is gone. Returns true: the write started.
    private func writeProjectMemory(
        _ context: ProjectMemoryContext, keeping failedSelection: ProjectMemorySelection = .none,
        _ work: @escaping @Sendable () throws -> ProjectMemorySelection
    ) -> Bool {
        // A panel opened since, maybe for another workspace, isn't this one.
        let request = projectMemoryRequest
        let opening = projectMemoryPanel?.opening ?? 0
        Self.runProjectMemoryWrite(context, work) { [weak self] model, result in
            // The Brief tab shows what a write to the brief left.
            self?.spaceSettings?.brief.checkDisk()
            guard let self, let panel = projectMemoryPanel else { return }
            // Closed or reopened since: the result isn't this panel's to show,
            // but the write is over.
            guard request == projectMemoryRequest else {
                panel.writeEnded(opening: opening)
                if case .failure(let error) = result { showToast(error.localizedDescription, tone: .error) }
                return
            }
            func picks(_ selection: ProjectMemorySelection) -> (ProjectMemory.Entry) -> Bool {
                { entry in
                    switch selection {
                    case .memory(let fileName): return model.knowledge.memory(of: entry)?.fileName == fileName
                    case .rule(let text): return entry.scope == .always && model.knowledge.rule(of: entry)?.rule.text == text
                    case .missingFile(let fileName):
                        if case .missingFile(let line) = entry.source { return line.fileName == fileName }
                        return false
                    case .brick(let id): return model.knowledge.brick(of: entry)?.id == id
                    case .none: return false
                    }
                }
            }
            switch result {
            case .failure(let error):
                panel.writeFailed(error.localizedDescription, model: model, selecting: picks(failedSelection))
                if !panel.isVisible { showToast(error.localizedDescription, tone: .error) }
            case .success(let selection):
                panel.update(model: model, selecting: picks(selection))
            }
        }
        return true
    }

    // MARK: - Off the main thread

    /// One write at a time: two at once could each re-read `MEMORY.md`
    /// before the other's rename.
    nonisolated private static let projectMemoryWrites = DispatchQueue(label: "Nirux.ProjectMemory.writes", qos: .userInitiated)

    /// Off the main thread through nonisolated functions, so the closures
    /// can't inherit this view's main-actor isolation.
    nonisolated static func readProjectMemory(
        _ context: ProjectMemoryContext, completion: @escaping @MainActor @Sendable (ProjectMemoryPanel.Model) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let model = projectMemoryModel(context)
            DispatchQueue.main.async { @MainActor in
                completion(model)
            }
        }
    }

    nonisolated private static func runProjectMemoryWrite(
        _ context: ProjectMemoryContext,
        _ work: @escaping @Sendable () throws -> ProjectMemorySelection,
        completion: @escaping @MainActor @Sendable (ProjectMemoryPanel.Model, Result<ProjectMemorySelection, Error>) -> Void
    ) {
        projectMemoryWrites.async {
            let result = Result { try work() }
            let model = projectMemoryModel(context)
            DispatchQueue.main.async { @MainActor in
                completion(model, result)
            }
        }
    }

    nonisolated private static func projectMemoryModel(_ context: ProjectMemoryContext) -> ProjectMemoryPanel.Model {
        let location = ProjectMemory.locate(
            folder: context.folder, home: context.home, environment: context.environment, managed: context.managed
        )
        let bricks = SpaceKnowledge.store(spaceID: context.spaceID).flatMap {
            ProjectMemory.Bricks.read($0, serves: SpaceDefaultsStore.defaults(forSpace: context.spaceID).servesKnowledge)
        }
        return ProjectMemoryPanel.Model(
            repository: URL(fileURLWithPath: location.projectRoot).lastPathComponent,
            location: location,
            knowledge: ProjectMemory.knowledge(folder: context.folder, brief: context.brief, location: location, bricks: bricks)
        )
    }
}

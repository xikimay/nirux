import AppKit

// MARK: - Project Memory panel (⌘P › Project Memory…, the project's menu)

extension NiruxShellView {
    /// What a Project Memory read needs, kept for the reads after a write.
    struct ProjectMemoryContext: Sendable {
        let folder: String
        let brief: URL?
        let home: String
        let environment: [String: String]
        let managed: ProjectMemory.ManagedFolders
    }

    /// Which item to select once a write is read back.
    enum ProjectMemorySelection: Sendable {
        case memory(fileName: String)
        case rule(text: String)
        case missingFile(fileName: String)
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

    /// Opens what agents know about the active workspace's repository; from
    /// a project's menu, about that project's workspace's (see
    /// `projectMemoryWorkspace`). The workspace's own folder decides, not
    /// where its focused terminal has `cd`'d.
    func showProjectMemory(profileID: String? = nil) {
        guard window != nil else { return }
        guard let workspace = profileID.map(projectMemoryWorkspace(inProject:)) ?? activeWorkspace else {
            showToast("Open a workspace in this project to see what agents know")
            return
        }
        let context = ProjectMemoryContext(
            folder: workspace.cwd,
            brief: SpaceBrief.briefURL(spaceID: workspace.profileID),
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
            presentProjectMemory(model, context: context, workspace: workspace)
        }
    }

    /// From a project's menu: its active workspace when it is the active
    /// project, else its first one.
    func projectMemoryWorkspace(inProject profileID: String) -> WorkspaceState? {
        if let active = activeWorkspace, active.profileID == profileID, !active.isClosing { return active }
        return projectWorkspaces(of: profileID).first
    }

    private func presentProjectMemory(
        _ model: ProjectMemoryPanel.Model, context: ProjectMemoryContext, workspace: WorkspaceState?
    ) {
        guard let window else { return }
        if projectMemoryPanel == nil { projectMemoryPanel = ProjectMemoryPanel() }
        projectMemoryPanel?.show(
            relativeTo: window, model: model, actions: projectMemoryActions(context: context, workspace: workspace)
        )
    }

    // MARK: - Actions

    private func projectMemoryActions(context: ProjectMemoryContext, workspace: WorkspaceState?) -> ProjectMemoryPanel.Actions {
        let spaceID = workspace?.profileID
        let trash = sideEffects.trash
        var actions = ProjectMemoryPanel.Actions()
        // An item's file opens in the editor of the workspace it was read
        // for, brought forward, as the project brief opens in the
        // workspace's.
        actions.open = { [weak self, weak workspace] url, line in
            guard let self else { return }
            window?.makeKey()
            let target = workspace.flatMap { workspace in
                workspace.isClosing ? nil : workspaces.firstIndex { $0 === workspace }
            }
            if let target, workspaces[target] !== activeWorkspace { switchToWorkspace(target) }
            openInEditorColumn(path: url.path, line: line, in: target.map { workspaces[$0] })
        }
        actions.confirm = { [weak self] alert in self?.runModal(alert) == .alertFirstButtonReturn }
        let limit = SpaceBrief.maxCharacters
        actions.move = { [weak self] target, scope in
            guard let self else { return false }
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
        return actions
    }

    /// The project's brief, created on first use as "Edit Project Brief…"
    /// does; nil with a toast when it can't be.
    private func ensureProjectBrief(spaceID: String?) -> URL? {
        if let spaceID {
            let name = workspaceStore.profiles.first { $0.id == spaceID }?.name ?? spaceID
            do {
                if let url = try SpaceBrief.ensureBriefFile(spaceID: spaceID, spaceName: name) { return url }
            } catch {
                NiruxDebugLog.log("ProjectMemory: could not create the brief file: \(error)")
            }
        }
        projectMemoryPanel?.writeFailed("Couldn’t create the project’s brief")
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
    nonisolated private static func readProjectMemory(
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
        return ProjectMemoryPanel.Model(
            repository: URL(fileURLWithPath: location.projectRoot).lastPathComponent,
            location: location,
            knowledge: ProjectMemory.knowledge(folder: context.folder, brief: context.brief, location: location)
        )
    }
}

import AppKit

// MARK: - The ⌘N sheet (see NewTask)

extension NiruxShellView {
    /// ⌘N, the sidebar's "+" and "New…" in the palette: the sheet opens on
    /// the active space, its default repository selected
    /// (docs/design/spaces.md, "One door: ⌘N").
    /// `spaceID` and `selectedKey` (a Lead's proposal) override the active
    /// space and its default repository; `withoutRepository` selects No
    /// Repository. `parentTask` ("New Sub-task…"): the task it starts lists
    /// under that one, in its repository or its folder.
    @discardableResult
    func showNewPanel(
        spaceID requestedSpaceID: String? = nil, selectedKey: String? = nil, withoutRepository: Bool = false,
        parentTask: NewTaskPanel.ParentTask? = nil
    ) -> NewTaskPanel? {
        guard let window else { return nil }
        // Another sheet is up (an alert, Board Settings): a second one would
        // wait unseen behind it, and one waiting there would come up loose.
        if let sheet = window.attachedSheet, sheet !== newTaskPanel?.panel {
            NSSound.beep()
            sheet.makeKeyAndOrderFront(nil)
            return nil
        }
        if let panel = newTaskPanel {
            guard panel.isHidden else {
                panel.focus()
                return nil
            }
            // Closed while its task starts: it comes back by itself if
            // starting fails, and ⌘N opens a new sheet meanwhile.
            startingTaskPanels.append(panel)
            newTaskPanel = nil
        }
        let spaceID = requestedSpaceID ?? activeProfileID
        guard let space = profiles.first(where: { $0.id == spaceID }) else { return nil }
        let panel = NewTaskPanel()
        newTaskPanel = panel
        let stateDirectory = Persistence.stateDirectory
        // Capture lists in the inner closures too: they are @Sendable, and
        // Swift 6.1 rejects one reading a weak var it didn't capture itself.
        panel.onRepositorySelected = { [weak self, weak panel] repository in
            let anchors = self?.profiles.first { $0.id == spaceID }?.anchors ?? []
            Self.readNewTaskInfo(
                spaceID: spaceID, folder: repository?.folder, anchors: anchors, stateDirectory: stateDirectory
            ) { [weak panel] info in
                panel?.update(repositoryKey: repository?.key, info: info)
            }
        }
        panel.onStart = { [weak self, weak panel] request in
            guard let self, let panel else { return }
            self.startTask(request) { [weak self, weak panel] outcome in
                // Its picture, before it closes: it folds toward the
                // task's row.
                if case .opened = outcome, let panel { self?.takeTaskSheetPicture(of: panel) }
                panel?.finishStarting(outcome)
            }
        }
        // No Repository: the home folder, as the sheet says, not the
        // space's default folder.
        let homeFolder = sideEffects.homeDirectory()
        let settings = Persistence.load()?.settings
        panel.onOpenShell = { [weak self] repository in
            self?.openPlainWorkspace(spaceID: spaceID, folder: repository?.folder ?? homeFolder)
        }
        panel.onAddSuggested = { [weak self] anchor in
            self?.runFromRunLoop { [weak self] in self?.addAnchor(anchor, toSpace: spaceID, pickedInSheet: true) }
        }
        panel.onAddRepository = { [weak self, weak panel] in
            self?.addRepository(toSpace: spaceID, sheet: panel?.panel)
        }
        panel.onExistingBranch = { [weak self] repository in
            self?.showWorktreeListPalette(repositoryFolder: repository?.folder)
        }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            if self.newTaskPanel === panel { self.newTaskPanel = nil }
            self.startingTaskPanels.removeAll { $0 === panel }
            self.focusActiveTerminal(in: self.window)
        }
        let repositories = newTaskRepositories(of: space)
        // Before it shows: the sheet comes down at its size.
        panel.lead = leadMissionParent(inSpace: space.id)
        panel.showsTrustHint = !(settings?.startedFolderTask ?? false)
        // A sub-task's repository (none for a task without one), No
        // Repository when asked, else the one asked for, the default, the
        // first.
        let selected: String?
        if let parentTask {
            selected = parentTask.repositoryKey
        } else if withoutRepository {
            selected = nil
        } else {
            selected = [selectedKey, space.anchors.defaultAnchor?.key].compactMap { $0 }
                .first { key in repositories.contains { $0.key == key } } ?? repositories.first?.key
        }
        panel.show(
            attachedTo: window,
            space: NewTaskPanel.Space(id: space.id, name: space.name, isGeneral: space.id == WorkspaceProfile.defaultID),
            repositories: repositories,
            selectedKey: selected,
            parentTask: parentTask,
            agent: defaultTaskAgent(forSpace: space.id),
            homeFolder: homeFolder,
            tasksFolder: tasksFolder(settings).path,
            tasksFolderIsDefault: tasksFolder(settings).isDefault
        )
        if repositories.isEmpty, space.id != WorkspaceProfile.defaultID {
            suggestRepository(to: panel)
        }
        return panel
    }

    /// "New Sub-task…": the sheet in the task's space and repository (see
    /// `subtaskRepositoryKey`), under it. A task without a repository has
    /// its sub-tasks' folders in its own.
    @discardableResult
    func showNewSubtaskPanel(under parent: WorkspaceState) -> NewTaskPanel? {
        if let folder = parent.taskFolder, !parent.isLead {
            guard NiruxURLRequest.directoryExists(folder) else {
                NSSound.beep()
                return nil
            }
            return showNewPanel(
                spaceID: parent.profileID,
                parentTask: NewTaskPanel.ParentTask(workspaceID: parent.id, title: parent.title, place: .folder(folder))
            )
        }
        guard let repositoryKey = subtaskRepositoryKey(of: parent) else {
            NSSound.beep()
            return nil
        }
        return showNewPanel(
            spaceID: parent.profileID,
            parentTask: NewTaskPanel.ParentTask(workspaceID: parent.id, title: parent.title, place: .repository(key: repositoryKey))
        )
    }

    /// Where a task without a repository gets its folder (NewTask+Folder):
    /// the one picked in Settings › General, else `defaultTasksFolder`,
    /// the only one made when missing (`isDefault`).
    func tasksFolder(_ settings: PersistedSettings? = Persistence.load()?.settings) -> (path: String, isDefault: Bool) {
        settings?.tasksFolder.map { ($0, false) } ?? (defaultTasksFolder, true)
    }

    /// `~/Nirux Tasks`, made when missing.
    var defaultTasksFolder: String {
        (sideEffects.homeDirectory() as NSString).appendingPathComponent(NewTask.defaultTasksFolderName)
    }

    /// The menu bar's New Sub-task…, for the workspace in front. Not while
    /// a sheet is up: ⌘N's would come forward without the parent.
    var activeWorkspaceOffersSubtask: Bool {
        window?.attachedSheet == nil && (activeWorkspace.map(offersSubtask) ?? false)
    }

    /// The space's Lead as a Mission parent: its workspace and the column
    /// its Claude runs in (or will, once a restored one resumes), else its
    /// first terminal.
    func leadMissionParent(inSpace spaceID: String) -> NewTask.MissionParent? {
        guard let lead = leadWorkspace(inSpace: spaceID) else { return nil }
        let snapshot = ProcessSnapshot()
        let terminals = lead.columns.filter { !$0.isClosing && $0.agentUUID != nil && ($0.pty != nil || $0.deferredAgent != nil) }
        let claude = terminals.first { column in
            column.deferredAgent?.processName == "claude" || column.pty?.foregroundProcessName(snapshot: snapshot) == "claude"
        }
        guard let agentUUID = (claude ?? terminals.first)?.agentUUID else { return nil }
        return NewTask.MissionParent(workspaceID: lead.id, agentUUID: agentUUID)
    }

    /// The agent a space's tasks start with unless the sheet says otherwise:
    /// its default (Space Settings › Defaults), else Claude Code.
    func defaultTaskAgent(forSpace spaceID: String) -> NiruxApp.WorkspaceAgent {
        SpaceDefaultsStore.defaults(forSpace: spaceID).taskAgent
    }

    /// The space's repositories and folders the sheet can start from: those
    /// with a folder (a bare repository has no main checkout to find).
    func newTaskRepositories(of space: WorkspaceProfile) -> [NewTaskPanel.Repository] {
        space.anchors.compactMap { anchor in
            guard let key = anchor.key, let folder = anchor.folder else { return nil }
            var isFolder = false
            if case .folder = anchor.kind { isFolder = true }
            return NewTaskPanel.Repository(key: key, name: anchor.name, folder: folder, isFolder: isFolder)
        }
    }

    /// The sheet of a space whose repositories changed: `key` was just
    /// anchored from it, and is selected (see
    /// `NewTaskPanel.updateRepositories`).
    func refreshNewTaskPanelRepositories(selecting key: String? = nil) {
        guard let panel = newTaskPanel, panel.panel != nil,
              let space = profiles.first(where: { $0.id == panel.space.id })
        else { return }
        panel.updateRepositories(newTaskRepositories(of: space), added: key, fallback: space.anchors.defaultAnchor?.key)
    }

    /// Offers the focused terminal's repository to a space that has none,
    /// unless another space has it (as New Space… does).
    private func suggestRepository(to panel: NewTaskPanel) {
        guard projectStore.availability == .writable, let folder = activeWorkspace?.focusedWorkingDirectory else { return }
        Self.identifyOffMain(folder, timeout: max(1, sideEffects.routingTimeout)) { [weak self, weak panel] identity in
            guard let self, let panel, let identity, identity.commonDir != nil,
                  identity.anchor.key.flatMap(self.workspaceStore.profile(anchoring:)) == nil
            else { return }
            panel.setSuggestion(identity.anchor)
        }
    }

    /// Return with nothing typed: a shell in the repository's main checkout,
    /// else where a plain workspace of the space opens (its default folder,
    /// else the home folder). Named after its folder, then its branch.
    func openPlainWorkspace(spaceID: String, folder: String?) {
        let cwd = folder.flatMap { NiruxURLRequest.directoryExists($0) ? $0 : nil } ?? defaultFolder(forSpace: spaceID)
        addWorkspace(cwd: cwd, profileID: spaceID)
        saveState()
    }

    /// Fetches origin's branch, creates the worktree (or the folder, for a
    /// task without a repository) and writes the handover off the main
    /// thread, then opens the workspace and launches the agent.
    /// `completion` says how it ended; when the sheet was closed meanwhile,
    /// it comes back to show a failure. `opened` follows `.opened`, once the
    /// workspace is there, with its id and what was made.
    func startTask(
        _ request: NewTask.Request,
        completion: @escaping @MainActor @Sendable (NewTaskPanel.Outcome) -> Void,
        opened: (@MainActor (_ workspaceID: String, _ created: CreatedTask) -> Void)? = nil
    ) {
        Self.createTask(
            request, handoverFilename: Self.handoverFilename(for: request.agent), routesByAnchor: routesByAnchor
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failed(let message):
                completion(.failed(message))
            case .fetchFailed(let message):
                completion(.fetchFailed(message))
            case .created(let created):
                // The sheet goes first: the new terminal then takes the focus.
                completion(.opened)
                let workspaceID = self.openTaskWorkspace(request, created)
                opened?(workspaceID, created)
            }
        }
    }

    /// In the space its repository belongs to, else the sheet's
    /// (docs/design/spaces.md, "Routing"). A folder has no repository: its parent's
    /// space, else the sheet's, whatever space anchors a folder above it.
    @discardableResult
    private func openTaskWorkspace(_ request: NewTask.Request, _ created: CreatedTask) -> String {
        var decision = decideSpace(
            identity: created.identity, parentWorkspaceID: request.parentWorkspaceID ?? request.reportsTo?.workspaceID,
            startedFromSpaceID: request.projectID
        )
        // A task a Lead starts comes from its space's repository: it opens
        // in that space, as its parent, even when another space anchors its
        // folder (its setup script then doesn't run).
        if request.startedByLead,
           let lead = request.reportsTo.flatMap({ parent in workspaces.first { $0.id == parent.workspaceID && $0.isLead } }),
           decision.spaceID != lead.profileID {
            decision = decideSpace(identity: nil, parentWorkspaceID: lead.id, startedFromSpaceID: lead.profileID)
        }
        let childWorkspaceID = UUID().uuidString
        let childAgentUUID = UUID().uuidString
        // The branch, or the folder's name as it was made.
        let label = created.checkedOutBranch ?? created.folderName ?? request.name
        let title = NewTask.workspaceTitle(description: request.description) ?? label
        // A Mission names its child by its branch: a folder task has none,
        // so its title stands in ("Fix login", not "Fix login (branch Fix
        // login 2)"), and `--mission tell --branch` takes that title.
        let mission = request.reportsTo.flatMap { parent in
            createMission(
                parent: parent, childWorkspaceID: childWorkspaceID, childAgentUUID: childAgentUUID,
                agent: request.agent, branch: created.folderName == nil ? label : title, reportsToTask: request.reportsToTask
            )
        }
        addWorkspace(
            title: title,
            cwd: created.workingDirectory,
            agent: request.agent,
            profileID: decision.spaceID,
            workspaceID: childWorkspaceID,
            initialAgentUUID: childAgentUUID,
            missionID: mission?.id,
            parentWorkspaceID: request.parentWorkspaceID,
            reportsToLead: mission?.reportsToLead == true,
            reportsToTask: mission?.reportsToTask == true,
            deliveredHandover: created.handoverError == nil,
            // A folder's name is as stable as a branch: it names the
            // session too (see `SessionName`).
            worktreeBranch: created.checkedOutBranch ?? created.folderName,
            // The Lead's list_tasks says another agent started it.
            startedByAgent: request.reportsToTask,
            setupScript: setupScript(for: decision),
            taskFolder: created.folderName == nil ? nil : created.path,
            activate: request.opensInFront,
            slidesIn: pendingTaskSheet != nil
        )
        if let born = workspaces.first(where: { $0.id == childWorkspaceID }) { playTaskBirth(of: born) }
        // The sheet's trust hint has done its job once a Claude Code task
        // started in the tasks folder, where the hint applies.
        // The cheap checks first: the settings are read only for such a task.
        if case .folder(let parent, _, _) = request.place, created.folderName != nil, request.agent == .claude,
           !request.startedByLead, request.parentWorkspaceID == nil {
            let settings = Persistence.load()?.settings
            if settings?.startedFolderTask != true, parent == tasksFolder(settings).path {
                _ = Persistence.updateSettings(liveLayout: persistedState()) { $0.startedFolderTask = true }
            }
        }
        saveState()
        // A hook prints its reason last.
        let gitWarning = created.gitWarning.map {
            "git reported a problem: the worktree may be incomplete.\n\n" + NewTaskPanel.lastLines(of: $0, maxLines: 12)
        }
        if let handoverError = created.handoverError {
            NSLog("[NewTask] Handover not written in \(created.workingDirectory): \(handoverError)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(created.handover, forType: .string)
            presentProblem(
                "The task wasn’t handed over for “\(label)”",
                "The \(created.folderName == nil ? "worktree" : "folder") is open and the agent started without it. "
                    + "The task is on the clipboard: paste it in. "
                    + handoverError.explanation + (gitWarning.map { "\n\n" + $0 } ?? "")
            )
        } else if let gitWarning {
            presentProblem("“\(label)” is open and the agent started", gitWarning)
        }
        return childWorkspaceID
    }

    struct CreatedTask: Sendable {
        /// The worktree, or the task's folder.
        let path: String
        /// The worktree, or the space's folder in it (`Target.subdirectory`);
        /// the task's folder.
        let workingDirectory: String
        let checkedOutBranch: String?
        /// A task without a repository: its folder's name, as made (`name 2`
        /// when the name was taken).
        var folderName: String?
        let handover: String
        let handoverError: HandoverFile.TransferError?
        /// git's error, when it failed after creating the worktree.
        let gitWarning: String?
        /// `workingDirectory`'s repository, for routing.
        let identity: FolderIdentity?
    }

    enum TaskResult: Sendable {
        case created(CreatedTask)
        case failed(String)
        case fetchFailed(String)
    }

    /// Handover files never belong in a commit: the repository ignores them
    /// (see `GitWorktree.ensureExcluded`), in any folder, since a task's
    /// workspace may open in a folder of the repository.
    nonisolated static let excludedHandovers = HandoverFile.filenames

    /// Off the main thread through nonisolated functions, so the closures
    /// can't inherit this view's main-actor isolation (see `runOffMain` in
    /// the worktree cleanup). `stateDirectory` is read on the main thread:
    /// a test's environment may be gone by the time this runs.
    nonisolated static func readNewTaskInfo(
        spaceID: String,
        folder: String?,
        anchors: [SpaceAnchor],
        stateDirectory: URL,
        completion: @escaping @MainActor @Sendable (NewTaskPanel.ProjectInfo) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Each repository's board base; one the board doesn't set up
            // starts from its origin's default branch.
            let baseBranch = folder.flatMap {
                boardBaseBranch(for: $0, spaceID: spaceID, anchors: anchors, stateDirectory: stateDirectory)
            }
            let target = folder.flatMap { NewTask.resolveTarget(folder: $0, baseBranch: baseBranch) }
            let templates = TaskTemplates.load(spaceID: spaceID, stateDirectory: stateDirectory)
            let isOutsideGit = target == nil && folder.map(NewTask.isOutsideGit) == true
            let isGone = folder.map { !NiruxURLRequest.directoryExists($0) } ?? false
            DispatchQueue.main.async { @MainActor in
                completion(NewTaskPanel.ProjectInfo(target: target, templates: templates, isOutsideGit: isOutsideGit, isGone: isGone))
            }
        }
    }

    nonisolated private static func createTask(
        _ request: NewTask.Request,
        handoverFilename: String,
        routesByAnchor: Bool,
        completion: @escaping @MainActor @Sendable (TaskResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: TaskResult
            switch request.place {
            case .worktree(let target, let branch):
                result = makeTaskWorktree(
                    request, target: target, branch: branch, handoverFilename: handoverFilename, routesByAnchor: routesByAnchor
                )
            case .folder(let parent, let name, let makesParent):
                result = makeTaskFolder(request, parent: parent, name: name, makesParent: makesParent, handoverFilename: handoverFilename)
            }
            DispatchQueue.main.async { @MainActor in
                completion(result)
            }
        }
    }

    /// A new folder, never one already there (see `NewTask.makeFolder`),
    /// with the handover. Nothing else: no git, no setup script.
    nonisolated private static func makeTaskFolder(
        _ request: NewTask.Request, parent: String, name: String, makesParent: Bool, handoverFilename: String
    ) -> TaskResult {
        // Checked before the folder is made, with the longest name it may
        // get: a refusal leaves nothing behind.
        let longest = NewTask.folderHandover(
            description: request.description, template: request.template,
            folder: (parent as NSString).appendingPathComponent("\(name) \(NewTask.maxFolderAttempts)")
        )
        guard longest.utf8.count <= HandoverFile.maxBytes else {
            return .failed("The task and its template are longer than 1 MB: shorten them.")
        }
        // Never inside a git repository (a dotfiles home holds the default
        // tasks folder, say, or a parent task's agent ran `git init`): the
        // agent would work in that repository. Two short lines: the sheet
        // cuts a long one in its middle.
        if !NewTask.isOutsideGit(NewTask.nearestFolder(holding: parent) ?? parent) {
            let name = (parent as NSString).lastPathComponent
            return .failed(request.parentWorkspaceID == nil
                ? "“\(name)” is inside a git repository, where a task without one doesn’t belong.\n"
                    + "Pick another folder for these tasks in Settings › General."
                : "“\(name)” is inside a git repository now, where a task without one doesn’t belong.\n"
                    + "Uncheck “Sub-task of” to give it a folder of its own.")
        }
        let folder: String
        switch NewTask.makeFolder(named: name, in: parent, makesParent: makesParent) {
        case .success(let path): folder = path
        case .failure(let error): return .failed(error.message)
        }
        let handover = NewTask.folderHandover(description: request.description, template: request.template, folder: folder)
        var handoverError: HandoverFile.TransferError?
        if case .failure(let failure) = HandoverFile.deliver(handover, toDirectory: folder, filename: handoverFilename) {
            handoverError = failure
        }
        return .created(CreatedTask(
            path: folder, workingDirectory: folder, checkedOutBranch: nil, folderName: (folder as NSString).lastPathComponent,
            handover: handover, handoverError: handoverError, gitWarning: nil, identity: nil
        ))
    }

    nonisolated private static func makeTaskWorktree(
        _ request: NewTask.Request, target: NewTask.Target, branch: String, handoverFilename: String, routesByAnchor: Bool
    ) -> TaskResult {
        let start: NewTask.Start
        if let remoteBranch = target.remoteBranch, let name = target.remoteBranchName {
            if request.fetchesFirst {
                if let error = GitWorktree.fetch(branch: remoteBranch, repoRoot: target.repository) {
                    return .fetchFailed(error)
                }
                start = .fetched(name)
            } else {
                start = .lastFetched(name)
            }
        } else {
            start = .checkoutHead(repository: target.repository, branch: target.checkoutBranch)
        }
        let handover = NewTask.handover(
            description: request.description, template: request.template, branch: branch,
            start: start, subdirectory: target.subdirectory
        )
        guard handover.utf8.count <= HandoverFile.maxBytes else {
            return .failed("The task and its template are longer than 1 MB: shorten them.")
        }
        let (path, error) = GitWorktree.create(branch: branch, repoRoot: target.repository, newBranchFrom: target.startPoint)
        guard let path else { return .failed(error ?? "git worktree add failed") }
        GitWorktree.ensureExcluded(excludedHandovers, repoRoot: target.repository)
        let workingDirectory = NewTask.workingDirectory(in: path, subdirectory: target.subdirectory)
        // Where the agent starts: its prompt names the file, not a path.
        var handoverError: HandoverFile.TransferError?
        if case .failure(let failure) = HandoverFile.deliver(handover, toDirectory: workingDirectory, filename: handoverFilename) {
            handoverError = failure
        }
        return .created(CreatedTask(
            path: path,
            workingDirectory: workingDirectory,
            // Read back from the checkout: the session is named after the
            // branch it will actually work on (see `SessionName`).
            checkedOutBranch: GitWorktree.currentBranch(at: path),
            handover: handover,
            handoverError: handoverError,
            gitWarning: error,
            identity: routesByAnchor
                ? FolderIdentity.identify(workingDirectory, timeout: FolderIdentity.backgroundRoutingTimeout) : nil
        ))
    }
}

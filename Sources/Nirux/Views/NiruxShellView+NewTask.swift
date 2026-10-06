import AppKit

// MARK: - New Task (see NewTask)

extension NiruxShellView {
    /// New Task… in the palette: the form opens on the active project.
    func showNewTaskPanel() {
        guard let window else { return }
        if let panel = newTaskPanel {
            if panel.isHidden { panel.reshow() } else { panel.focus() }
            return
        }
        let panel = NewTaskPanel()
        newTaskPanel = panel
        // Capture lists in the inner closures too: they are @Sendable, and
        // Swift 6.1 rejects one reading a weak var it didn't capture itself.
        panel.onProjectSelected = { [weak self, weak panel] projectID in
            guard let self, let panel else { return }
            let folders = self.newTaskFolders(projectID: projectID)
            Self.readNewTaskProject(
                projectID: projectID, folders: folders, stateDirectory: Persistence.stateDirectory
            ) { [weak panel] info in
                panel?.update(projectID: projectID, info: info)
            }
        }
        panel.onStart = { [weak self, weak panel] request in
            guard let self, let panel else { return }
            self.startTask(request) { [weak panel] outcome in panel?.finishStarting(outcome) }
        }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self else { return }
            if self.newTaskPanel === panel { self.newTaskPanel = nil }
            self.focusActiveTerminal(in: self.window)
        }
        panel.show(
            attachedTo: window,
            projects: profiles.map { NewTaskPanel.Project(id: $0.id, name: $0.name) },
            selectedProjectID: activeProfileID
        )
    }

    /// Where to look for a project's repository, in order: the active
    /// workspace's folder and the folder its focused terminal is in, when it
    /// belongs to the project, then the folders of the project's other
    /// workspaces, inactive ones included.
    func newTaskFolders(projectID: String) -> [NewTask.Folder] {
        var folders: [NewTask.Folder] = []
        let active = activeWorkspace.flatMap { $0.profileID == projectID ? $0 : nil }
        if let active {
            folders.append(NewTask.Folder(path: active.cwd, isWorkspaceFolder: true))
            folders.append(NewTask.Folder(path: active.focusedWorkingDirectory, isWorkspaceFolder: false))
        }
        for workspace in workspaces where workspace.profileID == projectID && !workspace.isClosing && workspace !== active {
            folders.append(NewTask.Folder(path: workspace.cwd, isWorkspaceFolder: true))
        }
        return folders
    }

    /// Fetches origin's branch, creates the worktree and writes the handover
    /// off the main thread, then opens the workspace and launches the agent.
    /// `completion` says how it ended; when the form was closed meanwhile,
    /// it comes back to show a failure.
    func startTask(_ request: NewTask.Request, completion: @escaping @MainActor @Sendable (NewTaskPanel.Outcome) -> Void) {
        Self.createTaskWorktree(request, handoverFilename: Self.handoverFilename(for: request.agent)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failed(let message):
                completion(.failed(message))
            case .fetchFailed(let message):
                completion(.fetchFailed(message))
            case .created(let created):
                // The sheet goes first: the new terminal then takes the focus.
                completion(.opened)
                self.openTaskWorkspace(request, created)
            }
        }
    }

    private func openTaskWorkspace(_ request: NewTask.Request, _ created: CreatedTaskWorktree) {
        addWorkspace(
            title: NewTask.workspaceTitle(description: request.description) ?? request.branch,
            cwd: created.workingDirectory,
            agent: request.agent,
            profileID: request.projectID,
            deliveredHandover: created.handoverError == nil,
            handoverText: created.handover,
            worktreeBranch: created.checkedOutBranch
        )
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
                "The task wasn’t handed over for “\(request.branch)”",
                "The worktree is open and the agent started without it. The task is on the clipboard: paste it in. "
                    + handoverError.explanation + (gitWarning.map { "\n\n" + $0 } ?? "")
            )
        } else if let gitWarning {
            presentProblem("“\(request.branch)” is open and the agent started", gitWarning)
        }
    }

    /// "Edit Task Templates…" in a project's menu: opens its templates in an
    /// editor column, creating the file with the default ones on first use.
    func editTaskTemplates(profileID: String) {
        let projectName = workspaceStore.profiles.first { $0.id == profileID }?.name ?? profileID
        do {
            guard let url = try TaskTemplates.ensureFile(spaceID: profileID, spaceName: projectName) else {
                NSSound.beep()
                return
            }
            openInEditorColumn(path: url.path)
        } catch {
            NiruxDebugLog.log("TaskTemplates: could not create the templates file: \(error)")
            NSSound.beep()
        }
    }

    struct CreatedTaskWorktree: Sendable {
        let path: String
        /// The worktree, or the project's folder in it (`Target.subdirectory`).
        let workingDirectory: String
        let checkedOutBranch: String?
        let handover: String
        let handoverError: HandoverFile.TransferError?
        /// git's error, when it failed after creating the worktree.
        let gitWarning: String?
    }

    enum TaskWorktreeResult: Sendable {
        case created(CreatedTaskWorktree)
        case failed(String)
        case fetchFailed(String)
    }

    /// Handover files never belong in a commit: the repository ignores them
    /// (see `GitWorktree.ensureExcluded`), in any folder, since a project's
    /// workspace may open in a folder of the repository.
    nonisolated static let excludedHandovers = NiruxApp.WorkspaceAgent.allCases.map(handoverFilename(for:))

    /// Off the main thread through nonisolated functions, so the closures
    /// can't inherit this view's main-actor isolation (see `runOffMain` in
    /// the worktree cleanup). `stateDirectory` is read on the main thread:
    /// a test's environment may be gone by the time this runs.
    nonisolated private static func readNewTaskProject(
        projectID: String,
        folders: [NewTask.Folder],
        stateDirectory: URL,
        completion: @escaping @MainActor @Sendable (NewTaskPanel.ProjectInfo) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let baseBranch = BoardConfigStore(spaceID: projectID, stateDirectory: stateDirectory)?.load().config?.baseBranch
            let target = NewTask.resolveTarget(folders: folders, baseBranch: baseBranch)
            let templates = TaskTemplates.load(spaceID: projectID, stateDirectory: stateDirectory)
            DispatchQueue.main.async { @MainActor in
                completion(NewTaskPanel.ProjectInfo(target: target, templates: templates))
            }
        }
    }

    nonisolated private static func createTaskWorktree(
        _ request: NewTask.Request,
        handoverFilename: String,
        completion: @escaping @MainActor @Sendable (TaskWorktreeResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = makeTaskWorktree(request, handoverFilename: handoverFilename)
            DispatchQueue.main.async { @MainActor in
                completion(result)
            }
        }
    }

    nonisolated private static func makeTaskWorktree(_ request: NewTask.Request, handoverFilename: String) -> TaskWorktreeResult {
        let target = request.target
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
            description: request.description, template: request.template, branch: request.branch,
            start: start, subdirectory: target.subdirectory
        )
        guard handover.utf8.count <= HandoverFile.maxBytes else {
            return .failed("The task and its template are longer than 1 MB: shorten them.")
        }
        let (path, error) = GitWorktree.create(branch: request.branch, repoRoot: target.repository, newBranchFrom: target.startPoint)
        guard let path else { return .failed(error ?? "git worktree add failed") }
        GitWorktree.ensureExcluded(excludedHandovers, repoRoot: target.repository)
        let workingDirectory = NewTask.workingDirectory(in: path, subdirectory: target.subdirectory)
        // Where the agent starts: its prompt names the file, not a path.
        var handoverError: HandoverFile.TransferError?
        if case .failure(let failure) = HandoverFile.deliver(handover, toDirectory: workingDirectory, filename: handoverFilename) {
            handoverError = failure
        }
        return .created(CreatedTaskWorktree(
            path: path,
            workingDirectory: workingDirectory,
            // Read back from the checkout: the session is named after the
            // branch it will actually work on (see `SessionName`).
            checkedOutBranch: GitWorktree.currentBranch(at: path),
            handover: handover,
            handoverError: handoverError,
            gitWarning: error
        ))
    }
}

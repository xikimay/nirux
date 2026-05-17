import AppKit

/// File tree shown to the left of the Monaco editor. Wraps an `NSOutlineView`
/// and loads directory children lazily so opening the editor on a large repo
/// doesn't pay an upfront recursive scan — only what the user expands gets
/// read from disk.
@MainActor
final class EditorFileTree: NSView {

    var onFilePicked: ((String) -> Void)?
    var onDiffPicked: ((String, EditorDiffMode) -> Void)?
    var onDiffCollectionPicked: ((String, [String], EditorDiffMode) -> Void)?

    private let changesHeader = NSTextField(labelWithString: "Source Control")
    private let filesHeader = NSTextField(labelWithString: "Files")
    private let changesScrollView = NSScrollView()
    private let filesScrollView = NSScrollView()
    private let changesOutline = ContextOutlineView()
    private let filesOutline = ContextOutlineView()
    private let sectionDivider = NSView()
    private var changeRootChildren: [FileNode] = []
    private var workspaceChildren: [FileNode] = []
    private var gitChanges: [GitChange] = []
    private var branchChanges: [GitChange] = []
    private var gitChangeGeneration = 0
    let workspaceCwd: String

    init(workspaceCwd: String) {
        self.workspaceCwd = workspaceCwd
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1).cgColor

        configureHeaders()
        configureOutline(changesOutline)
        configureOutline(filesOutline)
        configureScroll(changesScrollView, outline: changesOutline)
        configureScroll(filesScrollView, outline: filesOutline)
        configureDivider()
        loadRoot()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureHeaders() {
        for header in [changesHeader, filesHeader] {
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = NSColor.white.withAlphaComponent(0.42)
            header.backgroundColor = .clear
            header.isBordered = false
            header.isEditable = false
            header.lineBreakMode = .byTruncatingTail
            addSubview(header)
        }
    }

    private func configureOutline(_ outline: ContextOutlineView) {
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.rowHeight = 22
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.selectionHighlightStyle = .regular
        outline.style = .plain
        outline.allowsMultipleSelection = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.doubleAction = #selector(rowDoubleClicked(_:))
        outline.menuForRow = { [weak self] row in
            self?.contextMenu(forRow: row, in: outline)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        column.width = 200
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
    }

    private func configureScroll(_ scrollView: NSScrollView, outline: NSOutlineView) {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = outline
        // Frame-based layout (matches the rest of Nirux). Mixing Auto Layout
        // constraints into a frame-based superview produced an infinite
        // constraint-update cycle that crashed when the sidebar reloaded.
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    private func configureDivider() {
        sectionDivider.wantsLayer = true
        sectionDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        addSubview(sectionDivider)
    }

    override func layout() {
        super.layout()
        let headerH: CGFloat = 24
        let dividerH: CGFloat = 1
        let changeRows = CGFloat(changeRootChildren.reduce(0) { partial, node in
            partial + 1 + (changesOutline.isItemExpanded(node) ? (node.children?.count ?? 0) : 0)
        })
        let hasChanges = !changeRootChildren.isEmpty
        let minChangesH = headerH + 88
        let idealChangesH = headerH + min(max(changeRows * changesOutline.rowHeight, 88), 280)
        let maxChangesH = max(minChangesH, bounds.height * 0.46)
        let changesTotalH = hasChanges ? min(idealChangesH, maxChangesH) : 0

        changesHeader.isHidden = !hasChanges
        changesScrollView.isHidden = !hasChanges
        sectionDivider.isHidden = !hasChanges

        var y = bounds.height
        if hasChanges {
            y -= headerH
            changesHeader.frame = NSRect(x: 12, y: y, width: max(0, bounds.width - 24), height: headerH)
            y -= changesTotalH - headerH
            changesScrollView.frame = NSRect(x: 0, y: y, width: bounds.width, height: changesTotalH - headerH)
            y -= dividerH
            sectionDivider.frame = NSRect(x: 0, y: y, width: bounds.width, height: dividerH)
        }

        y -= headerH
        filesHeader.frame = NSRect(x: 12, y: max(0, y), width: max(0, bounds.width - 24), height: headerH)
        filesScrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, y))
    }

    // MARK: - Loading

    private func loadRoot() {
        let url = URL(fileURLWithPath: workspaceCwd)
        workspaceChildren = FileNode.children(of: url) ?? []
        rebuildRootChildren()
        filesOutline.reloadData()
        reloadGitChanges()
    }

    /// Refresh the tree from disk. Cheap if the user hasn't expanded much.
    func reload() {
        let expanded = expandedRelativePaths()
        let url = URL(fileURLWithPath: workspaceCwd)
        workspaceChildren = FileNode.children(of: url) ?? []
        rebuildRootChildren()
        filesOutline.reloadData()
        for path in expanded { expand(relativePath: path) }
        reloadGitChanges()
    }

    /// Refresh the virtual "Changes" section from `git status`.
    func reloadGitChanges() {
        gitChangeGeneration += 1
        let generation = gitChangeGeneration
        let cwd = workspaceCwd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let changes = Self.loadGitChanges(cwd: cwd)
            let branchChanges = Self.loadBranchChanges(cwd: cwd, worktreeChanges: changes)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.gitChangeGeneration == generation else { return }
                self.gitChanges = changes
                self.branchChanges = branchChanges
                self.rebuildRootChildren()
            }
        }
    }

    private func rebuildRootChildren() {
        var virtualRoots: [FileNode] = []
        if !gitChanges.isEmpty {
            let changeNodes = gitChanges.map { change in
                FileNode(
                    url: URL(fileURLWithPath: (workspaceCwd as NSString).appendingPathComponent(change.relativePath)),
                    name: change.relativePath,
                    isDirectory: false,
                    gitStatus: change.status,
                    preferredDiffMode: .head,
                    isVirtual: true
                )
            }
            let changesRoot = FileNode(
                url: URL(fileURLWithPath: workspaceCwd),
                name: "Uncommitted Changes (\(gitChanges.count))",
                isDirectory: true,
                children: changeNodes,
                preferredDiffMode: .head,
                isVirtual: true
            )
            virtualRoots.append(changesRoot)
        }
        if !branchChanges.isEmpty {
            let branchNodes = branchChanges.map { change in
                FileNode(
                    url: URL(fileURLWithPath: (workspaceCwd as NSString).appendingPathComponent(change.relativePath)),
                    name: change.relativePath,
                    isDirectory: false,
                    gitStatus: change.status,
                    preferredDiffMode: .branch,
                    isVirtual: true
                )
            }
            let branchRoot = FileNode(
                url: URL(fileURLWithPath: workspaceCwd),
                name: "Full Branch Diff (\(branchChanges.count))",
                isDirectory: true,
                children: branchNodes,
                preferredDiffMode: .branch,
                isVirtual: true
            )
            virtualRoots.append(branchRoot)
        }
        changeRootChildren = virtualRoots
        changesOutline.reloadData()
        if let changesRoot = virtualRoots.first {
            changesOutline.expandItem(changesRoot)
        }
        needsLayout = true
    }

    /// Expand the tree to reveal `absolutePath` and select it.
    func reveal(absolutePath: String) {
        guard absolutePath.hasPrefix(workspaceCwd) else { return }
        let relative = String(absolutePath.dropFirst(workspaceCwd.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return }

        let parts = relative.components(separatedBy: "/")
        var siblings = workspaceChildren
        var currentNode: FileNode?
        var pathSoFar = ""

        for (i, part) in parts.enumerated() {
            guard let match = siblings.first(where: { $0.name == part }) else { return }
            currentNode = match
            pathSoFar = pathSoFar.isEmpty ? part : "\(pathSoFar)/\(part)"
            // Expand every ancestor (everything except the leaf, which is the
            // file the user just opened).
            if i < parts.count - 1 {
                if match.isDirectory {
                    if match.children == nil {
                        match.children = FileNode.children(of: match.url) ?? []
                    }
                    filesOutline.expandItem(match)
                    siblings = match.children ?? []
                }
            }
        }

        if let node = currentNode {
            let row = filesOutline.row(forItem: node)
            if row >= 0 {
                filesOutline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                filesOutline.scrollRowToVisible(row)
            }
        }
    }

    private func expandedRelativePaths() -> [String] {
        var out: [String] = []
        for row in 0..<filesOutline.numberOfRows {
            guard let node = filesOutline.item(atRow: row) as? FileNode,
                  !node.isVirtual,
                  filesOutline.isItemExpanded(node)
            else { continue }
            out.append(relativePath(of: node))
        }
        return out
    }

    private func relativePath(of node: FileNode) -> String {
        let abs = node.url.path
        guard abs.hasPrefix(workspaceCwd) else { return node.name }
        return String(abs.dropFirst(workspaceCwd.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func expand(relativePath: String) {
        let parts = relativePath.components(separatedBy: "/")
        var siblings = workspaceChildren
        for part in parts {
            guard let match = siblings.first(where: { $0.name == part && $0.isDirectory }) else { return }
            if match.children == nil {
                match.children = FileNode.children(of: match.url) ?? []
            }
            filesOutline.expandItem(match)
            siblings = match.children ?? []
        }
    }

    // MARK: - Click handlers

    @objc private func rowClicked(_ sender: NSOutlineView) {
        commitSelection(in: sender)
    }

    @objc private func rowDoubleClicked(_ sender: NSOutlineView) {
        commitSelection(in: sender)
    }

    private func commitSelection(in outline: NSOutlineView) {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return }
        if node.isDirectory {
            if node.isVirtual, let preferredDiffMode = node.preferredDiffMode {
                if !outline.isItemExpanded(node) {
                    outline.expandItem(node)
                }
                let paths = node.children?.map(\.url.path) ?? []
                onDiffCollectionPicked?(node.name, paths, preferredDiffMode)
                return
            }
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        } else {
            if let preferredDiffMode = node.preferredDiffMode {
                onDiffPicked?(node.url.path, preferredDiffMode)
            } else {
                onFilePicked?(node.url.path)
            }
        }
    }

    // MARK: - Right-click context menu

    /// Build the right-click menu for `row`, or for the workspace root if
    /// `row < 0` (right-click in the empty area below the file list).
    fileprivate func contextMenu(forRow row: Int, in outline: NSOutlineView) -> NSMenu? {
        let node = outline.item(atRow: row) as? FileNode
        let menu = NSMenu()

        if let node {
            if node.isVirtual, node.isDirectory { return nil }
            menu.addItem(makeItem(title: "Copy Relative Path",
                                  action: #selector(copyRelativePathAction(_:)), node: node))
            if !node.isDirectory {
                if !node.isVirtual {
                    menu.insertItem(makeItem(title: "Copy Path",
                                             action: #selector(copyPathAction(_:)), node: node), at: 0)
                    menu.insertItem(makeItem(title: "Reveal in Finder",
                                             action: #selector(revealInFinderAction(_:)), node: node), at: 0)
                }
                menu.addItem(.separator())
                menu.addItem(makeItem(title: "Open Diff with HEAD",
                                      action: #selector(openHeadDiffAction(_:)), node: node))
                menu.addItem(makeItem(title: "Open Branch Diff",
                                      action: #selector(openBranchDiffAction(_:)), node: node))
            }
            if node.isVirtual {
                return menu.items.isEmpty ? nil : menu
            }
            menu.addItem(.separator())
        }

        // New File / New Folder always available — when no node is clicked we
        // create at the workspace root, otherwise at the node's directory
        // (or its parent directory if the node is a file).
        let target: FileNode? = node
        menu.addItem(makeItem(title: "New File…",
                              action: #selector(newFileAction(_:)), node: target))
        menu.addItem(makeItem(title: "New Folder…",
                              action: #selector(newFolderAction(_:)), node: target))

        if let node {
            menu.addItem(.separator())
            menu.addItem(makeItem(title: "Rename…",
                                  action: #selector(renameAction(_:)), node: node))
            menu.addItem(makeItem(title: "Move to Trash",
                                  action: #selector(trashAction(_:)), node: node))
        }

        return menu.items.isEmpty ? nil : menu
    }

    private func makeItem(title: String, action: Selector, node: FileNode?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = node
        return item
    }

    @objc private func revealInFinderAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPathAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        copyToPasteboard(node.url.path)
    }

    @objc private func copyRelativePathAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let abs = node.url.path
        let rel: String
        if abs.hasPrefix(workspaceCwd) {
            rel = String(abs.dropFirst(workspaceCwd.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            rel = abs
        }
        copyToPasteboard(rel)
    }

    @objc private func openHeadDiffAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode, !node.isDirectory else { return }
        onDiffPicked?(node.url.path, .head)
    }

    @objc private func openBranchDiffAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode, !node.isDirectory else { return }
        onDiffPicked?(node.url.path, .branch)
    }

    @objc private func newFileAction(_ sender: NSMenuItem) {
        let parent = parentDir(for: sender.representedObject as? FileNode)
        guard let name = promptForName(title: "New File", initial: "") else { return }
        let target = parent.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            beep("File already exists")
            return
        }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        reload()
        onFilePicked?(target.path)
    }

    @objc private func newFolderAction(_ sender: NSMenuItem) {
        let parent = parentDir(for: sender.representedObject as? FileNode)
        guard let name = promptForName(title: "New Folder", initial: "") else { return }
        let target = parent.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            beep("Could not create folder: \(error.localizedDescription)")
            return
        }
        reload()
    }

    @objc private func renameAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        guard let newName = promptForName(title: "Rename", initial: node.name),
              newName != node.name
        else { return }
        let target = node.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: node.url, to: target)
        } catch {
            beep("Rename failed: \(error.localizedDescription)")
            return
        }
        reload()
    }

    @objc private func trashAction(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let alert = NSAlert()
        alert.messageText = "Move \"\(node.name)\" to Trash?"
        alert.informativeText = node.url.path
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            beep("Could not move to trash: \(error.localizedDescription)")
            return
        }
        reload()
    }

    /// Pick the directory new files/folders should go into. If the click was
    /// on a directory node we drop new entries inside it; on a file we drop
    /// next to it; with no node we use the workspace root.
    private func parentDir(for node: FileNode?) -> URL {
        guard let node else { return URL(fileURLWithPath: workspaceCwd) }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    private func copyToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    private func beep(_ message: String) {
        NSSound.beep()
        NSLog("[EditorFileTree] %@", message)
    }

    private nonisolated static func loadGitChanges(cwd: String) -> [GitChange] {
        guard let output = runGit(["status", "--porcelain", "--untracked-files=all"], cwd: cwd) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { GitChange.parsePorcelain(String($0)) }
            .sorted { lhs, rhs in
                lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
            }
    }

    private nonisolated static func loadBranchChanges(
        cwd: String,
        worktreeChanges: [GitChange]
    ) -> [GitChange] {
        guard let base = branchBaseRef(cwd: cwd),
              let output = runGit(["diff", "--name-status", base, "--"], cwd: cwd)
        else { return [] }

        var changesByPath: [String: GitChange] = [:]
        for change in output
            .split(separator: "\n")
            .compactMap({ GitChange.parseNameStatus(String($0)) }) {
            changesByPath[change.relativePath] = change
        }
        for change in worktreeChanges where change.status == .untracked {
            changesByPath[change.relativePath] = change
        }
        return changesByPath.values.sorted { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private nonisolated static func branchBaseRef(cwd: String) -> String? {
        for candidate in ["@{upstream}", "origin/main", "origin/master", "main", "master"] {
            guard let output = runGit(["merge-base", "HEAD", candidate], cwd: cwd) else { continue }
            let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return sha }
        }
        return nil
    }

    private nonisolated static func runGit(_ arguments: [String], cwd: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Modal name prompt used by New File / New Folder / Rename. Returns
    /// `nil` if the user cancelled or entered an empty name.
    private func promptForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        // Focus the field on next runloop tick — assigning before runModal
        // doesn't take effect because the alert window isn't key yet.
        DispatchQueue.main.async { [weak field] in
            field?.window?.makeFirstResponder(field)
            field?.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Git changes

private struct GitChange: Equatable, Sendable {
    let status: GitChangeStatus
    let relativePath: String

    static func parsePorcelain(_ porcelainLine: String) -> GitChange? {
        guard porcelainLine.count >= 4 else { return nil }
        let indexStatus = porcelainLine[porcelainLine.startIndex]
        let worktreeStatus = porcelainLine[porcelainLine.index(after: porcelainLine.startIndex)]
        let rawPath = String(porcelainLine.dropFirst(3))
        let path = normalizePath(rawPath)
        guard !path.isEmpty else { return nil }
        return GitChange(
            status: GitChangeStatus(index: indexStatus, worktree: worktreeStatus),
            relativePath: path
        )
    }

    static func parseNameStatus(_ line: String) -> GitChange? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard let rawStatus = parts.first?.first else { return nil }
        let rawPath = String(parts.last ?? "")
        let path = normalizePath(rawPath)
        guard !path.isEmpty else { return nil }
        return GitChange(
            status: GitChangeStatus(diffStatus: rawStatus),
            relativePath: path
        )
    }

    private static func normalizePath(_ raw: String) -> String {
        let renamedPath = raw.components(separatedBy: " -> ").last ?? raw
        return renamedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}

private enum GitChangeStatus: Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case untracked
    case conflicted

    init(diffStatus: Character) {
        switch diffStatus {
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "U": self = .conflicted
        default: self = .modified
        }
    }

    init(index: Character, worktree: Character) {
        if index == "?" && worktree == "?" {
            self = .untracked
        } else if index == "U" || worktree == "U" {
            self = .conflicted
        } else if index == "D" || worktree == "D" {
            self = .deleted
        } else if index == "R" || worktree == "R" {
            self = .renamed
        } else if index == "A" || worktree == "A" {
            self = .added
        } else {
            self = .modified
        }
    }

    var badge: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .conflicted: return "!"
        }
    }

    var color: NSColor {
        switch self {
        case .modified: return NSColor.systemOrange
        case .added, .untracked: return NSColor.systemGreen
        case .deleted: return NSColor.systemRed
        case .renamed: return NSColor.systemBlue
        case .conflicted: return NSColor.systemPurple
        }
    }
}

// MARK: - Outline view subclass with row-aware right-click menu

private final class ContextOutlineView: NSOutlineView {
    /// Returns the menu to show for the row under the right-click. `row` is
    /// `-1` when the click landed on empty area below the rows.
    var menuForRow: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        // Select the clicked row so the user has visual feedback while the
        // menu is open. Skip when the click was outside any row.
        if row >= 0 {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuForRow?(row)
    }
}

// MARK: - Outline data source

extension EditorFileTree: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? FileNode else {
            return rootNodes(for: outlineView).count
        }
        if node.children == nil && node.isDirectory {
            node.children = FileNode.children(of: node.url) ?? []
        }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let roots = rootNodes(for: outlineView)
        guard let node = item as? FileNode else { return roots[index] }
        return node.children?[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    private func rootNodes(for outlineView: NSOutlineView) -> [FileNode] {
        outlineView === changesOutline ? changeRootChildren : workspaceChildren
    }
}

// MARK: - Outline delegate

extension EditorFileTree: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileTreeCellView)
            ?? FileTreeCellView()
        cell.identifier = identifier
        cell.configure(node: node)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        FileTreeRowView()
    }
}

// MARK: - File node

@MainActor
private final class FileNode {
    let url: URL
    let name: String
    let isDirectory: Bool
    let gitStatus: GitChangeStatus?
    let preferredDiffMode: EditorDiffMode?
    let isVirtual: Bool
    var children: [FileNode]?

    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        children: [FileNode]? = nil,
        gitStatus: GitChangeStatus? = nil,
        preferredDiffMode: EditorDiffMode? = nil,
        isVirtual: Bool = false
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.children = children
        self.gitStatus = gitStatus
        self.preferredDiffMode = preferredDiffMode
        self.isVirtual = isVirtual
    }

    /// Lists `url`'s children with the editor's ignore rules and dir-first sort.
    /// Includes hidden files (`.env`, `.gitignore`, etc.) — they're routinely
    /// the target of an edit. Noisy dotdirs like `.git` / `.build` are still
    /// filtered out via `WorkspaceFileScanner.skipDirs`.
    static func children(of url: URL) -> [FileNode]? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys
        ) else { return nil }

        var nodes: [FileNode] = []
        nodes.reserveCapacity(urls.count)
        for child in urls {
            let name = child.lastPathComponent
            if WorkspaceFileScanner.skipFiles.contains(name) { continue }

            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            if isDir, WorkspaceFileScanner.skipDirs.contains(name) { continue }

            nodes.append(FileNode(url: child, name: name, isDirectory: isDir))
        }

        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return nodes
    }
}

// MARK: - Cell view (icon + name)

private final class FileTreeCellView: NSTableCellView {
    private let iconLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconLabel.font = .systemFont(ofSize: 11)
        iconLabel.alignment = .center
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.textColor = NSColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 1)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(iconLabel)
        addSubview(nameLabel)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        iconLabel.frame = NSRect(x: 2, y: 2, width: 16, height: bounds.height - 4)
        nameLabel.frame = NSRect(x: 20, y: 2, width: bounds.width - 24, height: bounds.height - 4)
    }

    func configure(node: FileNode) {
        if let gitStatus = node.gitStatus {
            iconLabel.stringValue = gitStatus.badge
            iconLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
            iconLabel.textColor = gitStatus.color
            nameLabel.stringValue = node.name
            nameLabel.textColor = NSColor.white.withAlphaComponent(0.9)
            nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
            return
        }

        iconLabel.font = .systemFont(ofSize: 11)
        iconLabel.stringValue = node.isDirectory ? "▸" : "·"
        iconLabel.textColor = node.isDirectory
            ? NSColor(red: 0.55, green: 0.70, blue: 1.0, alpha: node.isVirtual ? 0.95 : 0.7)
            : NSColor.secondaryLabelColor
        nameLabel.stringValue = node.name
        nameLabel.textColor = node.isVirtual
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor(red: 0.85, green: 0.88, blue: 0.95, alpha: 1)
        nameLabel.font = .systemFont(ofSize: 12, weight: node.isVirtual ? .semibold : .regular)
    }
}

/// Row view that paints the same accent highlight as the file picker.
private final class FileTreeRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        if selectionHighlightStyle != .none {
            NSColor.niruxAccent.withAlphaComponent(0.18).setFill()
            bounds.fill()
        }
    }
    override var isEmphasized: Bool { get { true } set {} }
}

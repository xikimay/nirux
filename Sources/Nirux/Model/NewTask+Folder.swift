import Foundation

// MARK: - Tasks without a repository

/// A task without a repository gets a new folder of its own instead of a
/// worktree (docs/spaces.md, "Tasks without a repository"): named after the
/// task, in the tasks folder (Settings › General, `~/Nirux Tasks` unless the
/// user picks another), in a space's folder outside git, or in the folder of
/// the task it is a sub-task of. No branch, no pull request, no clean-up:
/// Nirux never deletes it.
extension NewTask {
    /// The tasks folder in the home folder, unless the user picks another.
    static let defaultTasksFolderName = "Nirux Tasks"
    /// Longest folder name Nirux suggests, in characters.
    static let maxFolderNameLength = 50
    /// Longest folder name, in UTF-8 bytes: APFS takes 255, and "name 999"
    /// must fit too.
    static let maxFolderNameBytes = 200
    /// Past it, the folder's name is taken that many times: something is
    /// wrong, and Nirux stops looking.
    static let maxFolderAttempts = 999

    /// The folder's name from the description's first line (see
    /// `cleanedFolderName`), cut at a whole word. "Task" when nothing is
    /// left.
    static func suggestedFolderName(description: String) -> String {
        let words = (firstLine(of: description) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        var name = ""
        for word in words {
            let candidate = name.isEmpty ? word : name + " " + word
            guard candidate.count <= maxFolderNameLength else { break }
            name = candidate
        }
        if name.isEmpty, let first = words.first { name = String(first.prefix(maxFolderNameLength)) }
        return cleanedFolderName(name) ?? "Task"
    }

    /// `name` as a folder's name: whitespace runs and control characters
    /// become one space, "/" and ":" a "-" (Finder shows a ":" as "/"), no
    /// leading "." (a hidden folder), "..", or spaces at either end, at most
    /// `maxFolderNameBytes`. Nil when nothing is left.
    static func cleanedFolderName(_ name: String) -> String? {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in name.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar == "/" || scalar == ":" ? "-" : scalar)
        }
        var cleaned = String(scalars)
        while cleaned.hasPrefix(".") || cleaned.hasPrefix(" ") { cleaned.removeFirst() }
        while cleaned.utf8.count > maxFolderNameBytes { cleaned.removeLast() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Makes the folder `name` in `parent`, and `parent` when it is
    /// missing; `name 2`, `name 3`… when the name is taken (in any case:
    /// the volume may not tell them apart), so it is always a new, empty
    /// folder. Its path, or why it failed.
    static func makeFolder(named name: String, in parent: String) -> Result<String, MakeFolderError> {
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            return .failure(MakeFolderError(message: "Couldn’t make \(parent.abbreviatedPath()): \(error.localizedDescription)"))
        }
        for attempt in 1...maxFolderAttempts {
            let path = (parent as NSString).appendingPathComponent(attempt == 1 ? name : "\(name) \(attempt)")
            // mkdir, not FileManager: it fails on any name already there,
            // a link too, which is what tells a free name.
            if mkdir(path, 0o755) == 0 { return .success(path) }
            let code = errno
            guard code == EEXIST else {
                let reason = String(cString: strerror(code))
                return .failure(MakeFolderError(message: "Couldn’t make the folder in \(parent.abbreviatedPath()): \(reason)."))
            }
        }
        return .failure(MakeFolderError(message: "\(parent.abbreviatedPath()) already holds \(maxFolderAttempts) folders named “\(name)”."))
    }

    struct MakeFolderError: Error, Equatable, Sendable {
        let message: String
    }

    /// The handover of a task in a folder of its own: the description as
    /// the user typed it, then the template's way of working.
    static func folderHandover(description: String, template: TaskTemplates.Template?, folder: String) -> String {
        let title = workspaceTitle(description: description) ?? (folder as NSString).lastPathComponent
        var text = """
        # Task: \(title)

        The user started this session from Nirux (⌘N) for the task below, in `\(folder)`, a new folder \
        Nirux made for it: no repository, no branch. This file is for you only.

        ## Task

        \(description.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        if let template, !template.body.isEmpty {
            text += """

            ## How to proceed (template “\(template.name)”)

            \(template.body)

            """
        }
        return text
    }
}

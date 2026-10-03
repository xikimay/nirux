import Foundation

/// A project's task templates: ways of working that New Task… adds to the
/// handover after the task's description ("reproduce, write a failing test,
/// fix"). They live next to the brief, in
/// `<state dir>/projects/<space id>/task-templates.md`, one `## Name`
/// section per template, and are edited as Markdown from the project's menu.
///
/// Until that file exists, the form offers `defaults`; the first Edit Task
/// Templates… writes them to it.
enum TaskTemplates {
    static let fileName = "task-templates.md"

    struct Template: Equatable, Sendable {
        let name: String
        /// The section's text, trimmed; may be empty.
        let body: String
    }

    static let defaults: [Template] = [
        Template(
            name: "Bugfix",
            body: """
            1. Reproduce the bug first, and say how.
            2. Write a test that fails because of it.
            3. Fix the cause, not the symptom, then show the test passes along with the existing ones.
            """
        ),
        Template(
            name: "Feature (full review cycle)",
            body: """
            1. Read the code this touches, and ask before any product or UX decision that isn't obvious.
            2. Implement it with tests, following the conventions of the surrounding code.
            3. Before opening the pull request: two adversarial reviews by fresh agents with distinct angles, \
            a premortem, fixes, then a confirmation review.
            4. Open one pull request for this change, and don't merge it.
            """
        ),
        Template(
            name: "Investigation (no code)",
            body: """
            Investigate only: don't change any file in the repository, and don't commit.
            Report what you find, with evidence (files and lines, commands and their output), \
            what you're unsure of, and the options to act on it.
            """
        )
    ]

    static func fileURL(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> URL? {
        SpaceBrief.directory(spaceID: spaceID, stateDirectory: stateDirectory)?.appendingPathComponent(fileName)
    }

    /// The templates New Task… offers for a space: the file's, or `defaults`
    /// while it doesn't exist. A file that can't be read (not a regular file,
    /// larger than `SpaceBrief.maxFileBytes`, not UTF-8) offers none: its
    /// owner meant to replace the defaults. Reads the disk: call it off the main thread.
    static func load(spaceID: String, stateDirectory: URL = Persistence.stateDirectory) -> [Template] {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory) else { return defaults }
        switch BoardConfigStore.read(url.resolvingSymlinksInPath(), maxBytes: SpaceBrief.maxFileBytes) {
        case .missing: return defaults
        case .notARegularFile, .tooLarge, .unreadableBytes: return []
        case .data(let data): return String(bytes: data, encoding: .utf8).map(parse) ?? []
        }
    }

    /// Creates the file with `defaults` and an explanatory comment when it
    /// doesn't exist yet, and returns its URL.
    static func ensureFile(
        spaceID: String, spaceName: String, stateDirectory: URL = Persistence.stateDirectory
    ) throws -> URL? {
        guard let url = fileURL(spaceID: spaceID, stateDirectory: stateDirectory) else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(template(spaceName: spaceName).utf8).write(to: url, options: .atomic)
        }
        return url
    }

    /// The `## Name` sections of `text`, in order. HTML comments are dropped
    /// first (an unclosed `<!--` stays text, as in the brief); a `## ` line
    /// inside a fenced code block belongs to the template above it. A name
    /// used twice keeps its first section.
    static func parse(_ text: String) -> [Template] {
        var templates: [Template] = []
        var name: String?
        var lines: [Substring] = []
        var fence: Substring?
        func flush() {
            guard let name, !templates.contains(where: { $0.name == name }) else { return }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            templates.append(Template(name: name, body: body))
        }
        for line in withoutComments(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
            } else if line.hasPrefix("## ") {
                flush()
                let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                name = heading.isEmpty ? nil : heading
                lines = []
                continue
            }
            lines.append(line)
        }
        flush()
        return templates
    }

    private static func withoutComments(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<!--"),
              let close = rest[open.upperBound...].range(of: "-->") {
            result += rest[..<open.lowerBound]
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    private static func template(spaceName: String) -> String {
        // A "-->" in the name would end the comment.
        var name = spaceName
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        let sections = defaults.map { "## \($0.name)\n\n\($0.body)\n" }.joined(separator: "\n")
        return """
        <!--
        Task templates for the project "\(name)". New Task… (Cmd+P) offers each
        "## Name" section below; the one picked goes into the new workspace's
        handover, after the task's description. Add, edit or delete sections
        freely. Text inside this comment is ignored.
        Deleting the project leaves this file here.
        -->

        \(sections)
        """
    }
}

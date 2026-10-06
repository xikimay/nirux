import Foundation

// MARK: - Claude's notes under the hunks (section 4.3)

extension BranchReview.FileDiff {
    /// A note of Claude's, under the last changed line of the hunk it
    /// explains: what pierre draws as a line annotation.
    struct Note: Encodable, Equatable, Sendable {
        /// The note's id in the review file: what marking it wrong names.
        let id: String
        /// "additions" or "deletions", and the line's number on that side.
        let side: String
        let lineNumber: Int
        let text: String
        /// What the reviewer should verify, when Claude thinks something
        /// may be wrong.
        let check: String?
        let isWrong: Bool
        /// "Opus 5.5", and the head its run read.
        let model: String
        let head: String
    }
}

extension BranchReview {
    /// The notes Explain kept for `file`, each under its hunk, found by the
    /// hunk's anchor (its changed lines): hunks merge or split when the
    /// base changes the lines between them, so a note whose hunk no longer
    /// is in the diff isn't shown.
    static func diffNotes(for file: FileChange, explanation: Explanation?) -> [FileDiff.Note] {
        guard let entry = explanation?.files[file.path], !entry.notes.isEmpty, !file.hunks.isEmpty else { return [] }
        let anchors = hunkAnchors(of: file.hunks)
        let model = ExplainSettings.displayName(of: entry.model ?? explanation?.model ?? "")
        return entry.notes.compactMap { note in
            guard let anchor = note.anchor, let index = anchors.firstIndex(of: anchor),
                  let line = lastChangedLine(of: file.hunks[index])
            else { return nil }
            return FileDiff.Note(
                id: note.id, side: line.side, lineNumber: line.number, text: note.text, check: note.check,
                isWrong: note.isWrong, model: model, head: entry.head ?? explanation?.head ?? ""
            )
        }
    }

    /// The hunk's last added or removed line: its side and number there.
    static func lastChangedLine(of hunk: Hunk) -> (side: String, number: Int)? {
        var old = hunk.oldStart
        var new = hunk.newStart
        var last: (side: String, number: Int)?
        for line in hunk.lines {
            switch line.kind {
            case .context:
                old += 1
                new += 1
            case .removed:
                last = ("deletions", old)
                old += 1
            case .added:
                last = ("additions", new)
                new += 1
            case .noNewlineMarker:
                break
            }
        }
        return last
    }
}

extension BranchReview.Explanation {
    /// What the notes on the page come from, by path: a change to anything
    /// else (runs, summaries) leaves the diffs drawn as they are.
    struct FileNotes: Equatable {
        let notes: [NoteEntry]
        let model: String?
        let head: String?
    }

    var notesShown: [String: FileNotes] {
        files.filter { !$0.value.notes.isEmpty }.mapValues { FileNotes(notes: $0.notes, model: $0.model, head: $0.head) }
    }

    /// The file whose notes hold `id`.
    func path(ofNote id: String) -> String? {
        files.first { $0.value.notes.contains { $0.id == id } }?.key
    }

    func note(id: String) -> NoteEntry? {
        path(ofNote: id).flatMap { files[$0]?.notes.first { $0.id == id } }
    }

    /// These notes without their marks: what changes when only marks do.
    var withoutMarks: Self {
        var unmarked = self
        unmarked.wrongCount = 0
        for (path, entry) in files {
            var entry = entry
            for index in entry.notes.indices { entry.notes[index].isWrong = false }
            unmarked.files[path] = entry
        }
        return unmarked
    }

    /// Marks the note `id` wrong, or not, and counts it: how often notes
    /// were wrong, since the first Explain. False when nothing changed.
    @discardableResult
    mutating func mark(note id: String, wrong: Bool) -> Bool {
        guard let path = path(ofNote: id), var entry = files[path],
              let index = entry.notes.firstIndex(where: { $0.id == id }), entry.notes[index].isWrong != wrong
        else { return false }
        entry.notes[index].isWrong = wrong
        files[path] = entry
        wrongCount = max(0, wrongCount + (wrong ? 1 : -1))
        return true
    }
}

import Foundation

/// The name Nirux gives a Claude session it starts in a new worktree
/// workspace (`claude --name`). It is the session title on claude.ai, in the
/// Claude app and in `claude --resume`, which would otherwise all read like
/// the handover prompt (".claude-handover.md").
///
/// A name freezes that title: Claude Code stops deriving it from the prompt.
/// So Nirux names only sessions whose label is stable, the branch of a
/// worktree, and leaves every other session to Claude Code's own title.
enum SessionName {
    /// Phone session lists truncate long titles anyway.
    static let maxLabelLength = 60
    static let maxSpaceLength = 30

    /// `<branch> · <space>`, or nil without a worktree branch.
    /// - Parameters:
    ///   - worktreeBranch: branch checked out in the worktree, read when the
    ///     workspace was created.
    ///   - spaceName: name of the space the workspace belongs to.
    ///   - isDefaultSpace: the space is the built-in default one, whose
    ///     default name ("main") would read like a branch.
    static func make(worktreeBranch: String?, spaceName: String?, isDefaultSpace: Bool) -> String? {
        guard let label = worktreeBranch.flatMap({ cleaned($0, maxLength: maxLabelLength) }) else {
            return nil
        }
        guard let space = spaceName.flatMap({ cleaned($0, maxLength: maxSpaceLength) }),
              !(isDefaultSpace && space == WorkspaceProfile.defaultProfile.name),
              space.caseInsensitiveCompare(label) != .orderedSame
        else { return label }
        // Distinctive part first, for the same truncation reason.
        return "\(label) · \(space)"
    }

    /// Whitespace and C0/C1 control characters collapse to single spaces.
    /// Format characters such as zero-width joiners stay: emoji and some
    /// scripts need them.
    private static let separators: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: Unicode.Scalar(UInt8(0x00))...Unicode.Scalar(UInt8(0x1F)))
        set.insert(charactersIn: Unicode.Scalar(UInt8(0x7F))...Unicode.Scalar(UInt8(0x9F)))
        return set
    }()

    /// Removed outright: bidi overrides and isolates could make the title
    /// read differently from its bytes, `\` leaves fish's single quotes open
    /// and `!` triggers tcsh history expansion inside them. Space names are
    /// free text, so they can hold any of these.
    private static let dropped = CharacterSet(
        charactersIn: "\\!\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
    )

    private static func cleaned(_ text: String, maxLength: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !dropped.contains($0) })
        let words = String(scalars).components(separatedBy: separators).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        guard joined.count > maxLength else { return joined }
        return String(joined.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

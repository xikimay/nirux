import XCTest
@testable import Nirux

/// The Project Memory panel's writes (see ProjectMemory+Writing), on
/// throwaway folders: a memory or a rule added, edited, moved, deleted,
/// while "agents" write the same files.
final class ProjectMemoryWritingTests: XCTestCase {
    private var root: URL!
    private var memory: URL { root.appendingPathComponent("memory") }
    private var brief: URL { root.appendingPathComponent("brief.md") }
    private var index: URL { memory.appendingPathComponent(ProjectMemory.indexFileName) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("project-memory-writing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func memory(_ fileName: String) throws -> ProjectMemory.Memory {
        try XCTUnwrap(ProjectMemory.read(directory: memory)?.memories.first { $0.fileName == fileName })
    }

    /// Records what goes to the Trash, and deletes it.
    private final class TrashBin: @unchecked Sendable {
        private(set) var names: [String] = []
        func trash(_ url: URL) throws {
            names.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Memories

    func testSlug() {
        XCTAssertEqual(ProjectMemory.slug(for: "Café — Release train!"), "cafe-release-train")
        XCTAssertEqual(ProjectMemory.slug(for: "  --  "), "")
        XCTAssertEqual(ProjectMemory.slug(for: String(repeating: "word ", count: 20)).count, 59)
    }

    /// The file, then its line at the end of an index created on first use;
    /// a name taken in any case, `MEMORY.md` included, gets a number; a
    /// title with no letter a file name can use, a plain one.
    func testAddMemory() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z"))
        let first = try ProjectMemory.addMemory(
            title: "Release [train]", description: "Nightly: \"one\" PR\nat a time", text: "Each merge ships.",
            type: .project, in: memory, now: now
        )
        XCTAssertEqual(first, "release-train.md")
        XCTAssertEqual(try text(index), "- [Release (train)](release-train.md) — Nightly: \"one\" PR at a time\n")
        let added = try memory("release-train.md")
        XCTAssertEqual(added.name, "release-train")
        XCTAssertEqual(added.description, "Nightly: \"one\" PR at a time")
        XCTAssertEqual(added.kind, .project)
        XCTAssertEqual(added.body, "Each merge ships.")
        XCTAssertEqual(added.modified, now)

        try write("x", to: memory.appendingPathComponent("Ship-Fast.md"))
        try write("# Index\r\n- [Old](old.md) — kept", to: index)
        XCTAssertEqual(try ProjectMemory.addMemory(title: "ship fast", description: "", text: "t", type: .user, in: memory), "ship-fast-2.md")
        XCTAssertEqual(try ProjectMemory.addMemory(title: "Memory", description: "x", text: "y", type: .user, in: memory), "memory-2.md")
        XCTAssertEqual(try ProjectMemory.addMemory(title: "設計", description: "x", text: "y", type: .user, in: memory), "note.md")
        XCTAssertThrowsError(try ProjectMemory.addMemory(title: "  ", description: "", text: "", type: .user, in: memory)) {
            XCTAssertEqual($0 as? ProjectMemory.WriteError, .emptyTitle)
        }
        // Its own line breaks kept.
        XCTAssertEqual(try text(index), "# Index\r\n- [Old](old.md) — kept\r\n- [ship fast](ship-fast-2.md) — ship fast\r\n"
            + "- [Memory](memory-2.md) — x\r\n- [設計](note.md) — x\r\n")
    }

    /// A new file never replaces one an agent wrote meanwhile, and leaves
    /// no temporary file.
    func testNewFileNeverReplacesAnother() throws {
        let taken = memory.appendingPathComponent("agent.md")
        try write("the agent's", to: taken)
        XCTAssertThrowsError(try ProjectMemory.createFile(Data("ours".utf8), at: taken)) {
            XCTAssertEqual($0 as? ProjectMemory.WriteError, .exists("agent.md"))
        }
        XCTAssertEqual(try text(taken), "the agent's")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: memory.path), ["agent.md"])
    }

    /// An agent writing the index while Nirux changes it keeps its line:
    /// Nirux starts over from what is there, never from its older copy.
    /// Through a link, the link's target is written and the link stays; a
    /// read-only, non-UTF-8 or too large file is never written.
    func testUpdate() throws {
        try write("- [A](a.md) — a\n", to: index)
        var calls = 0
        try ProjectMemory.update(index) { current in
            calls += 1
            if calls == 1 { try "- [A](a.md) — a\n- [Agent](agent.md) — meanwhile\n".write(to: self.index, atomically: true, encoding: .utf8) }
            return current + "- [Ours](ours.md) — ours\n"
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(try text(index), "- [A](a.md) — a\n- [Agent](agent.md) — meanwhile\n- [Ours](ours.md) — ours\n")
        XCTAssertThrowsError(try ProjectMemory.update(index) { current in
            try (current + "x").write(to: self.index, atomically: true, encoding: .utf8)
            return "ours only"
        }) { XCTAssertEqual($0 as? ProjectMemory.WriteError, .changed("MEMORY.md")) }
        XCTAssertFalse(try text(index).contains("ours only"))

        let target = root.appendingPathComponent("real-brief.md")
        try write("- rule A\n", to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: brief, withDestinationURL: target)
        try ProjectMemory.appendRule("rule B", to: brief)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: brief.path), target.path)
        XCTAssertEqual(try text(target), "- rule A\n- rule B\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path))[.posixPermissions] as? Int, 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
        XCTAssertThrowsError(try ProjectMemory.appendRule("rule C", to: target))
        XCTAssertEqual(try text(target), "- rule A\n- rule B\n")

        let latin = root.appendingPathComponent("latin.md")
        try Data([0x2D, 0x20, 0xE9, 0x0A]).write(to: latin)
        XCTAssertThrowsError(try ProjectMemory.appendRule("x", to: latin))
        XCTAssertEqual(try Data(contentsOf: latin), Data([0x2D, 0x20, 0xE9, 0x0A]))

        let large = String(repeating: "x", count: ProjectMemory.maxWrittenBytes + 1)
        try write(large, to: index)
        XCTAssertThrowsError(try ProjectMemory.update(index) { $0 + "y" })
        XCTAssertEqual(try text(index).count, large.count)
    }

    /// Its text replaced, its frontmatter and line breaks kept but for the
    /// date; never over what an agent wrote since the panel read it.
    /// Deleted, it goes to the Trash and its lines leave the index, every
    /// other line as written.
    func testEditAndDeleteMemory() throws {
        try ProjectMemory.addMemory(title: "Keep", description: "k", text: "Kept.", type: .user, in: memory)
        let name = try ProjectMemory.addMemory(title: "Gone soon", description: "g", text: "Old text.", type: .feedback, in: memory)
        let later = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-06T08:00:00Z"))
        try ProjectMemory.replaceMemoryText(fileName: name, in: memory, expected: "Old text.", with: "New **text**.\n\n**Why:** asked.", now: later)
        let edited = try memory(name)
        XCTAssertEqual(edited.body, "New **text**.\n\n**Why:** asked.")
        XCTAssertEqual(edited.kind, .feedback)
        XCTAssertEqual(edited.description, "g")
        XCTAssertEqual(edited.modified, later)
        XCTAssertThrowsError(try ProjectMemory.replaceMemoryText(fileName: name, in: memory, expected: "Old text.", with: "Stale")) {
            XCTAssertEqual($0 as? ProjectMemory.WriteError, .changed(name))
        }
        XCTAssertEqual(try memory(name).body, "New **text**.\n\n**Why:** asked.")

        let windows = memory.appendingPathComponent("windows.md")
        try write("---\r\nname: windows\r\ndescription: w\r\nmetadata:\r\n  type: user\r\n---\r\n\r\nOld.\r\n", to: windows)
        try ProjectMemory.replaceMemoryText(fileName: "windows.md", in: memory, expected: "Old.", with: "New\nlines.")
        XCTAssertEqual(try text(windows), "---\r\nname: windows\r\ndescription: w\r\nmetadata:\r\n  type: user\r\n---\r\n\r\nNew\r\nlines.\r\n")

        let before = try text(index)
        try write(before + "<!-- note -->\n* [Gone again](GONE-SOON.md#x) — twice\n", to: index)
        let bin = TrashBin()
        try ProjectMemory.deleteMemory(fileName: name, in: memory, trash: bin.trash)
        XCTAssertEqual(bin.names, [name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: memory.appendingPathComponent(name).path))
        XCTAssertEqual(try text(index), "- [Keep](keep.md) — k\n<!-- note -->\n")
    }

    // MARK: - Rules

    /// Appended, edited (as the bullet, numbered or not, or the paragraph
    /// it was), deleted; refused when the rule moved, when a comment shares
    /// its lines, or when the brief would pass what sessions get of it.
    func testRules() throws {
        try write("<!-- The brief's comment -->\n\n- One rule.\n- Two\n  lines.\n", to: brief)
        try ProjectMemory.appendRule("Third,\non two lines.", to: brief)
        XCTAssertEqual(try text(brief), "<!-- The brief's comment -->\n\n- One rule.\n- Two\n  lines.\n- Third,\n  on two lines.\n")

        var rules = ProjectMemory.rules(in: try text(brief))
        XCTAssertEqual(rules.map(\.text), ["One rule.", "Two\nlines.", "Third,\non two lines."])
        try ProjectMemory.replaceRule(rules[1], in: brief, with: "Two, edited\nover lines.")
        rules = ProjectMemory.rules(in: try text(brief))
        XCTAssertEqual(rules[1].text, "Two, edited\nover lines.")
        try ProjectMemory.replaceRule(rules[0], in: brief, with: nil)
        XCTAssertEqual(try text(brief), "<!-- The brief's comment -->\n\n- Two, edited\n  over lines.\n- Third,\n  on two lines.\n")

        // Moved since the panel read it: refused, nothing written.
        let stale = ProjectMemory.rules(in: try text(brief))[0]
        try write("- Added by hand.\n" + (try text(brief)), to: brief)
        let edited = try text(brief)
        XCTAssertThrowsError(try ProjectMemory.replaceRule(stale, in: brief, with: "x")) {
            XCTAssertEqual($0 as? ProjectMemory.WriteError, .changed("brief.md"))
        }
        XCTAssertEqual(try text(brief), edited)

        // The marker and the paragraph stay what they were.
        try write("1. Numbered\n   on.\n\n**Bold** paragraph.\n- a <!-- hidden\n  note --> b\n", to: brief)
        rules = ProjectMemory.rules(in: try text(brief))
        try ProjectMemory.replaceRule(rules[1], in: brief, with: "**Bold** paragraph, edited.")
        try ProjectMemory.replaceRule(rules[0], in: brief, with: "Numbered\nstill.")
        XCTAssertEqual(try text(brief), "1. Numbered\n   still.\n\n**Bold** paragraph, edited.\n- a <!-- hidden\n  note --> b\n")
        rules = ProjectMemory.rules(in: try text(brief))
        XCTAssertThrowsError(try ProjectMemory.replaceRule(rules[2], in: brief, with: nil))

        XCTAssertThrowsError(try ProjectMemory.appendRule(String(repeating: "x", count: 50), to: brief, maxCharacters: 60)) {
            XCTAssertEqual($0 as? ProjectMemory.WriteError, .tooLong(60))
        }
        // Already past it: a rule can still shrink.
        try write("- " + String(repeating: "y", count: 80) + "\n", to: brief)
        let long = try XCTUnwrap(ProjectMemory.rules(in: try text(brief)).first)
        try ProjectMemory.replaceRule(long, in: brief, with: String(repeating: "y", count: 70), maxCharacters: 60)
        XCTAssertEqual(try text(brief), "- " + String(repeating: "y", count: 70) + "\n")
    }

    /// Bullets, numbered or not, a code block in one, keep their place
    /// through saves; a bare `-` gets its space back.
    func testSavesKeepIndents() throws {
        let kept = "- Run:\n  ```\n  swift test\n  ```\n1. Use pnpm\n   not npm\n10. Ten\n    on.\n2. Fence:\n   ```\n   make\n   ```\n"
        try write(kept, to: brief)
        for _ in 0..<3 {
            for index in 0..<4 {
                let rule = ProjectMemory.rules(in: try text(brief))[index]
                try ProjectMemory.replaceRule(rule, in: brief, with: rule.text + " ")
            }
        }
        XCTAssertEqual(try text(brief), kept)

        try write("-\n  bare marker\n", to: brief)
        let bare = try XCTUnwrap(ProjectMemory.rules(in: try text(brief)).first)
        try ProjectMemory.replaceRule(bare, in: brief, with: "edited")
        XCTAssertEqual(try text(brief), "- edited\n")
    }

    /// Only `metadata`'s date changes, and every other line keeps its own
    /// break.
    func testEditKeepsWhatItDoesntChange() throws {
        let file = memory.appendingPathComponent("m.md")
        try write("---\nname: m\ndescription: |\n  modified: not a date\nmetadata:\n  type: user\n  modified: 2026-01-01T00:00:00.000Z\n---\n\nOld.\n", to: file)
        let later = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-06T08:00:00Z"))
        try ProjectMemory.replaceMemoryText(fileName: "m.md", in: memory, expected: "Old.", with: "New.", now: later)
        XCTAssertEqual(try text(file), "---\nname: m\ndescription: |\n  modified: not a date\nmetadata:\n  type: user\n  modified: 2026-10-06T08:00:00.000Z\n---\n\nNew.\n")

        try write("- [A](a.md) — a\r\n- [B](b.md) — b\n- [C](c.md) — c\n", to: index)
        try ProjectMemory.removeIndexLines(of: "b.md", in: memory)
        XCTAssertEqual(try text(index), "- [A](a.md) — a\r\n- [C](c.md) — c\n")
        // The last line, without a break after it: the one before keeps its.
        try write("- [A](a.md) — a\r\n- [B](b.md) — b", to: index)
        try ProjectMemory.removeIndexLines(of: "b.md", in: memory)
        XCTAssertEqual(try text(index), "- [A](a.md) — a\r\n")

        try write("- a\r\n- b", to: brief)
        var rules = ProjectMemory.rules(in: try text(brief))
        try ProjectMemory.replaceRule(rules[1], in: brief, with: "b\r\nmore")
        XCTAssertEqual(try text(brief), "- a\r\n- b\r\n  more")
        rules = ProjectMemory.rules(in: try text(brief))
        try ProjectMemory.replaceRule(rules[1], in: brief, with: nil)
        XCTAssertEqual(try text(brief), "- a\r\n")
        try write("- a\r\n- b\n", to: brief)
        try ProjectMemory.appendRule("c", to: brief)
        XCTAssertEqual(try text(brief), "- a\r\n- b\n- c\r\n")
        try write("Paragraph.\n", to: brief)
        try ProjectMemory.replaceRule(try XCTUnwrap(ProjectMemory.rules(in: try text(brief)).first), in: brief, with: "Pasted\r\ntext.")
        XCTAssertEqual(try text(brief), "Pasted\ntext.\n")
    }

    // MARK: - Moves

    /// Always → When relevant and back, as it was: the source checked
    /// first, the destination written, then the source taken out. Changed
    /// meanwhile, or the destination failing, the source stays.
    func testMoves() throws {
        try write("- **Never merge.** The user merges.\n- Keep this.\n", to: brief)
        let rule = try XCTUnwrap(ProjectMemory.rules(in: try text(brief)).first)
        let fileName = try ProjectMemory.moveRuleToMemory(rule, from: brief, to: memory)
        XCTAssertEqual(fileName, "never-merge.md")
        XCTAssertEqual(try text(brief), "- Keep this.\n")
        let moved = try memory(fileName)
        XCTAssertEqual(moved.title, "Never merge")
        XCTAssertEqual(moved.description, "The user merges.")
        XCTAssertEqual(moved.kind, .feedback)
        XCTAssertEqual(moved.body, "**Never merge.** The user merges.")

        // An agent added to the memory since the panel read it: not moved.
        let file = memory.appendingPathComponent(fileName)
        let original = try text(file)
        try write(original + "Added by an agent.\n", to: file)
        XCTAssertThrowsError(try ProjectMemory.moveMemoryToRule(moved, in: memory, to: brief, trash: { _ in XCTFail("trashed") }))
        XCTAssertEqual(try text(brief), "- Keep this.\n")
        try write(original, to: file)

        let bin = TrashBin()
        let text = try ProjectMemory.moveMemoryToRule(moved, in: memory, to: brief, trash: bin.trash)
        XCTAssertEqual(text, "**Never merge.** The user merges.")
        XCTAssertEqual(ProjectMemory.rules(in: try self.text(brief)).last?.text, text)
        XCTAssertEqual(bin.names, ["never-merge.md"])
        XCTAssertEqual(try self.text(index), "")

        // The rule changed since: no memory made.
        let stale = try XCTUnwrap(ProjectMemory.rules(in: try self.text(brief)).first)
        try write("- Keep this, edited.\n", to: brief)
        XCTAssertThrowsError(try ProjectMemory.moveRuleToMemory(stale, from: brief, to: memory))
        XCTAssertEqual(ProjectMemory.read(directory: memory)?.memories, [])

        // What the rule's removal would refuse is checked before: no memory.
        try write("- **Deploy** on fridays <!-- ask first -->\n", to: brief)
        let commented = try XCTUnwrap(ProjectMemory.rules(in: try self.text(brief)).first)
        XCTAssertThrowsError(try ProjectMemory.moveRuleToMemory(commented, from: brief, to: memory))
        XCTAssertEqual(ProjectMemory.read(directory: memory)?.memories, [])
        try write("- Keep this, edited.\n", to: brief)

        // A memory that isn't UTF-8 text isn't copied, nor trashed.
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A]).write(to: memory.appendingPathComponent("raw.md"))
        let raw = try memory("raw.md")
        XCTAssertThrowsError(try ProjectMemory.moveMemoryToRule(raw, in: memory, to: brief, trash: { _ in XCTFail("trashed") }))
        XCTAssertEqual(try self.text(brief), "- Keep this, edited.\n")

        // The memory folder can't be made: the rule stays in the brief.
        let blocked = root.appendingPathComponent("a-file")
        try write("not a folder", to: blocked)
        let kept = try XCTUnwrap(ProjectMemory.rules(in: try self.text(brief)).first)
        XCTAssertThrowsError(try ProjectMemory.moveRuleToMemory(kept, from: brief, to: blocked.appendingPathComponent("memory")))
        XCTAssertEqual(ProjectMemory.rules(in: try self.text(brief)).first, kept)
    }
}

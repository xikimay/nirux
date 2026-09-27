import Foundation

/// Writes the agent skills Nirux ships (`name → SKILL.md content`) and
/// compares the copies on disk with them.
enum AgentSkillsInstaller {
    /// Every skill goes to both roots.
    static func roots(home: String) -> [String] {
        [
            home + "/.agents/skills",  // Codex, Cursor, Copilot, etc.
            home + "/.claude/skills"  // Claude Code
        ]
    }

    static func skillFile(root: String, name: String) -> String {
        root + "/" + name + "/SKILL.md"
    }

    /// Swift multiline strings already normalize indentation. The authored
    /// content is written verbatim so YAML front matter stays valid.
    static func fileContents(_ content: String) -> String {
        content + "\n"
    }

    static func install(_ skills: [String: String], home: String) throws {
        for (name, content) in skills {
            for root in roots(home: home) {
                try FileManager.default.createDirectory(
                    atPath: root + "/" + name, withIntermediateDirectories: true)
                try fileContents(content).write(
                    toFile: skillFile(root: root, name: name), atomically: true, encoding: .utf8)
            }
        }
    }

    static func status(of skills: [String: String], home: String) -> AgentSkillsStatus {
        var foundAny = false
        var allCurrent = true
        for (name, content) in skills {
            let expected = Data(fileContents(content).utf8)
            for root in roots(home: home) {
                guard let data = FileManager.default.contents(atPath: skillFile(root: root, name: name)) else {
                    allCurrent = false
                    continue
                }
                foundAny = true
                if data != expected { allCurrent = false }
            }
        }
        if allCurrent { return .installed }
        return foundAny ? .outdated : .missing
    }
}

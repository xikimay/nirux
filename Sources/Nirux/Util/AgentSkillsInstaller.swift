import CryptoKit
import Foundation
import os

/// Writes the agent skills Nirux ships (`name → SKILL.md content`),
/// compares the copies on disk with them, and keeps the copies Nirux wrote
/// current (`updateNiruxCopies`).
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

    /// Writes every skill to both roots, replacing any copy, edited or not:
    /// the user asked for it. The texts are recorded as Nirux's first.
    static func install(_ skills: [String: String], home: String, stateDirectory: URL) throws {
        recordTexts(of: skills, in: stateDirectory)
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

    // MARK: - Updates at launch

    /// What one `updateNiruxCopies` pass did, by SKILL.md path.
    struct UpdateReport: Equatable, Sendable {
        /// Rewritten with this build's text.
        var updated: [String] = []
        /// Left as they are: a text Nirux never wrote (the user edited it),
        /// a symbolic link, or a file that can't be read.
        var kept: [String] = []
        /// Nirux's copies that couldn't be rewritten.
        var failed: [String] = []
    }

    /// Only a Nirux that installs the agent hooks (an app bundle, see
    /// `AgentHookInstaller.shouldInstall`) and runs on the real state updates
    /// the skills on its own: a development build or a copy on a state of
    /// its own (NIRUX_STATE_DIR) would put its wording in every agent
    /// session, and keep its record where the installed app never looks.
    static func updatesOnLaunch(environment: [String: String], bundleURL: URL) -> Bool {
        AgentHookInstaller.shouldInstall(environment: environment, bundleURL: bundleURL)
            && Persistence.stateDirectoryOverride(in: environment) == nil
    }

    /// Rewrites each installed copy of a skill whose text differs from this
    /// build's when Nirux wrote that text: one recorded in the state
    /// directory (`recordTexts`), or one shipped before Nirux kept a record
    /// (`shippedBefore`). A copy the user edited stays, and Getting Started
    /// keeps offering the update (`status`). Never creates a copy: a skill
    /// missing from a root stays missing.
    @discardableResult
    static func updateNiruxCopies(
        of skills: [String: String], home: String, stateDirectory: URL,
        shippedBefore: [String: Set<String>] = textsShippedBeforeRecords
    ) -> UpdateReport {
        // This build's texts join the record before anything is compared,
        // so a copy that already matches is known once a later build ships
        // other wording.
        let recorded = recordTexts(of: skills, in: stateDirectory)
        var report = UpdateReport()
        for name in skills.keys.sorted() {
            guard let content = skills[name] else { continue }
            let expected = Data(fileContents(content).utf8)
            let niruxTexts = recorded[name, default: []].union(shippedBefore[name, default: []])
            for root in roots(home: home) {
                let path = skillFile(root: root, name: name)
                // Doesn't follow a final symbolic link: Nirux never writes
                // one, so a linked SKILL.md is the user's setup.
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let data = FileManager.default.contents(atPath: path)
                else {
                    report.kept.append(path)
                    continue
                }
                if data == expected { continue }
                guard niruxTexts.contains(digest(data)) else {
                    report.kept.append(path)
                    continue
                }
                do {
                    try expected.write(to: URL(fileURLWithPath: path), options: .atomic)
                    report.updated.append(path)
                } catch {
                    report.failed.append(path)
                }
            }
        }
        return report
    }

    /// `updateNiruxCopies` on a background queue, then `done` on the main
    /// thread. At launch.
    nonisolated static func updateNiruxCopiesInBackground(
        of skills: [String: String], home: String, stateDirectory: URL,
        then done: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let report = updateNiruxCopies(of: skills, home: home, stateDirectory: stateDirectory)
            if report != UpdateReport() {
                NSLog(
                    "[AgentSkills] updated %d, kept %d, failed %d",
                    report.updated.count, report.kept.count, report.failed.count
                )
            }
            DispatchQueue.main.async { done() }
        }
    }

    // MARK: - Record of Nirux's texts

    /// SHA-256 of every text Nirux wrote or shipped, by skill name. Kept in
    /// the state directory, never in the skills folders, which belong to the
    /// user and to every agent that reads them.
    private struct Record: Codable, Equatable {
        var texts: [String: Set<String>] = [:]
    }

    static let recordFileName = "agent-skills.json"

    /// The background pass and an install from the palette may both add to
    /// the record.
    private static let recordLock = OSAllocatedUnfairLock()

    /// Adds the hash of each skill's file text to the record and returns the
    /// whole record. A record that can't be read starts over: forgetting a
    /// text only leaves a copy as it is.
    @discardableResult
    static func recordTexts(of skills: [String: String], in stateDirectory: URL) -> [String: Set<String>] {
        recordLock.withLock {
            let url = stateDirectory.appendingPathComponent(recordFileName)
            var record = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
                ?? Record()
            let before = record
            for (name, content) in skills {
                record.texts[name, default: []].insert(digest(Data(fileContents(content).utf8)))
            }
            guard record != before else { return record.texts }
            do {
                try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(record).write(to: url, options: .atomic)
            } catch {
                NSLog("[AgentSkills] Failed to save %@: %@", url.path, error.localizedDescription)
            }
            return record.texts
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

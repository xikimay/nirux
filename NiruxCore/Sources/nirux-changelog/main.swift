import Foundation
import NiruxCore

// nirux-changelog <build> <pull-requests.json> <commits.txt> <changelog.json> <notes.md>
//
// Adds the pull requests whose merge commit is in commits.txt to
// changelog.json (the previous nightly's when it exists, else a new one) and
// writes the release body's list of them to notes.md.

let usage = "usage: nirux-changelog <build> <pull-requests.json> <commits.txt> <changelog.json> <notes.md>\n"
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 5, let build = Int(arguments[0]), let built = Changelog.date(ofBuild: build) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let (pullRequests, commitList, changelogPath, notesPath) = (arguments[1], arguments[2], arguments[3], arguments[4])

let commits = Set(try String(contentsOfFile: commitList, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init))
guard let added = Changelog.entries(fromPullRequests: try Data(contentsOf: URL(fileURLWithPath: pullRequests)), commits: commits, build: build) else {
    FileHandle.standardError.write(Data("\(pullRequests) isn't a list of pull requests from gh pr list.\n".utf8))
    exit(1)
}
let previous = FileManager.default.fileExists(atPath: changelogPath)
    ? try JSONDecoder().decode(Changelog.self, from: Data(contentsOf: URL(fileURLWithPath: changelogPath)))
    : Changelog()
let oldest = Changelog.build(at: built.addingTimeInterval(-Double(Changelog.keptDays) * 86_400))
let changelog = previous.adding(added, keepingBuildsFrom: oldest)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try encoder.encode(changelog).write(to: URL(fileURLWithPath: changelogPath), options: .atomic)
try changelog.releaseNotes(build: build).write(toFile: notesPath, atomically: true, encoding: .utf8)
print("Build \(build): \(added.count) landed; \(changelog.entries.count) entries kept.")

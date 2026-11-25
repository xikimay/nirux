import Foundation
import NiruxCore

// nirux-changelog <build> <head> <pull-requests.json> <commits.txt> <changelog.json> <notes.md>
//
// Adds the pull requests whose merge commit is in commits.txt to
// changelog.json (the previous nightly's when it exists, else a new one),
// marks it as reaching <head>, and writes the release body's list of them
// to notes.md.

let usage = "usage: nirux-changelog <build> <head> <pull-requests.json> <commits.txt> <changelog.json> <notes.md>\n"
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 6, let build = Int(arguments[0]), let built = Changelog.date(ofBuild: build) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let (head, pullRequests, commitList, changelogPath, notesPath) = (arguments[1], arguments[2], arguments[3], arguments[4], arguments[5])

let commits = Set(try String(contentsOfFile: commitList, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init))
guard let added = Changelog.entries(fromPullRequests: try Data(contentsOf: URL(fileURLWithPath: pullRequests)), commits: commits, build: build) else {
    FileHandle.standardError.write(Data("\(pullRequests) isn't a list of pull requests from gh pr list.\n".utf8))
    exit(1)
}
// An unreadable history stops here: the next nightly continues from the
// last one published, rather than from an empty one.
let saved = FileManager.default.contents(atPath: changelogPath)
let read = saved.flatMap { try? JSONDecoder().decode(Changelog.self, from: $0) }
if saved != nil, read == nil {
    FileHandle.standardError.write(Data("\(changelogPath) can't be read.\n".utf8))
    exit(1)
}
let previous = read ?? Changelog()
let oldest = Changelog.build(at: built.addingTimeInterval(-Double(Changelog.keptDays) * 86_400))
let changelog = previous.adding(added, through: head, keepingBuildsFrom: oldest)

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
try encoder.encode(changelog).write(to: URL(fileURLWithPath: changelogPath), options: .atomic)
try changelog.releaseNotes(build: build).write(toFile: notesPath, atomically: true, encoding: .utf8)
print("Build \(build): \(added.count) landed; \(changelog.entries.count) entries kept.")

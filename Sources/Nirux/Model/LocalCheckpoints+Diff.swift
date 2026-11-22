import Darwin
import Foundation

extension LocalCheckpoints {
    struct Diff: Sendable {
        let warning: String?
        let text: String
    }

    func diff(from id: UUID, to otherID: UUID?, worktree: String) async throws -> Diff {
        try await Task.detached(priority: .userInitiated) {
            try buildDiff(from: id, to: otherID, worktree: worktree)
        }.value
    }

    private func buildDiff(from id: UUID, to otherID: UUID?, worktree: String) throws -> Diff {
        let before = try manifest(id)
        let after = try otherID.map(manifest)
        let repository = after == nil ? try Self.repositoryPaths(in: worktree)[0] : worktree
        let root = after == nil ? open(repository, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC) : -1
        guard after != nil || root >= 0 else { throw Self.fileError }
        defer { if root >= 0 { close(root) } }
        let git = DiffRepository(directory: repository)
        let original = try indexedFiles(before)
        let modified = try after.map(indexedFiles) ?? [:]
        var paths = Set(original.keys).union(modified.keys)
        var omissions = Set((before.omissions + (after?.omissions ?? [])).map(\.path))
        var sections: [String] = [], skipped: [String] = []
        var exceedsFileLimit = paths.count > limits.maxFilesPerCapture
        func include(_ path: String) {
            if paths.count < limits.maxFilesPerCapture { paths.insert(path) }
            else if !paths.contains(path) { exceedsFileLimit = true }
        }

        var targetHead = after?.head
        if after == nil {
            do {
                let status = try Self.changedTrackedStatus { git.run($0) }
                try Self.visitStatus(status) { path, _, reason in
                    include(path)
                    if reason != nil, paths.contains(path) { omissions.insert(path) }
                }
            } catch { skipped.append(error.localizedDescription) }
            targetHead = git.run(["rev-parse", "--verify", "HEAD"]).flatMap {
                $0.status == 0 ? $0.text.trimmingCharacters(in: .newlines) : nil
            }
        }
        do {
            try git.visitChangedPaths(from: before.head, to: targetHead, include)
        } catch { skipped.append(error.localizedDescription) }

        var budget = limits.maxWorkspaceBytes
        var remainingPatch = 4 << 20
        if exceedsFileLimit { skipped.append("Comparison file count limit reached.") }
        for path in paths.sorted().prefix(limits.maxFilesPerCapture) {
            guard !git.expired else {
                skipped.append("Comparison timed out. Additional changes may be missing.")
                break
            }
            do {
                guard Self.safeFilePath(path), !BranchReview.Secrets.isSecretPath(path) else { throw Problem("Unsafe path") }
                guard !omissions.contains(path) else { throw Problem("Omitted from checkpoint") }
                let left = try savedBytes(path, file: original[path], in: before, git: git, budget: &budget)
                let right: Data?
                if let after {
                    right = try savedBytes(path, file: modified[path], in: after, git: git, budget: &budget)
                } else {
                    switch BranchReview.ExplainCopy.readBytes(path, from: root, maxFileBytes: limits.maxSingleFileBytes, budget: budget) {
                    case let .success(bytes):
                        budget -= bytes.count
                        right = bytes
                    case .failure(.missing): right = nil
                    case .failure(.tooLarge): throw Problem("Single-file size limit")
                    case .failure(.overTotal): throw Problem("Comparison byte limit")
                    case .failure: throw Problem("Could not read regular file")
                    }
                }
                guard left != right else { continue }
                for case let data? in [left, right] where !data.contains(0) {
                    guard !BranchReview.Secrets.containsKey(String(decoding: data, as: UTF8.self)) else { throw Problem("Secret content") }
                }
                if let section = try Self.unifiedDiff(path: path, before: left, after: right) {
                    guard section.utf8.count <= remainingPatch else {
                        skipped.append("Diff size limit reached. Additional changes are omitted.")
                        break
                    }
                    remainingPatch -= section.utf8.count
                    sections.append(section)
                }
            } catch {
                skipped.append("Skipped " + BranchReview.visible(path) + " — " + error.localizedDescription)
            }
        }
        let warning = before.isIncomplete || after?.isIncomplete == true ? "Incomplete checkpoint. Some changes may be missing." : nil
        let text = skipped + sections
        return Diff(warning: warning, text: text.isEmpty ? "No changes." : text.joined(separator: "\n"))
    }

    private func indexedFiles(_ manifest: Manifest) throws -> [String: File] {
        guard manifest.files.count <= limits.maxFilesPerCapture else { throw Problem("Checkpoint file count limit exceeded.") }
        var files: [String: File] = [:]
        for file in manifest.files {
            guard files.updateValue(file, forKey: file.path) == nil else { throw Problem("Duplicate path in checkpoint.") }
        }
        return files
    }

    private struct DiffRepository {
        let directory: String
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        let options = BranchReview.Options(gitHub: nil, environment: ["GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"])

        var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }

        func run(_ arguments: [String], limit: Int = 8 << 20) -> BranchReview.GitOutput? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            return BranchReview.git(arguments, in: directory, options: options, timeout: min(5, remaining), maxOutputBytes: limit)
        }

        func visitChangedPaths(from before: String?, to after: String?, _ include: (String) -> Void) throws {
            let unavailable = Problem("Git baseline unavailable. Changes between commits may be missing.")
            guard let left = GitHub.objectID(before), let right = GitHub.objectID(after) else { throw unavailable }
            guard left != right else { return }
            guard let changed = run(["diff-tree", "-r", "--name-only", "-z", "--no-renames", "--no-commit-id", left, right, "--"]),
                  changed.status == 0 else { throw unavailable }
            var validNames = true
            for record in changed.stdout.split(separator: 0) {
                if let path = String(data: record, encoding: .utf8) { include(path) }
                else { validNames = false }
            }
            if !validNames { throw Problem("Skipped filenames that are not UTF-8.") }
        }

        func bytes(at path: String, head: String, limit: Int, budget: inout Int) throws -> Data? {
            let unavailable = Problem("Recorded HEAD baseline unavailable")
            guard let tree = run(["--literal-pathspecs", "ls-tree", "-z", "-l", "--full-tree", head, "--", path]),
                  tree.status == 0 else { throw unavailable }
            guard !tree.stdout.isEmpty else { return nil }
            guard let tab = tree.stdout.firstIndex(of: 9),
                  tree.stdout[(tab + 1)...].elementsEqual(Array(path.utf8) + [0]) else { throw unavailable }
            let entry = String(decoding: tree.stdout[..<tab], as: UTF8.self).split(separator: " ")
            guard entry.count == 4, ["100644", "100755"].contains(entry[0]), entry[1] == "blob",
                  let hash = GitHub.objectID(String(entry[2])), let size = Int(entry[3]), size >= 0 else {
                throw Problem("Baseline is not a regular file")
            }
            guard size <= limit else { throw Problem("Single-file size limit") }
            guard size <= budget else { throw Problem("Comparison byte limit") }
            guard let blob = run(["cat-file", "blob", hash], limit: size), blob.status == 0,
                  blob.stdout.count == size else { throw unavailable }
            budget -= size
            return blob.stdout
        }
    }

    private func savedBytes(_ path: String, file: File?, in manifest: Manifest, git: DiffRepository, budget: inout Int) throws -> Data? {
        guard let file else {
            guard !manifest.timedOut, !manifest.omissions.contains(where: { $0.path.isEmpty }),
                  let head = GitHub.objectID(manifest.head) else { throw Problem("Recorded HEAD baseline unavailable") }
            return try git.bytes(at: path, head: head, limit: limits.maxSingleFileBytes, budget: &budget)
        }
        guard file.size <= limits.maxSingleFileBytes else { throw Problem("Single-file size limit") }
        guard file.size <= budget else { throw Problem("Comparison byte limit") }
        let data = try payload(for: file, in: manifest.id)
        budget -= data?.count ?? 0
        return data
    }

    /// Lines retain their LF so the comparison also sees changes to the final newline.
    static func unifiedDiff(path: String, before: Data?, after: Data?) throws -> String? {
        guard before != after else { return nil }
        func lines(_ bytes: Data?) throws -> [Data] {
            guard let bytes else { return [] }
            guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else { throw Problem("Binary file") }
            var result: [Data] = []
            var start = bytes.startIndex
            for offset in bytes.indices where bytes[offset] == 10 {
                guard result.count < 20_000 else { throw Problem("Line limit") }
                result.append(bytes[start...offset])
                start = offset + 1
            }
            if start < bytes.endIndex { result.append(bytes[start...]) }
            return result
        }
        let old = try lines(before), new = try lines(after)
        let name = BranchReview.visible(path)
        var patch = "--- " + (before == nil ? "/dev/null" : "a/" + name) + "\n+++ " + (after == nil ? "/dev/null" : "b/" + name) + "\n"
        var prefix = 0, suffix = 0
        let common = min(old.count, new.count)
        while prefix < common, old[prefix] == new[prefix] { prefix += 1 }
        while suffix < common - prefix, old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let left = old[prefix..<old.count - suffix], right = new[prefix..<new.count - suffix]

        // Bound the quadratic worst case. A large replacement still yields an exact hunk.
        var removed = Set(left.indices), added = Set(right.indices)
        if left.count + right.count <= 1_200 {
            let edits = right.difference(from: left)
            removed.removeAll()
            added.removeAll()
            for edit in edits {
                switch edit {
                case let .remove(offset, _, _): removed.insert(prefix + offset)
                case let .insert(offset, _, _): added.insert(prefix + offset)
                }
            }
        }
        var edits: [(kind: Character, bytes: Data)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if removed.contains(i) {
                edits.append(("-", old[i]))
                i += 1
            } else if added.contains(j) {
                edits.append(("+", new[j]))
                j += 1
            } else {
                edits.append((" ", old[i]))
                i += 1
                j += 1
            }
        }
        var hunks: [Range<Int>] = []
        for index in edits.indices where edits[index].kind != " " {
            let range = max(0, index - 3)..<min(edits.count, index + 4)
            if let last = hunks.last, last.upperBound >= range.lowerBound {
                hunks[hunks.count - 1] = last.lowerBound..<range.upperBound
            } else { hunks.append(range) }
        }
        var end = 0, oldLine = 1, newLine = 1
        for range in hunks {
            oldLine += range.lowerBound - end
            newLine += range.lowerBound - end
            let hunk = edits[range]
            let oldCount = hunk.count { $0.kind != "+" }, newCount = hunk.count { $0.kind != "-" }
            patch += "@@ -\(oldCount == 0 ? oldLine - 1 : oldLine),\(oldCount) +\(newCount == 0 ? newLine - 1 : newLine),\(newCount) @@\n"
            for (kind, bytes) in hunk {
                patch.append(kind)
                patch += String(decoding: bytes, as: UTF8.self)
                if bytes.last != 10 { patch += "\n\\ No newline at end of file\n" }
            }
            oldLine += oldCount
            newLine += newCount
            end = range.upperBound
        }
        return patch
    }
}

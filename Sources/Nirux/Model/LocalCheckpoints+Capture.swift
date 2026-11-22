import CryptoKit
import Darwin
import Foundation

extension LocalCheckpoints {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Capture {
        var manifest: Manifest
        var payloads: [String: Data] = [:]
        var bytes = 0

        mutating func omit(_ path: String, _ reason: String) {
            manifest.omissions.append(Omission(path: path, reason: reason))
        }

        /// Include the encoded manifest in the on-disk quota, even when many paths were skipped.
        func fitting(bytes limit: Int) throws -> (Manifest, Data) {
            var result = self
            var payloadBytes = bytes
            while true {
                let json = try JSONEncoder().encode(result.manifest)
                var excess = json.count + payloadBytes - limit
                if excess <= 0 { return (result.manifest, json) }
                while excess > 0, let file = result.manifest.files.popLast() {
                    result.omit(file.path, "Workspace byte limit")
                    payloadBytes -= file.size
                    excess -= file.size
                }
                if excess > 0 { throw Problem("The workspace quota cannot hold the checkpoint manifest.") }
            }
        }
    }

    func save(worktree: String, label: String?) throws -> Manifest {
        let options = BranchReview.Options(gitHub: nil, environment: ["GIT_NO_LAZY_FETCH": "1"])
        let location = BranchReview.git(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
            in: worktree, options: options, timeout: 5
        )
        guard let location, location.status == 0 else { throw Problem("The workspace’s Git repository could not be opened.") }
        let paths = location.text.split(separator: "\n").compactMap { String($0).realPath }
        guard paths.count == 3 else { throw Problem("The workspace’s Git directories could not be identified.") }
        let storePath = folder.path.lowercased()
        for path in paths {
            let protected = path.lowercased()
            guard storePath != protected, !storePath.hasPrefix(protected + "/") else {
                throw Problem("Checkpoints must live outside the worktree and its Git directories.")
            }
        }

        let root = paths[0]
        let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.fileError }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + limits.captureTimeout
        func git(_ arguments: [String]) -> BranchReview.GitOutput? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            return BranchReview.git(["-c", "core.fsmonitor=false"] + arguments, in: root, options: options,
                                    timeout: remaining, maxOutputBytes: 8 << 20)
        }
        func value(_ arguments: [String]) -> String? {
            guard let result = git(arguments), result.status == 0 else { return nil }
            return result.text.trimmingCharacters(in: .newlines)
        }

        var capture = Capture(manifest: Manifest(label: label))
        capture.manifest.branch = value(["symbolic-ref", "-q", "--short", "HEAD"])
        capture.manifest.head = value(["rev-parse", "-q", "--verify", "HEAD"])
        if let head = capture.manifest.head {
            for base in ["origin/HEAD", "main", "master"] {
                if let base = value(["merge-base", head, base]) {
                    capture.manifest.mergeBase = base
                    break
                }
            }
        }
        // A configured clean filter (e.g. LFS) can write objects as a side effect of status.
        let filters = git(["config", "--null", "--name-only", "--get-regexp", #"^filter\..*\.(process|clean|required)$"#])
        if let filters, [0, 1].contains(filters.status) {
            let disabled = filters.stdout.split(separator: 0).flatMap { name -> [String] in
                let key = String(decoding: name, as: UTF8.self)
                return ["-c", key + (key.hasSuffix(".required") ? "=false" : "=")]
            }
            if let status = git(disabled + ["status", "--porcelain=v1", "-z", "--untracked-files=no", "--find-renames",
                                            "--ignore-submodules=untracked"]), status.status == 0 {
                try collect(status.stdout, root: descriptor, deadline: deadline, capture: &capture)
            } else if ProcessInfo.processInfo.systemUptime < deadline {
                throw Problem("Git could not list the changed tracked files within the status output limit.")
            }
        } else if ProcessInfo.processInfo.systemUptime < deadline {
            throw Problem("Git could not read the workspace’s filter configuration.")
        }
        capture.manifest.timedOut = ProcessInfo.processInfo.systemUptime >= deadline
        return try persist(capture)
    }

    private func collect(_ status: Data, root: Int32, deadline: TimeInterval, capture: inout Capture) throws {
        var records = status.split(separator: 0).makeIterator()
        while let record = records.next() {
            guard record.count > 3 else { throw Problem("Invalid Git status entry.") }
            let code = String(decoding: record.prefix(2), as: UTF8.self)
            let pathBytes = record.dropFirst(3)
            var oldPath: String?
            if code.contains("R") || code.contains("C") {
                guard let source = records.next() else { throw Problem("Incomplete Git rename entry.") }
                let sourcePath = String(decoding: source, as: UTF8.self)
                oldPath = sourcePath
                if code.contains("R") { capturePath(sourcePath, code: "D ", withheld: false, root: root, deadline: deadline, capture: &capture) }
            }
            guard let path = String(data: pathBytes, encoding: .utf8) else {
                capture.omit(String(decoding: pathBytes, as: UTF8.self), "Filename is not UTF-8")
                continue
            }
            capturePath(path, code: code, withheld: oldPath.map(BranchReview.Secrets.isSecretPath) == true,
                        root: root, deadline: deadline, capture: &capture)
        }
    }

    private func capturePath(_ path: String, code: String, withheld: Bool, root: Int32, deadline: TimeInterval, capture: inout Capture) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            return capture.omit(path, "Unsafe path")
        }
        guard !withheld, !BranchReview.Secrets.isSecretPath(path) else { return capture.omit(path, "Secret path") }
        guard ProcessInfo.processInfo.systemUptime < deadline else { return capture.omit(path, "Capture timed out") }
        guard capture.manifest.files.count < limits.maxFilesPerCapture else { return capture.omit(path, "File count limit") }
        if code == "D " {
            capture.manifest.files.append(File(path: path, status: code, size: 0, sha256: nil))
            return
        }
        let result = BranchReview.ExplainCopy.readBytes(path, from: root, maxFileBytes: limits.maxSingleFileBytes,
                                                       budget: limits.maxWorkspaceBytes - capture.bytes)
        switch result {
        case .failure(.missing) where code.hasSuffix("D"):
            capture.manifest.files.append(File(path: path, status: code, size: 0, sha256: nil))
        case .failure(.notRegularFile): capture.omit(path, "Symlink, hard link, or non-regular file")
        case .failure(.tooLarge): capture.omit(path, "Single-file size limit")
        case .failure(.overTotal): capture.omit(path, "Workspace byte limit")
        case .failure: capture.omit(path, "Could not read file")
        case .success(let data):
            guard !BranchReview.Secrets.containsKey(String(decoding: data, as: UTF8.self)) else {
                return capture.omit(path, "Secret content")
            }
            let hash = Self.digest(data)
            capture.payloads[hash] = data
            capture.bytes += data.count
            capture.manifest.files.append(File(path: path, status: code, size: data.count, sha256: hash))
        }
    }
}

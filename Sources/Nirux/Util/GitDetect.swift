import Foundation

struct GitIdentity: Hashable, Sendable {
    let repositoryRoot: String
    let head: String
}

struct GitContext: Hashable, Sendable {
    let branch: String
    let identity: GitIdentity
}

enum GitDetect {
    static func context(at path: String) -> GitContext? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["rev-parse", "--show-toplevel", "HEAD", "--abbrev-ref", "HEAD"]
        proc.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)
            else { return nil }
            let lines = output
                .split(whereSeparator: { $0.isNewline })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard lines.count == 3,
                  lines.allSatisfy({ !$0.isEmpty })
            else { return nil }
            return GitContext(
                branch: lines[2],
                identity: GitIdentity(
                    repositoryRoot: URL(fileURLWithPath: lines[0]).standardizedFileURL.path,
                    head: lines[1]
                )
            )
        } catch {
            return nil
        }
    }

    static func contextAsync(
        at path: String,
        completion: @escaping @MainActor @Sendable (GitContext?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let result = context(at: path)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

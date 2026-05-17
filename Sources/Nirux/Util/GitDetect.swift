import Foundation

/// Detects git branch from a directory path
enum GitDetect {
    static func branch(at path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        proc.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return result?.isEmpty == true ? nil : result
        } catch {
            return nil
        }
    }

    /// Async version for background detection
    static func branchAsync(at path: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = branch(at: path)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

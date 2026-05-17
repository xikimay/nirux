import Foundation

enum PRDetect {
    /// Fetch PR info for the given branch. Runs `gh` CLI.
    static func fetchAsync(branch: String, cwd: String, completion: @escaping (PRInfo?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = fetch(branch: branch, cwd: cwd)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func fetch(branch: String, cwd: String) -> PRInfo? {
        // Find gh binary
        let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let ghPath else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ghPath)
        proc.arguments = ["pr", "list", "--head", branch,
                          "--json", "number,state,isDraft,statusCheckRollup,reviewDecision,mergeable,url,additions,deletions,changedFiles",
                          "--limit", "1"]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first else { return nil }

            let number = first["number"] as? Int ?? 0
            let state = first["state"] as? String ?? ""
            let isDraft = first["isDraft"] as? Bool ?? false
            let url = first["url"] as? String ?? ""
            let additions = first["additions"] as? Int
            let deletions = first["deletions"] as? Int
            let changedFiles = first["changedFiles"] as? Int
            let reviewDecision = first["reviewDecision"] as? String
            let mergeable = first["mergeable"] as? String

            var ciStatus: String?
            var failedCheckUrl: String?
            if let rollup = first["statusCheckRollup"] as? [[String: Any]], !rollup.isEmpty {
                let conclusions = rollup.compactMap { $0["conclusion"] as? String }
                if conclusions.contains("FAILURE") {
                    ciStatus = "FAILURE"
                    failedCheckUrl = rollup
                        .first { ($0["conclusion"] as? String) == "FAILURE" }
                        .flatMap { $0["detailsUrl"] as? String }
                } else if conclusions.contains("PENDING") || conclusions.allSatisfy({ $0.isEmpty }) {
                    ciStatus = "PENDING"
                } else if !conclusions.isEmpty {
                    ciStatus = "SUCCESS"
                }
            }

            return PRInfo(number: number, state: state, isDraft: isDraft,
                         ciStatus: ciStatus, failedCheckUrl: failedCheckUrl,
                         reviewDecision: reviewDecision, mergeable: mergeable,
                         url: url, additions: additions, deletions: deletions,
                         changedFiles: changedFiles)
        } catch {
            return nil
        }
    }

    /// Get diff stats via git
    static func diffStatsAsync(cwd: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = diffStats(cwd: cwd)
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func diffPathsAsync(cwd: String, completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = diffPaths(cwd: cwd)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func diffStats(cwd: String) -> String? {
        guard let str = gitOutput(arguments: ["diff", "--shortstat"], cwd: cwd)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return str.isEmpty ? nil : str
    }

    private static func diffPaths(cwd: String) -> [String] {
        guard let output = gitOutput(arguments: ["diff", "--name-only"], cwd: cwd) else { return [] }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func gitOutput(arguments: [String], cwd: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = arguments
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return nil
        }
    }
}

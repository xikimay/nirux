import Foundation
import os

/// Whether an SSH host alias stands for github.com (`git@github-work:acme/app.git`,
/// with a `Host github-work` block naming `HostName github.com`, as people
/// with two GitHub accounts set it), as `ssh -G` resolves it from the user's
/// SSH config. Nothing connects: ssh only prints its config. A yes is kept
/// for the session; anything else is asked again, so a config fixed since
/// counts at the next Refresh. Runs ssh: never on the main thread.
enum SSHHostAlias {
    /// `configFile` replaces the user's SSH config (tests).
    static func isGitHub(_ host: String, configFile: String? = nil, timeout: TimeInterval = 5) -> Bool {
        resolve(host, configFile: configFile, timeout: timeout) ?? false
    }

    /// Whether `host` stands for github.com; nil when ssh didn't start or
    /// took too long. ssh refusing its config (a keyword it doesn't know,
    /// loose permissions) is a no, as git's ssh would fail there too.
    static func resolve(_ host: String, configFile: String? = nil, timeout: TimeInterval = 5) -> Bool? {
        let host = host.lowercased()
        if host == "github.com" || host == "ssh.github.com" { return true }
        // A name ssh can't read as an option.
        guard host.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil else { return false }
        let key = (configFile ?? "") + "\u{0}" + host
        if known.withLock({ $0.contains(key) }) { return true }
        let arguments = (configFile.map { ["-F", $0] } ?? []) + ["-G", "--", host]
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments,
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: timeout
        ) else { return nil }
        guard result.terminationStatus == 0 else { return false }
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        let hostName = output.split(separator: "\n").first { $0.hasPrefix("hostname ") }
            .map { $0.dropFirst("hostname ".count).trimmingCharacters(in: .whitespaces).lowercased() }
        guard hostName == "github.com" || hostName == "ssh.github.com" else { return false }
        known.withLock { _ = $0.insert(key) }
        return true
    }

    /// The hosts ssh resolved to github.com, by config file and host.
    private static let known = OSAllocatedUnfairLock(initialState: Set<String>())
}

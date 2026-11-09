import Foundation

/// Whether an SSH host alias stands for github.com (`git@github-work:acme/app.git`,
/// with a `Host github-work` block naming `HostName github.com`, as people
/// with two GitHub accounts set it), as `ssh -G` resolves it from the user's
/// SSH config. Nothing connects: ssh only prints its config. Each answer is
/// kept for the session. Runs ssh: never on the main thread.
enum SSHHostAlias {
    /// `configFile` replaces the user's SSH config (tests).
    static func isGitHub(_ host: String, configFile: String? = nil) -> Bool {
        resolve(host, configFile: configFile) ?? false
    }

    /// Whether `host` stands for github.com; nil when ssh didn't start or
    /// took too long (not cached: asked again next time). ssh refusing its
    /// config (a keyword it doesn't know, loose permissions) is a no, as
    /// git's ssh would fail there too.
    static func resolve(_ host: String, configFile: String? = nil) -> Bool? {
        let host = host.lowercased()
        if host == "github.com" || host == "ssh.github.com" { return true }
        // A name ssh can't read as an option.
        guard host.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil else { return false }
        let key = (configFile ?? "") + "\u{0}" + host
        if let known = cache.value(for: key) { return known }
        let arguments = (configFile.map { ["-F", $0] } ?? []) + ["-G", "--", host]
        guard let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments,
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: 5
        ) else { return nil }
        let output = result.terminationStatus == 0 ? String(decoding: result.standardOutput, as: UTF8.self) : ""
        let hostName = output.split(separator: "\n").first { $0.hasPrefix("hostname ") }
            .map { $0.dropFirst("hostname ".count).trimmingCharacters(in: .whitespaces).lowercased() }
        let isGitHub = hostName == "github.com" || hostName == "ssh.github.com"
        cache.set(isGitHub, for: key)
        return isGitHub
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: Bool] = [:]

        func value(for key: String) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return answers[key]
        }

        func set(_ value: Bool, for key: String) {
            lock.lock()
            answers[key] = value
            lock.unlock()
        }
    }
}

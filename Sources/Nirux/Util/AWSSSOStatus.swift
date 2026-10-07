import CryptoKit
import Foundation

/// AWS IAM Identity Center logins (`[sso-session NAME]` in ~/.aws/config)
/// that an agent's next `aws` call would find expired, for the title-bar
/// badge (docs/auth-expiry-badge.md).
///
/// The cache file's `expiresAt` is the access token's, about an hour: the
/// AWS CLI refreshes it on use while the session lasts, and the session's
/// own end isn't written anywhere. So the file only says when to look: once
/// it is inside the CLI's refresh window, `aws sts get-caller-identity`
/// runs as a profile of that session, and an SSO "expired" error means a
/// login is needed. Nirux reads no token: only `expiresAt` is decoded, and the
/// probe's output is dropped.
enum AWSSSOStatus {
    struct Session: Equatable, Sendable {
        let name: String
        /// The first profile using it, for the probe.
        let profile: String
    }

    /// botocore's `SSOTokenProvider._REFRESH_WINDOW`: inside it, the CLI
    /// refreshes the token before using it.
    static let refreshWindow: TimeInterval = 15 * 60

    static func installedAWSPath() -> String? {
        ["/opt/homebrew/bin/aws", "/usr/local/bin/aws"].first { FileManager.default.fileExists(atPath: $0) }
    }

    /// `! ` runs it from Claude Code's prompt, and is a no-op in a shell.
    /// The name comes from ~/.aws/config, where the CLI accepts `$(…)` or
    /// `;` in it: quoted, so the pasted command runs nothing else.
    static func loginCommand(session: String) -> String {
        "! aws sso login --sso-session \(GitHubCLIQueueClient.shellQuoted(session))"
    }

    /// Each sso-session that a profile uses, in config order.
    static func sessions(config: String) -> [Session] {
        var names: [String] = []
        var profiles: [String: String] = [:]
        var profile: String?
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                profile = header == "default" ? header : header.removingPrefix("profile ")
                if let name = header.removingPrefix("sso-session ") { names.append(name) }
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if let profile, pair.count == 2, pair[0] == "sso_session", profiles[pair[1]] == nil {
                profiles[pair[1]] = profile
            }
        }
        return names.compactMap { name in profiles[name].map { Session(name: name, profile: $0) } }
    }

    /// Where the CLI caches a session's token: the SHA-1 of its name.
    static func cacheURL(session: String, home: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: home).appendingPathComponent(".aws/sso/cache/\(digest).json")
    }

    /// The only field decoded: the token, refresh token and client secret
    /// beside it are never read into a value.
    private struct CachedToken: Decodable {
        let expiresAt: String
    }

    /// The CLI writes whole seconds; the JavaScript SDK, refreshing the
    /// same file, adds milliseconds.
    static func expiresAt(cache data: Data) -> Date? {
        guard let token = try? JSONDecoder().decode(CachedToken.self, from: data) else { return nil }
        let withMilliseconds = ISO8601DateFormatter()
        withMilliseconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: token.expiresAt) ?? withMilliseconds.date(from: token.expiresAt)
    }

    /// The sessions needing a login, each with the `expiresAt` seen when
    /// it was found expired. `known` is the last result: while a session's
    /// file is unchanged it stays expired without another probe, and a
    /// login rewrites the file. A session without a cache file was never
    /// logged in, or was logged out on purpose: it is left alone.
    static func expiredSessions(
        _ sessions: [Session],
        known: [String: Date],
        now: Date,
        expiresAt: (Session) -> Date?,
        probeSaysExpired: (Session) -> Bool
    ) -> [String: Date] {
        var expired: [String: Date] = [:]
        for session in sessions {
            guard let expiry = expiresAt(session) else { continue }
            if known[session.name] == expiry || (expiry.timeIntervalSince(now) < refreshWindow && probeSaysExpired(session)) {
                expired[session.name] = expiry
            }
        }
        return expired
    }

    /// Reads ~/.aws/config and the cache files, and probes: run it off the
    /// main actor.
    static func expiredSessions(known: [String: Date], aws: String, home: String = NSHomeDirectory()) -> [String: Date] {
        let config = (try? String(contentsOfFile: home + "/.aws/config", encoding: .utf8)) ?? ""
        return expiredSessions(
            sessions(config: config),
            known: known,
            now: Date(),
            expiresAt: { session in
                (try? Data(contentsOf: cacheURL(session: session.name, home: home))).flatMap { expiresAt(cache: $0) }
            },
            probeSaysExpired: { probeSaysExpired($0, aws: aws, home: home) }
        )
    }

    /// A failure for another reason (offline, a role without STS access)
    /// is not a login to ask for.
    static func probeSaysExpired(_ session: Session, aws: String, home: String) -> Bool {
        let result = BoundedProcess.run(
            executableURL: URL(fileURLWithPath: aws),
            arguments: ["sts", "get-caller-identity", "--profile", session.profile],
            currentDirectoryURL: URL(fileURLWithPath: home),
            environment: ["AWS_PAGER": ""],
            captureStandardError: true
        )
        guard let result, result.terminationStatus != 0 else { return false }
        return saysExpired(standardError: result.standardError)
    }

    /// botocore's two errors for an SSO login to renew. Not any "expired":
    /// a clock skewed after a wake says "Signature expired", which a login
    /// wouldn't fix.
    static func saysExpired(standardError: Data) -> Bool {
        let text = String(data: standardError, encoding: .utf8) ?? ""
        return text.contains("Token has expired and refresh failed")
            || text.contains("SSO session associated with this profile has expired")
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }
}

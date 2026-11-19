import Foundation

extension GitHub {
    /// The one way Nirux runs the GitHub CLI: where it is, how it runs, and
    /// what its failures mean.
    enum CLI {
        /// Plain JSON whatever the terminal Nirux was started from asked for.
        static let environment = [
            "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
            "NO_COLOR": "1", "CLICOLOR_FORCE": "0", "GH_FORCE_TTY": ""
        ]

        static let missing = "The GitHub CLI (gh) isn’t installed"
        static let signedOut = "gh isn’t signed in to github.com"

        /// Where gh is; nil when it isn't there. Looked up at each call, so a
        /// gh installed since launch is found.
        static func installedPath() -> String? {
            ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        /// gh at `path` with the neutral environment, from `folder`: by
        /// default one outside every checkout, so only the arguments name the
        /// repository. Nil when it didn't start or timed out.
        static func run(
            _ path: String, arguments: [String], in folder: URL = FileManager.default.temporaryDirectory,
            timeout: TimeInterval, maxStandardOutputBytes: Int? = nil
        ) -> BoundedProcessResult? {
            BoundedProcess.run(
                executableURL: URL(fileURLWithPath: path),
                arguments: arguments,
                currentDirectoryURL: folder,
                environment: environment,
                timeout: timeout,
                captureStandardError: true,
                maxStandardOutputBytes: maxStandardOutputBytes
            )
        }

        /// `gh api graphql` on github.com. `-f` sends each value as a plain
        /// string: `-F` would read `@file` and turn `true` or `12` into other types.
        static func graphQL(_ query: String, strings: [(String, String)], integers: [(String, Int)] = []) -> [String] {
            ["api", "graphql", "--hostname", GitHub.host, "-f", "query=\(query)"]
                + strings.flatMap { ["-f", "\($0.0)=\($0.1)"] }
                + integers.flatMap { ["-F", "\($0.0)=\($0.1)"] }
        }

        /// The `owner` and `name` variables of `owner/name`.
        static func ownerAndName(_ repository: String) -> [(String, String)] {
            let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
            return [("owner", parts.first ?? ""), ("name", parts.count > 1 ? parts[1] : "")]
        }

        struct Output: Sendable {
            let status: Int32
            let standardOutput: Data
            let standardError: Data
        }

        enum Failure: Error, Equatable, Sendable {
            /// The GitHub CLI isn't where Nirux looks for it.
            case ghMissing
            case notSignedIn(String)
            /// The primary rate limit, until `resetAt` when `rate_limit` says.
            case rateLimited(resetAt: Date?)
            case secondaryRateLimit(String)
            /// GitHub answered with an error: its HTTP status (none for a
            /// GraphQL error) and message.
            case refused(status: Int?, message: String)
            /// gh didn't start or timed out, GitHub couldn't be reached, or a
            /// server error: the call may have gone through.
            case noAnswer(String)
            /// gh exited 0 with output Nirux can't read.
            case unreadable(String)

            var message: String {
                switch self {
                case .ghMissing: return CLI.missing
                case .notSignedIn(let message), .secondaryRateLimit(let message), .noAnswer(let message): return message
                case .rateLimited: return "API rate limit exceeded"
                case .refused(let status, let message): return status.map { "\(message) (HTTP \($0))" } ?? message
                case .unreadable(let output): return "gh answered with something Nirux can’t read: \(output)"
                }
            }
        }

        /// What a failed gh run means: a rate limit, a sign-in, an error
        /// GitHub answered, or no answer.
        static func classify(_ output: Output) -> Failure {
            let standardError = String(decoding: output.standardError, as: UTF8.self)
            let standardOutput = String(decoding: output.standardOutput, as: UTF8.self)
            let text = standardError + "\n" + standardOutput
            let lowered = text.lowercased()
            let json = (try? JSONSerialization.jsonObject(with: output.standardOutput)) as? [String: Any]
            let graphQLErrors = json?["errors"] as? [[String: Any]] ?? []
            let status = httpStatus(standardError) ?? (json?["status"] as? String).flatMap { Int($0) }
            let message = (json?["message"] as? String)
                ?? graphQLErrors.compactMap { $0["message"] as? String }.first
                ?? WorktreeCleanup.firstLine(standardError).map(strippingPrefix)
                ?? "gh exited with status \(output.status)"

            if lowered.contains("secondary rate limit") || lowered.contains("abuse detection") {
                return .secondaryRateLimit(message)
            }
            if lowered.contains("api rate limit exceeded") || graphQLErrors.contains(where: { $0["type"] as? String == "RATE_LIMITED" })
                || status == 429 {
                return .rateLimited(resetAt: nil)
            }
            if status == 401 || output.status == 4 || lowered.contains("gh auth login") || lowered.contains("bad credentials") {
                return .notSignedIn(message)
            }
            if let status {
                return (500..<600).contains(status) ? .noAnswer("HTTP \(status): \(message)") : .refused(status: status, message: message)
            }
            if graphQLErrors.contains(where: { $0["type"] is String }) || standardError.hasPrefix("GraphQL:")
                || lowered.contains("is not mergeable") || lowered.contains("could not find any workflows") {
                return .refused(status: nil, message: message)
            }
            return .noAnswer(message)
        }

        /// `gh api`'s `… (HTTP 422)`, or the other commands' `HTTP 404: …`.
        static func httpStatus(_ text: String) -> Int? {
            if let range = text.range(of: #"\(HTTP \d{3}\)"#, options: .regularExpression) {
                return Int(text[range].dropFirst(6).prefix(3))
            }
            if let range = text.range(of: #"(?m)^(gh: )?HTTP \d{3}:"#, options: .regularExpression) {
                return Int(text[range].suffix(4).prefix(3))
            }
            return nil
        }

        private static func strippingPrefix(_ line: String) -> String {
            var line = line
            if line.hasPrefix("gh: ") { line.removeFirst(4) }
            if let range = line.range(of: #" \(HTTP \d{3}\)$"#, options: .regularExpression) { line.removeSubrange(range) }
            return line
        }
    }
}

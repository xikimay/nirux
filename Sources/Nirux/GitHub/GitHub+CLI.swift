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
        /// repository. Its output whatever its exit status; a failure when
        /// there is no gh, or it didn't start or timed out.
        static func run(
            _ arguments: [String], gh path: String? = installedPath(), in folder: URL = FileManager.default.temporaryDirectory,
            timeout: TimeInterval, maxStandardOutputBytes: Int? = nil
        ) -> Result<Output, Failure> {
            guard let path else { return .failure(.ghMissing) }
            guard let result = BoundedProcess.run(
                executableURL: URL(fileURLWithPath: path),
                arguments: arguments,
                currentDirectoryURL: folder,
                environment: environment,
                timeout: timeout,
                captureStandardError: true,
                maxStandardOutputBytes: maxStandardOutputBytes
            ) else { return .failure(.noAnswer("gh couldn’t start, or took longer than \(Int(timeout)) s")) }
            return .success(Output(status: result.terminationStatus, standardOutput: result.standardOutput,
                                   standardError: result.standardError))
        }

        /// `gh api graphql` on github.com. `-f` sends each value as a plain
        /// string: `-F` would read `@file` and turn `true` or `12` into other types.
        static func graphQL(_ query: String, strings: [(String, String)], integers: [(String, Int)] = []) -> [String] {
            ["api", "graphql", "--hostname", GitHub.host, "-f", "query=\(query)"]
                + strings.flatMap { ["-f", "\($0.0)=\($0.1)"] }
                + integers.flatMap { ["-F", "\($0.0)=\($0.1)"] }
        }

        /// The `owner` and `name` GraphQL variables of `owner/name`.
        static func repositoryVariables(_ repository: String) -> [(String, String)] {
            let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
            return [("owner", parts.first ?? ""), ("name", parts.count > 1 ? parts[1] : "")]
        }

        struct Output: Sendable {
            let status: Int32
            let standardOutput: Data
            let standardError: Data

            /// The standard output of a run that exited 0, else what its
            /// failure means.
            var result: Result<Data, Failure> {
                status == 0 ? .success(standardOutput) : .failure(classify(self))
            }
        }

        enum Failure: Error, Equatable, Sendable {
            /// The GitHub CLI isn't where Nirux looks for it.
            case ghMissing
            /// No account, or a token GitHub refuses: what gh said, unless it
            /// only asked for `gh auth login`.
            case notSignedIn(String?)
            /// The primary rate limit, until `resetAt` when `rate_limit` says.
            case rateLimited(resetAt: Date?)
            case secondaryRateLimit(String)
            /// GitHub answered with an error: its HTTP status (none for a
            /// GraphQL error) and message.
            case refused(status: Int?, message: String)
            /// gh didn't start or timed out, GitHub couldn't be reached, or a
            /// server error: the call may have gone through.
            case noAnswer(String)
            /// gh exited 0 with output Nirux can't read: the start of it.
            case unreadable(String)

            /// gh prints its JSON on one line: the excerpt is cut, not the line.
            static func unreadable(output: Data) -> Failure {
                let line = String(decoding: output.prefix(512), as: UTF8.self).firstLine ?? ""
                return .unreadable(line.count > 80 ? line.prefix(80) + "…" : line)
            }

            var message: String {
                switch self {
                case .ghMissing: return CLI.missing
                case .notSignedIn(let message): return message ?? CLI.signedOut
                case .secondaryRateLimit(let message), .noAnswer(let message): return message
                case .rateLimited: return "API rate limit exceeded"
                case .refused(let status, let message): return status.map { "\(message) (HTTP \($0))" } ?? message
                case .unreadable(let output): return "gh answered with something Nirux can’t read: \(output)"
                }
            }
        }

        /// What a failed gh run means: a rate limit, a sign-in, an error
        /// GitHub answered, or no answer. Read from gh's standard error and
        /// the error JSON it prints, never from the data a failed call
        /// printed beside it: a pull request's title ("How to run gh auth
        /// login") is no reason.
        static func classify(_ output: Output) -> Failure {
            let standardError = String(decoding: output.standardError, as: UTF8.self)
            let json = (try? JSONSerialization.jsonObject(with: output.standardOutput)) as? [String: Any]
            let graphQLErrors = json?["errors"] as? [[String: Any]] ?? []
            let jsonMessages = [json?["message"] as? String].compactMap { $0 } + graphQLErrors.compactMap { $0["message"] as? String }
            let lowered = ([standardError] + jsonMessages).joined(separator: "\n").lowercased()
            let status = httpStatus(standardError) ?? (json?["status"] as? String).flatMap { Int($0) }
            let message = jsonMessages.first
                ?? standardError.firstLine.map(strippingPrefix)
                ?? "gh exited with status \(output.status)"

            if lowered.contains("secondary rate limit") || lowered.contains("abuse detection") {
                return .secondaryRateLimit(message)
            }
            if lowered.contains("api rate limit exceeded") || graphQLErrors.contains(where: { $0["type"] as? String == "RATE_LIMITED" })
                || status == 429 {
                return .rateLimited(resetAt: nil)
            }
            if status == 401 || output.status == 4 || lowered.contains("gh auth login") || lowered.contains("bad credentials") {
                return .notSignedIn(message.lowercased().contains("gh auth login") ? nil : message)
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

        /// gh's words without the status it says on its own: `gh: … (HTTP 422)`,
        /// `HTTP 404: …`.
        private static func strippingPrefix(_ line: String) -> String {
            var line = line
            if line.hasPrefix("gh: ") { line.removeFirst(4) }
            if let range = line.range(of: #"^HTTP \d{3}: "#, options: .regularExpression) { line.removeSubrange(range) }
            if let range = line.range(of: #" \(HTTP \d{3}\)$"#, options: .regularExpression) { line.removeSubrange(range) }
            return line
        }
    }
}

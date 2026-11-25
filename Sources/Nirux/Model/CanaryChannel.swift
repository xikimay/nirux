import Foundation

/// How the packaged-app canary (scripts/canary) drives a copy of Nirux
/// without the user's focus: its runner writes requests into
/// `<state dir>/canary/requests/` through LeadChannel's files, and the app
/// acts on them as a person would (NiruxApp+Canary). Only a launch on a
/// state of its own (NIRUX_STATE_DIR) with the run's token opens it, and
/// every request must carry that token.
enum CanaryChannel {
    static let tokenKey = "NIRUX_CANARY_TOKEN"
    static let root = "canary"

    /// The run's token when this launch may open the channel: 64 lowercase
    /// hex digits, on a state of its own. Nil for any other launch.
    /// What a browser column may open. In a canary run only localhost and the
    /// run's own folder: WebKit's network process runs outside the copy's
    /// sandbox, whose network is localhost alone.
    static func pagePolicy(environment: [String: String], stateDirectory: URL) -> (URL) -> Bool {
        guard token(in: environment) != nil else { return { _ in true } }
        let root = stateDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path + "/"
        return { url in
            if url.isFileURL { return url.resolvingSymlinksInPath().path.hasPrefix(root) }
            let local = ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
            return url.absoluteString == "about:blank" || (["http", "https", "ws", "wss"].contains(url.scheme ?? "") && local)
        }
    }

    static func token(in environment: [String: String]) -> String? {
        guard Persistence.stateDirectoryOverride(in: environment) != nil,
              let token = environment[tokenKey], token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return token
    }

    /// Whether `request` carries `token` (its `token` argument), compared
    /// in constant time.
    static func isAuthorized(_ request: LeadChannel.Request, token: String) -> Bool {
        let given = Array((request.argumentObject["token"] as? String ?? "").utf8)
        let expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Opens the channel when `environment` allows it: requests carrying
    /// the run's token go to `perform`, others are refused. Each runs from
    /// the run loop rather than inside the request's dispatch block, so an
    /// action that opens a modal alert doesn't hold back the next request.
    /// Nil, with nothing written, for any other launch.
    @MainActor
    static func start(
        environment: [String: String],
        stateDirectory: URL,
        perform: @escaping LeadRequestCenter.Handler
    ) -> LeadRequestCenter? {
        guard let token = token(in: environment) else { return nil }
        let center = LeadRequestCenter(root: root)
        center.handler = { request, answer in
            guard isAuthorized(request, token: token) else {
                return answer("This request doesn't carry the run's canary token.", true)
            }
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { perform(request, answer) }
            }
        }
        center.start(stateDirectory: stateDirectory)
        return center
    }
}

import Foundation

/// Answering a Claude permission dialog from the Nirux sidebar (Settings →
/// Experimental, off by default).
///
/// Contract (Claude Code 2.1.283, read in its source): the interactive
/// dialog of the main thread and of foreground subagents does not wait for
/// PermissionRequest hooks. It opens at once and races them: the first
/// answer wins, and a hook decision arriving after a terminal answer is
/// ignored. Background subagents and teammates run the hooks first and
/// show their dialog only once every hook returned. A hook prints
/// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":
/// {"behavior":"allow"}}}` (or `"deny"` with `message` and `interrupt`); one
/// that prints nothing decides nothing.
///
/// Flow, when the option is on and the app is running:
/// 1. The hook receiver gives the PermissionRequest event a random request
///    ID, a deadline and the exact text of the call, queues it, and waits
///    for a decision file named after the ID (`PermissionApprovalChannel`),
///    never past the deadline.
/// 2. The app shows Allow / Deny under the column, if the sidebar may
///    answer: the column's own `claude`, the session bound to the column,
///    a card drawn in the sidebar for a column the user is not looking at.
///    Otherwise it releases the receiver at once.
/// 3. A click writes the decision, bound to the request ID, the session and
///    the column's NIRUX_AGENT_UUID. The receiver claims it (single use),
///    checks every field, prints the decision, and queues an
///    `approvalResolved` event saying what became of the request.
/// No decision (deadline, release) prints nothing: the terminal dialog
/// stays the only way to answer, as without the option.
enum PermissionApproval {
    /// Marker and decision files carry it: a receiver of another Nirux
    /// build (an update installed while the app runs) never waits on this
    /// app, and never takes its decisions.
    static let protocolVersion = 1

    enum Behavior: String, Codable, Sendable {
        case allow, deny
        /// Stop waiting and decide nothing: the terminal dialog answers.
        case release
    }

    /// What the receiver did with a request it waited for.
    enum Outcome: String, Codable, Sendable {
        /// The decision reached Claude. It applied, unless the dialog was
        /// answered at the terminal first; either way the dialog is closed.
        case allow, deny
        case release
        case expired
        /// A decision file whose fields did not match the request.
        case invalid
    }

    /// How long a receiver waits for a main-thread request. That dialog
    /// opens at once whatever the hook does, so waiting costs nothing but
    /// a sleeping process; the bound stays under the 60 s hook timeout of
    /// Claude Code before 2.1.3, so no version ever kills the receiver.
    static let mainThreadWindow: TimeInterval = 55
    /// A subagent's request: a background subagent shows its dialog only
    /// after the hooks return, so the wait delays it.
    static let subagentWindow: TimeInterval = 15
    /// The sidebar stops offering a decision this long before the
    /// deadline, so a click always lands while the receiver still polls.
    static let sendMargin: TimeInterval = 1.5
    static let pollInterval: TimeInterval = 0.1
    /// A sent decision the receiver hasn't reported on after this long
    /// did not arrive; the card then says so for `failureNoticeDuration`.
    static let deliveryTimeout: TimeInterval = 5
    static let failureNoticeDuration: TimeInterval = 8
    /// Permission modes whose dialogs are the user's ordinary call. Under
    /// bypass and auto modes the dialogs left are Claude's own safety
    /// checks (a dangerous `rm`), which deny themselves when nobody answers:
    /// a one-click Allow away from their warning is the wrong place.
    static let heldPermissionModes: Set<String> = ["default", "acceptEdits", "plan"]
    /// Tools whose whole meaning fits the text the sidebar shows (see
    /// `AgentToolInput.approvalText`).
    static let approvableTools: Set<String> = ["Bash", "PowerShell", "Read", "WebFetch", "WebSearch"]
    /// What Claude reads when a sidebar denial reaches it.
    static let denyMessage = "The user denied this tool call from the Nirux sidebar."

    static func window(agentID: String?) -> TimeInterval {
        agentID == nil ? mainThreadWindow : subagentWindow
    }

    /// The receiver's stdout for a decision. A denial never interrupts:
    /// the agent reads it and goes on, like "No" with feedback in the
    /// terminal, rather than stopping a run nobody is watching. Nil
    /// decides nothing (release).
    static func hookOutput(for behavior: Behavior) -> Data? {
        let decision: [String: Any]
        switch behavior {
        case .allow:
            decision = ["behavior": "allow"]
        case .deny:
            decision = ["behavior": "deny", "message": denyMessage, "interrupt": false]
        case .release:
            return nil
        }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]
        ]
        return try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    }

    /// The app's own check of what a queued request asks it to show, since
    /// the receiver may be another build: an approvable tool, and text
    /// that reaches the screen unchanged.
    static func isDisplayable(toolName: String?, text: String?) -> Bool {
        guard let toolName, approvableTools.contains(toolName), let text else { return false }
        return AgentToolInput.isExactDisplay(text)
    }
}

/// When the sidebar may hold a column's requests.
struct PermissionApprovalHold: Equatable {
    /// The column's card is drawn with its buttons (expanded sidebar, its
    /// workspace listed, not folded away) and the column is not the one on
    /// screen, whose terminal dialog answers.
    let cardShown: Bool
    /// The user can see the sidebar now: app active, window visible.
    let userSeesSidebar: Bool

    static let never = PermissionApprovalHold(cardShown: false, userSeesSidebar: false)

    /// A background subagent's dialog waits for the hook, so its request
    /// is held only while the user can see the buttons; the main thread's
    /// dialog never waits. (Foreground subagents can't be told apart.)
    func holds(isSubagent: Bool) -> Bool {
        cardShown && (userSeesSidebar || !isSubagent)
    }
}

/// A PermissionRequest whose receiver waits for a sidebar decision.
struct PermissionApprovalTicket: Hashable, Sendable {
    enum Display: Hashable, Sendable {
        case open
        case sending(PermissionApproval.Behavior)
        /// The receiver ended without the sent decision.
        case undelivered
    }

    let requestID: String
    /// Epoch seconds the receiver stops waiting.
    let deadline: TimeInterval
    /// Exactly what the call does, as the receiver checked it.
    let text: String
    let isSubagent: Bool
    /// The decision the sidebar sent, awaiting the receiver's report.
    var sent: PermissionApproval.Behavior?
    var sentAt: TimeInterval?
    /// The receiver reported that it ended without the sent decision.
    var undelivered = false

    init(requestID: String, deadline: TimeInterval, text: String, isSubagent: Bool = false) {
        self.requestID = requestID
        self.deadline = deadline
        self.text = text
        self.isSubagent = isSubagent
    }

    /// The sidebar may still answer.
    func isOpen(now: TimeInterval) -> Bool {
        sent == nil && now < deadline - PermissionApproval.sendMargin
    }

    /// The receiver still waits on the sidebar, or on a decision it sent.
    func isHeld(at now: TimeInterval) -> Bool { !undelivered && now < deadline }

    /// What the card shows, if anything.
    func display(now: TimeInterval) -> Display? {
        guard let sent, let sentAt else { return isOpen(now: now) ? .open : nil }
        let failedAt = sentAt + PermissionApproval.deliveryTimeout
        if undelivered || now >= failedAt {
            return now < failedAt + PermissionApproval.failureNoticeDuration ? .undelivered : nil
        }
        return .sending(sent)
    }
}

/// A decision, as the app writes it and the receiver checks it.
struct PermissionApprovalDecision: Codable, Equatable {
    let version: Int
    let requestID: String
    let sessionID: String
    let agentUUID: String
    let behavior: PermissionApproval.Behavior
    /// Epoch seconds (informational: the request ID alone is single use).
    let issuedAt: TimeInterval

    init(
        requestID: String,
        sessionID: String,
        agentUUID: String,
        behavior: PermissionApproval.Behavior,
        issuedAt: TimeInterval,
        version: Int = PermissionApproval.protocolVersion
    ) {
        self.version = version
        self.requestID = requestID
        self.sessionID = sessionID
        self.agentUUID = agentUUID
        self.behavior = behavior
        self.issuedAt = issuedAt
    }
}

/// The app that turned the option on, as receivers find it.
struct PermissionApprovalMarker: Codable, Equatable {
    let version: Int
    let app: ProcessInstance
}

/// The receiver's side of one request: what it waits for, and until when.
struct PermissionApprovalWait: Equatable {
    let requestID: String
    let sessionID: String
    let agentUUID: String
    /// The call's exact text (`AgentToolInput.approvalText`).
    let text: String
    let isSubagent: Bool
    let startedAt: TimeInterval
    let deadline: TimeInterval

    /// Nil when the sidebar can't answer this request: the option is off
    /// or Nirux isn't running (`isAppListening`), the payload lacks a
    /// session, the session runs in bypass or auto mode, or the call isn't
    /// one the sidebar can show exactly.
    static func prepare(
        payload: [String: Any],
        env: [String: String],
        now: TimeInterval,
        isAppListening: () -> Bool
    ) -> PermissionApprovalWait? {
        guard payload["hook_event_name"] as? String == "PermissionRequest",
              let sessionID = payload["session_id"] as? String, UUID(uuidString: sessionID) != nil,
              let agentUUID = env["NIRUX_AGENT_UUID"], !agentUUID.isEmpty,
              let mode = payload["permission_mode"] as? String,
              PermissionApproval.heldPermissionModes.contains(mode),
              let toolName = payload["tool_name"] as? String,
              let text = AgentToolInput.approvalText(
                  toolName: toolName,
                  input: payload["tool_input"] as? [String: Any] ?? [:],
                  home: env["HOME"]
              ),
              isAppListening()
        else { return nil }
        let agentID = (payload["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PermissionApprovalWait(
            requestID: UUID().uuidString,
            sessionID: sessionID,
            agentUUID: agentUUID,
            text: text,
            isSubagent: agentID != nil,
            startedAt: now,
            deadline: now + PermissionApproval.window(agentID: agentID)
        )
    }

    /// Whether `decision` answers this request: same protocol, and every
    /// binding matches.
    func accepts(_ decision: PermissionApprovalDecision) -> Bool {
        decision.version == PermissionApproval.protocolVersion
            && decision.requestID == requestID
            && decision.sessionID == sessionID
            && decision.agentUUID == agentUUID
    }

    /// Poll the channel until a decision for this request arrives, the
    /// deadline passes, or `isAbandoned` (Claude gave up on the hook, or
    /// the app is gone). `now` should be monotonic: a wall-clock step must
    /// not stretch the wait.
    func waitForDecision(
        on channel: PermissionApprovalChannel,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void,
        isAbandoned: () -> Bool
    ) -> PermissionApproval.Outcome {
        while true {
            // Claim before checking the clock: a decision written just
            // before the deadline still counts after the last sleep.
            if let decision = channel.claimDecision(requestID: requestID) {
                guard accepts(decision) else { return .invalid }
                switch decision.behavior {
                case .allow: return .allow
                case .deny: return .deny
                case .release: return .release
                }
            }
            let remaining = deadline - now()
            if remaining <= 0 || isAbandoned() { return .expired }
            sleep(min(PermissionApproval.pollInterval, remaining))
        }
    }
}

/// The files that carry decisions from the app to waiting receivers, in
/// `permission-approvals/` under the state directory:
/// - `app.json`: the running app's process identity, present only while
///   the option is on. Receivers wait only when it names a live process.
/// - `<request ID>.json`: one decision, written atomically, claimed by the
///   receiver with a rename so it is read at most once.
/// Both ends trust the files only in the user's own directories, which
/// no other account can write (a NIRUX_STATE_DIR under /tmp): the state
/// directory owned and not writable by others, the channel private
/// (0700), each file a regular file of the user's. Anything able to write
/// there runs as the user already; the request ID keeps decisions from
/// applying to another request, and the receiver checks the session and
/// column besides.
struct PermissionApprovalChannel {
    let directory: URL

    static var standard: PermissionApprovalChannel {
        PermissionApprovalChannel(
            directory: Persistence.stateDirectory.appendingPathComponent("permission-approvals", isDirectory: true)
        )
    }

    var markerURL: URL { directory.appendingPathComponent("app.json") }

    /// Receivers generate UUIDs; anything else read back from the event
    /// queue must not become a path.
    static func canonicalRequestID(_ raw: String) -> String? {
        UUID(uuidString: raw)?.uuidString
    }

    func decisionURL(requestID: String) -> URL? {
        Self.canonicalRequestID(requestID).map { directory.appendingPathComponent("\($0).json") }
    }

    /// Nobody but this user can have put files here.
    func isTrusted() -> Bool {
        Self.isOwnedDirectory(directory.deletingLastPathComponent().path, followingLinks: true, forbiddenModes: 0o022)
            && Self.isOwnedDirectory(directory.path, followingLinks: false, forbiddenModes: 0o077)
    }

    // MARK: App side

    /// Turn the option on: the marker names `app`. False when it could not
    /// be written in a trusted directory.
    @discardableResult
    func setListening(_ app: ProcessInstance) -> Bool {
        let marker = PermissionApprovalMarker(version: PermissionApproval.protocolVersion, app: app)
        guard prepareDirectory(), let data = try? JSONEncoder().encode(marker) else { return false }
        return Self.writeAtomically(data, to: markerURL)
    }

    /// Turn the option off for `app`: the marker goes, unless it names
    /// another Nirux still running on this state directory.
    func stopListening(
        for app: ProcessInstance?,
        running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:)
    ) {
        if isTrusted(),
           let data = Self.readPrivateFile(markerURL),
           let marker = try? JSONDecoder().decode(PermissionApprovalMarker.self, from: data),
           marker.app != app, running(marker.app.pid) == marker.app {
            return
        }
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Write one decision for a waiting receiver. False when it could not
    /// be written (the receiver then decides nothing).
    @discardableResult
    func send(_ decision: PermissionApprovalDecision) -> Bool {
        guard let url = decisionURL(requestID: decision.requestID),
              prepareDirectory(),
              let data = try? JSONEncoder().encode(decision) else { return false }
        return Self.writeAtomically(data, to: url)
    }

    /// Remove decisions nobody claimed (their receiver was gone) and
    /// leftovers of interrupted writes or claims, once older than any
    /// receiver's wait.
    func sweep(now: Date = Date(), maxAge: TimeInterval = PermissionApproval.mainThreadWindow + 60) {
        guard isTrusted() else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != markerURL.lastPathComponent {
            let url = directory.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, now.timeIntervalSince(modified) < maxAge { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: Receiver side

    /// The option is on and the app of this protocol that turned it on
    /// still runs (not a marker left by a crash, whose PID may now be
    /// another process).
    func isAppListening(running: (pid_t) -> ProcessInstance? = ProcessInstance.running(pid:)) -> Bool {
        guard isTrusted(),
              let data = Self.readPrivateFile(markerURL),
              let marker = try? JSONDecoder().decode(PermissionApprovalMarker.self, from: data),
              marker.version == PermissionApproval.protocolVersion else { return false }
        return running(marker.app.pid) == marker.app
    }

    /// Take the decision for `requestID`, if written: renamed aside first,
    /// so no second reader ever sees it, then read and deleted.
    func claimDecision(requestID: String) -> PermissionApprovalDecision? {
        guard let url = decisionURL(requestID: requestID) else { return nil }
        let claimed = directory.appendingPathComponent("\(url.lastPathComponent).claimed-\(getpid())")
        guard rename(url.path, claimed.path) == 0 else { return nil }
        defer { unlink(claimed.path) }
        guard let data = Self.readPrivateFile(claimed) else { return nil }
        return try? JSONDecoder().decode(PermissionApprovalDecision.self, from: data)
    }

    // MARK: Helpers

    /// Create the channel if needed; true once it is trusted.
    private func prepareDirectory() -> Bool {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // An existing directory keeps its mode otherwise (only ours can change).
        var info = stat()
        if lstat(directory.path, &info) == 0, info.st_uid == geteuid(), (info.st_mode & S_IFMT) == S_IFDIR {
            chmod(directory.path, 0o700)
        }
        return isTrusted()
    }

    private static func isOwnedDirectory(_ path: String, followingLinks: Bool, forbiddenModes: mode_t) -> Bool {
        var info = stat()
        let result = followingLinks ? stat(path, &info) : lstat(path, &info)
        return result == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == geteuid()
            && (info.st_mode & forbiddenModes) == 0
    }

    /// A small regular file of this user's, read without following a link
    /// or blocking on a FIFO.
    private static func readPrivateFile(_ url: URL, maxBytes: Int = 4096) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size <= maxBytes else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        guard read(fd, &buffer, buffer.count) == buffer.count else { return nil }
        return Data(buffer)
    }

    /// Owner-only file, complete before it appears under its name.
    private static func writeAtomically(_ data: Data, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return write(fd, base, buffer.count)
        }
        close(fd)
        guard written == data.count, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }
}

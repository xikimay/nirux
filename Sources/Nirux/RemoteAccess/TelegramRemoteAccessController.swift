import Foundation

struct TelegramRemoteAccessDisplayState: Equatable {
    let enabled: Bool
    let polling: Bool
    let hasToken: Bool
    let pairedUserID: Int64?
    let pairingCode: String?
    let pairingExpiresAt: Date?
    let lastError: String?

    var isPaired: Bool { pairedUserID != nil }

    var statusText: String {
        if !enabled { return "Remote Access is off." }
        if !hasToken { return "Add a Telegram bot token to connect." }
        if let pairedUserID {
            let base = polling
                ? "Paired with Telegram user \(pairedUserID)."
                : "Paired, but polling is stopped."
            return lastError.map { "\(base) \($0)" } ?? base
        }
        if let pairingCode, let pairingExpiresAt {
            let minutes = max(1, Int(ceil(pairingExpiresAt.timeIntervalSinceNow / 60)))
            let base = "Send /pair \(pairingCode) to the bot within \(minutes) min."
            return lastError.map { "\(base) \($0)" } ?? base
        }
        let base = "Not paired. Generate a one-time pairing code."
        return lastError.map { "\(base) \($0)" } ?? base
    }
}

enum TelegramPromptRoute: Equatable {
    case currentSelection
    case explicit(String)
    case unavailableReply

    static func resolve(replyToMessageID: Int64?, routes: [Int64: String]) -> TelegramPromptRoute {
        guard let replyToMessageID else { return .currentSelection }
        guard let target = routes[replyToMessageID] else { return .unavailableReply }
        return .explicit(target)
    }
}

@MainActor
final class TelegramRemoteAccessController {
    typealias SessionsProvider = () -> [RemoteAgentSession]
    typealias PromptSender = (String, String) -> RemotePromptResult
    typealias TokenLoader = () throws -> String?

    private enum PollingError: LocalizedError {
        case updateStatePersistenceFailed

        var errorDescription: String? {
            "Unable to save Telegram update state; no remote prompt was processed."
        }
    }

    var onStateChange: (() -> Void)?

    private let sessionsProvider: SessionsProvider
    private let promptSender: PromptSender
    private let tokenLoader: TokenLoader
    private let urlSession: URLSession
    private var pollingTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var client: TelegramBotClient?
    private var nextUpdateOffset: Int64?
    private var enabled = false
    private var hasToken = false
    private var pairedUserID: Int64?
    private var pairedChatID: Int64?
    private var notifyOnCompletion = true
    private var notifyOnAttention = true
    private var pairingCode: String?
    private var pairingExpiresAt: Date?
    private var pairingFailuresByUser: [Int64: Int] = [:]
    private var selectedAgentUUID: String?
    private var replyRoutes: [Int64: String] = [:]
    private var replyRouteOrder: [Int64] = []
    private var notificationArmedAt = Date.distantFuture
    private var lastError: String?

    init(
        sessions: @escaping SessionsProvider,
        sendPrompt: @escaping PromptSender,
        tokenLoader: @escaping TokenLoader = TelegramTokenStore.load,
        urlSession: URLSession = .shared
    ) {
        sessionsProvider = sessions
        promptSender = sendPrompt
        self.tokenLoader = tokenLoader
        self.urlSession = urlSession
    }

    var displayState: TelegramRemoteAccessDisplayState {
        TelegramRemoteAccessDisplayState(
            enabled: enabled,
            polling: pollingTask != nil,
            hasToken: hasToken,
            pairedUserID: pairedUserID,
            pairingCode: activePairingCode,
            pairingExpiresAt: activePairingCode == nil ? nil : pairingExpiresAt,
            lastError: lastError
        )
    }

    func reloadFromPersistence() {
        let previousToken = client?.token
        let previousPairingCode = activePairingCode
        let previousPairingExpiry = pairingExpiresAt
        stopPolling()
        let settings = Persistence.load()?.settings ?? PersistedSettings()
        enabled = settings.telegramRemoteAccessEnabled
        pairedUserID = settings.telegramPairedUserID
        pairedChatID = settings.telegramPairedChatID
        notifyOnCompletion = settings.telegramNotifyOnCompletion
        notifyOnAttention = settings.telegramNotifyOnAttention
        nextUpdateOffset = settings.telegramLastUpdateID.map { $0 + 1 }
        selectedAgentUUID = nil
        replyRoutes.removeAll()
        replyRouteOrder.removeAll()
        lastError = nil

        let token: String?
        do {
            token = try tokenLoader()
        } catch {
            token = nil
            lastError = "Keychain: \(error.localizedDescription)"
        }
        hasToken = token != nil
        let preservePairing = enabled
            && pairedUserID == nil
            && pairedChatID == nil
            && token == previousToken
            && previousPairingCode != nil
        pairingCode = preservePairing ? previousPairingCode : nil
        pairingExpiresAt = preservePairing ? previousPairingExpiry : nil
        if !preservePairing { pairingFailuresByUser.removeAll() }
        guard enabled, let token else {
            notificationArmedAt = .distantFuture
            publishState()
            return
        }

        let botClient = TelegramBotClient(token: token, session: urlSession)
        client = botClient
        notificationArmedAt = Date()
        let generation = pollGeneration
        pollingTask = Task { [weak self] in
            await self?.poll(client: botClient, generation: generation)
        }
        publishState()
    }

    func shutdown() {
        stopPolling()
        notificationArmedAt = .distantFuture
    }

    @discardableResult
    func beginPairing() -> String? {
        guard enabled, hasToken, client != nil, pairedUserID == nil, pairedChatID == nil else {
            return nil
        }
        let code = TelegramPairingCode.generate()
        pairingCode = code
        pairingExpiresAt = Date().addingTimeInterval(10 * 60)
        pairingFailuresByUser.removeAll()
        publishState()
        return code
    }

    func unpair() {
        pairedUserID = nil
        pairedChatID = nil
        selectedAgentUUID = nil
        replyRoutes.removeAll()
        replyRouteOrder.removeAll()
        pairingCode = nil
        pairingExpiresAt = nil
        updatePersistedPairing(userID: nil, chatID: nil)
        publishState()
    }

    /// Hook events are already normalized upstream; Telegram sees only
    /// generic completion/attention notifications tied to a stable column ID.
    func handleAgentEvent(_ event: AgentHookEvent, resolution: AgentHookCenter.Resolution?) {
        guard event.timestamp >= notificationArmedAt.timeIntervalSince1970,
              let resolution,
              let agentUUID = event.agentUUID,
              isAuthorizedConfiguration
        else { return }

        let eventLabel: String
        switch event.name {
        case .notification where notifyOnAttention:
            eventLabel = "Agent needs attention"
        case .stop where notifyOnCompletion,
             .turnComplete where notifyOnCompletion:
            eventLabel = "Agent turn completed"
        default:
            return
        }

        let workspaceTitle = resolution.workspace.title
        let columnNumber = resolution.columnIndex + 1
        let detail = event.detail.flatMap(Self.safeDetail)
        Task { [weak self] in
            await self?.sendAgentNotification(
                label: eventLabel,
                workspaceTitle: workspaceTitle,
                columnNumber: columnNumber,
                agentUUID: agentUUID,
                detail: detail
            )
        }
    }

    private var activePairingCode: String? {
        guard let pairingCode, let pairingExpiresAt, pairingExpiresAt > Date() else { return nil }
        return pairingCode
    }

    private var isAuthorizedConfiguration: Bool {
        enabled && hasToken && client != nil && pairedUserID != nil && pairedChatID != nil
    }

    private func stopPolling() {
        pollGeneration += 1
        pollingTask?.cancel()
        pollingTask = nil
        client = nil
    }

    private func poll(client: TelegramBotClient, generation: Int) async {
        var retryDelay: TimeInterval = 1
        while isCurrentPoll(generation) {
            do {
                let updates = try await client.getUpdates(offset: nextUpdateOffset)
                guard isCurrentPoll(generation) else { return }
                if lastError != nil {
                    lastError = nil
                    publishState()
                }
                for update in updates.sorted(by: { $0.updateID < $1.updateID }) {
                    guard isCurrentPoll(generation) else { return }
                    guard update.updateID >= (nextUpdateOffset ?? Int64.min) else { continue }
                    guard persistLastUpdateID(update.updateID) else {
                        throw PollingError.updateStatePersistenceFailed
                    }
                    guard isCurrentPoll(generation) else { return }
                    nextUpdateOffset = update.updateID + 1
                    await handle(update, client: client)
                }
                retryDelay = 1
            } catch {
                if Task.isCancelled || generation != pollGeneration { return }
                let description = error.localizedDescription
                if lastError != description {
                    lastError = description
                    publishState()
                }
                try? await Task.sleep(for: .seconds(retryDelay))
                retryDelay = min(30, retryDelay * 2)
            }
        }
    }

    private func handle(_ update: TelegramUpdate, client: TelegramBotClient) async {
        if let message = update.message {
            await handle(message, client: client)
        } else if let callback = update.callbackQuery {
            await handle(callback, client: client)
        }
    }

    private func handle(_ message: TelegramMessage, client: TelegramBotClient) async {
        guard let user = message.from, let text = message.text else { return }
        if pairedUserID == nil || pairedChatID == nil {
            await handlePairingMessage(message, user: user, text: text, client: client)
            return
        }
        guard isAuthorized(userID: user.id, chatID: message.chat.id) else { return }

        if let command = TelegramCommand.parse(text) {
            await handle(command, chatID: message.chat.id, client: client)
            return
        }

        let route = TelegramPromptRoute.resolve(
            replyToMessageID: message.replyToMessage?.messageID,
            routes: replyRoutes
        )
        switch route {
        case .currentSelection:
            await sendPrompt(text, preferredTarget: nil, chatID: message.chat.id, client: client)
        case let .explicit(target):
            await sendPrompt(text, preferredTarget: target, chatID: message.chat.id, client: client)
        case .unavailableReply:
            _ = await send(
                "That reply target is no longer available. Use /sessions to select a live agent.",
                chatID: message.chat.id,
                client: client
            )
        }
    }

    private func handlePairingMessage(
        _ message: TelegramMessage,
        user: TelegramUser,
        text: String,
        client: TelegramBotClient
    ) async {
        guard message.chat.type == "private", let command = TelegramCommand.parse(text) else { return }
        if command == .help {
            _ = await send(
                "Open Nirux Settings → Telegram Remote Access, generate a pairing code, then send /pair CODE here.",
                chatID: message.chat.id,
                client: client
            )
            return
        }
        guard case let .pair(submittedCode) = command else { return }
        let failures = pairingFailuresByUser[user.id, default: 0]
        let expectedCode = activePairingCode
        if expectedCode == nil, pairingCode != nil {
            pairingCode = nil
            pairingExpiresAt = nil
            publishState()
        }
        guard failures < 5,
              let expectedCode,
              Self.constantTimeEqual(submittedCode, expectedCode)
        else {
            pairingFailuresByUser[user.id] = failures + 1
            _ = await send("Pairing failed. Generate a new code in Nirux Settings.", chatID: message.chat.id, client: client)
            return
        }

        pairedUserID = user.id
        pairedChatID = message.chat.id
        pairingCode = nil
        pairingExpiresAt = nil
        pairingFailuresByUser.removeAll()
        updatePersistedPairing(userID: user.id, chatID: message.chat.id)
        publishState()
        _ = await send(
            "Paired with Nirux. Use /sessions to choose a live agent, then send a prompt or reply to a notification.",
            chatID: message.chat.id,
            client: client
        )
    }

    private func handle(_ command: TelegramCommand, chatID: Int64, client: TelegramBotClient) async {
        switch command {
        case .help:
            _ = await send(Self.helpText, chatID: chatID, client: client)
        case .sessions:
            await sendSessions(chatID: chatID, client: client)
        case .status:
            guard let session = selectedSession() else {
                await sendSessions(chatID: chatID, client: client)
                return
            }
            let message = await send(statusText(for: session), chatID: chatID, client: client)
            if let message { rememberReplyRoute(message.messageID, agentUUID: session.id) }
        case .tail:
            guard let session = selectedSession() else {
                await sendSessions(chatID: chatID, client: client)
                return
            }
            let output = session.recentOutput.isEmpty ? "No recent terminal output." : session.recentOutput
            let message = await send(
                "\(session.workspaceTitle) · column \(session.columnIndex + 1)\n\n\(output)",
                chatID: chatID,
                client: client
            )
            if let message { rememberReplyRoute(message.messageID, agentUUID: session.id) }
        case .pair:
            _ = await send("This bot is already paired.", chatID: chatID, client: client)
        case let .unknown(name):
            let label = name.isEmpty ? "Unknown command." : "Unknown command /\(name)."
            _ = await send("\(label) Use /help for supported commands.", chatID: chatID, client: client)
        }
    }

    private func handle(_ callback: TelegramCallbackQuery, client: TelegramBotClient) async {
        guard let chatID = callback.message?.chat.id,
              isAuthorized(userID: callback.from.id, chatID: chatID),
              let data = callback.data,
              data.hasPrefix("session:")
        else {
            try? await client.answerCallbackQuery(id: callback.id)
            return
        }
        let agentUUID = String(data.dropFirst("session:".count))
        guard let session = sessionsProvider().first(where: { $0.id == agentUUID }) else {
            try? await client.answerCallbackQuery(id: callback.id, text: "That agent session is no longer live.")
            return
        }
        selectedAgentUUID = session.id
        try? await client.answerCallbackQuery(id: callback.id, text: "Selected \(session.workspaceTitle)")
        let message = await send(statusText(for: session), chatID: chatID, client: client)
        if let message { rememberReplyRoute(message.messageID, agentUUID: session.id) }
    }

    private func sendSessions(chatID: Int64, client: TelegramBotClient) async {
        let sessions = sessionsProvider()
        guard !sessions.isEmpty else {
            selectedAgentUUID = nil
            _ = await send("No recognized live agent sessions are available.", chatID: chatID, client: client)
            return
        }
        if sessions.count == 1 { selectedAgentUUID = sessions[0].id }
        let lines = sessions.enumerated().map { index, session in
            "\(index + 1). \(session.workspaceTitle) · col \(session.columnIndex + 1) · \(session.statusLabel)"
        }
        let keyboard = TelegramInlineKeyboard(inlineKeyboard: sessions.map { session in
            [TelegramInlineKeyboardButton(
                text: "\(session.workspaceTitle) · col \(session.columnIndex + 1)",
                callbackData: "session:\(session.id)"
            )]
        })
        _ = await send(
            "Live agent sessions\n\n\(lines.joined(separator: "\n"))\n\nChoose one below.",
            chatID: chatID,
            keyboard: keyboard,
            client: client
        )
    }

    private func sendPrompt(
        _ text: String,
        preferredTarget: String?,
        chatID: Int64,
        client: TelegramBotClient
    ) async {
        let target = preferredTarget ?? selectedAgentUUID ?? singleSessionID
        guard let target else {
            await sendSessions(chatID: chatID, client: client)
            return
        }
        switch promptSender(target, text) {
        case let .sent(session):
            selectedAgentUUID = session.id
            let message = await send(
                "Prompt sent to \(session.workspaceTitle) · column \(session.columnIndex + 1).",
                chatID: chatID,
                client: client
            )
            if let message { rememberReplyRoute(message.messageID, agentUUID: session.id) }
        case .sessionUnavailable:
            if selectedAgentUUID == target { selectedAgentUUID = nil }
            _ = await send("That agent session is no longer live. Use /sessions to choose another.", chatID: chatID, client: client)
        case .emptyPrompt:
            _ = await send("The prompt was empty after removing terminal control characters.", chatID: chatID, client: client)
        }
    }

    private func sendAgentNotification(
        label: String,
        workspaceTitle: String,
        columnNumber: Int,
        agentUUID: String,
        detail: String?
    ) async {
        guard let client, let chatID = pairedChatID, isAuthorizedConfiguration else { return }
        var text = "\(label)\nWorkspace: \(workspaceTitle)\nColumn: \(columnNumber)"
        if let detail, !detail.isEmpty { text += "\n\n\(detail)" }
        let keyboard = TelegramInlineKeyboard(inlineKeyboard: [[
            TelegramInlineKeyboardButton(text: "Continue this session", callbackData: "session:\(agentUUID)")
        ]])
        let message = await send(text, chatID: chatID, keyboard: keyboard, client: client)
        if let message { rememberReplyRoute(message.messageID, agentUUID: agentUUID) }
    }

    private func selectedSession() -> RemoteAgentSession? {
        let sessions = sessionsProvider()
        if let selectedAgentUUID,
           let selected = sessions.first(where: { $0.id == selectedAgentUUID }) {
            return selected
        }
        if sessions.count == 1 {
            selectedAgentUUID = sessions[0].id
            return sessions[0]
        }
        return nil
    }

    private var singleSessionID: String? {
        let sessions = sessionsProvider()
        return sessions.count == 1 ? sessions[0].id : nil
    }

    private func statusText(for session: RemoteAgentSession) -> String {
        "Workspace: \(session.workspaceTitle)\n"
            + "Column: \(session.columnIndex + 1)\n"
            + "Session: \(session.displayName)\n"
            + "Status: \(session.statusLabel)\n"
            + "Directory: \(session.cwd)"
    }

    @discardableResult
    private func send(
        _ text: String,
        chatID: Int64,
        keyboard: TelegramInlineKeyboard? = nil,
        client: TelegramBotClient
    ) async -> TelegramMessage? {
        let limited = text.count > 4_096 ? String(text.prefix(4_095)) + "…" : text
        do {
            return try await client.sendMessage(chatID: chatID, text: limited, keyboard: keyboard)
        } catch {
            if Task.isCancelled { return nil }
            let description = error.localizedDescription
            if lastError != description {
                lastError = description
                publishState()
            }
            return nil
        }
    }

    private func rememberReplyRoute(_ messageID: Int64, agentUUID: String) {
        replyRoutes[messageID] = agentUUID
        replyRouteOrder.append(messageID)
        if replyRouteOrder.count > 100 {
            let removeCount = replyRouteOrder.count - 100
            let expired = Array(replyRouteOrder.prefix(removeCount))
            replyRouteOrder.removeFirst(removeCount)
            for messageID in expired { replyRoutes.removeValue(forKey: messageID) }
        }
    }

    private func isAuthorized(userID: Int64, chatID: Int64) -> Bool {
        userID == pairedUserID && chatID == pairedChatID
    }

    private func isCurrentPoll(_ generation: Int) -> Bool {
        !Task.isCancelled && generation == pollGeneration
    }

    private func updatePersistedPairing(userID: Int64?, chatID: Int64?) {
        var state = Persistence.load() ?? PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        var settings = state.settings ?? PersistedSettings()
        settings.telegramPairedUserID = userID
        settings.telegramPairedChatID = chatID
        state.settings = settings
        Persistence.save(state)
    }

    private func persistLastUpdateID(_ updateID: Int64) -> Bool {
        var state = Persistence.load() ?? PersistedState(workspaces: [], activeWorkspaceIndex: 0)
        var settings = state.settings ?? PersistedSettings()
        guard updateID > (settings.telegramLastUpdateID ?? Int64.min) else { return true }
        settings.telegramLastUpdateID = updateID
        state.settings = settings
        return Persistence.save(state)
    }

    private func publishState() {
        onStateChange?()
    }

    private static func safeDetail(_ value: String) -> String? {
        RemotePromptSanitizer.sanitize(String(value.prefix(700)))
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            difference |= Int(left[safe: index] ?? 0) ^ Int(right[safe: index] ?? 0)
        }
        return difference == 0
    }

    private static let helpText = """
    Nirux Telegram Remote Access

    /sessions — list and select recognized live agent sessions
    /status — show the selected session status
    /tail — show recent terminal output
    /help — show this message

    After selecting a session, send ordinary text as a prompt. You can also reply directly to a Nirux notification.
    Shell execution commands are not supported.
    """
}

import Foundation

struct TelegramBotClient: Sendable {
    enum ClientError: LocalizedError {
        case invalidToken
        case invalidResponse
        case httpStatus(Int)
        case api(String)

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "The Telegram bot token is invalid."
            case .invalidResponse: return "Telegram returned an invalid response."
            case let .httpStatus(status): return "Telegram returned HTTP \(status)."
            case let .api(description): return description
            }
        }
    }

    let token: String
    let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    func getUpdates(offset: Int64?, timeout: Int = 25) async throws -> [TelegramUpdate] {
        try await request(
            method: "getUpdates",
            body: GetUpdatesRequest(
                offset: offset,
                limit: 50,
                timeout: timeout,
                allowedUpdates: ["message", "callback_query"]
            ),
            timeout: TimeInterval(timeout + 10)
        )
    }

    func sendMessage(
        chatID: Int64,
        text: String,
        keyboard: TelegramInlineKeyboard? = nil
    ) async throws -> TelegramMessage {
        try await request(
            method: "sendMessage",
            body: SendMessageRequest(chatID: chatID, text: text, replyMarkup: keyboard)
        )
    }

    func answerCallbackQuery(id: String, text: String? = nil) async throws {
        let _: Bool = try await request(
            method: "answerCallbackQuery",
            body: AnswerCallbackQueryRequest(callbackQueryID: id, text: text)
        )
    }

    private func request<Body: Encodable, Result: Decodable>(
        method: String,
        body: Body,
        timeout: TimeInterval = 30
    ) async throws -> Result {
        guard TelegramBotToken.isPlausible(token),
              let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)")
        else { throw ClientError.invalidToken }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpStatus(http.statusCode) }
        let envelope = try JSONDecoder().decode(TelegramAPIResponse<Result>.self, from: data)
        guard envelope.ok, let result = envelope.result else {
            throw ClientError.api(envelope.description ?? "Telegram rejected the request.")
        }
        return result
    }
}

private struct TelegramAPIResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
}

private struct GetUpdatesRequest: Encodable {
    let offset: Int64?
    let limit: Int
    let timeout: Int
    let allowedUpdates: [String]

    enum CodingKeys: String, CodingKey {
        case offset, limit, timeout
        case allowedUpdates = "allowed_updates"
    }
}

private struct SendMessageRequest: Encodable {
    let chatID: Int64
    let text: String
    let replyMarkup: TelegramInlineKeyboard?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
        case replyMarkup = "reply_markup"
    }
}

private struct AnswerCallbackQueryRequest: Encodable {
    let callbackQueryID: String
    let text: String?

    enum CodingKeys: String, CodingKey {
        case callbackQueryID = "callback_query_id"
        case text
    }
}

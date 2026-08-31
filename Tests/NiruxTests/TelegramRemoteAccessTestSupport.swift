import Foundation

final class TelegramAPIStub: @unchecked Sendable {
    struct SentMessage: Equatable {
        let text: String
        let callbackData: [String]
    }

    struct Snapshot {
        let sentMessages: [SentMessage]
        let getUpdatesOffsets: [Int64?]
        let callbackAnswers: Int
        let requestedMethods: Set<String>
    }

    private let lock = NSLock()
    private var servedUpdateBatch = false
    private var nextMessageID: Int64 = 100
    private var storedMessages: [SentMessage] = []
    private var storedOffsets: [Int64?] = []
    private var storedCallbackAnswers = 0
    private var storedMethods: Set<String> = []
    private var queuedUpdateBatch: [[String: Any]] = controllerUpdateBatch
    private var storedSendMessageDelay: TimeInterval = 0
    private let sendStateLock = NSLock()
    private var storedSendMessageStartedCount = 0

    var sentMessages: [SentMessage] { snapshot().sentMessages }
    var sendMessageStartedCount: Int {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }
        return storedSendMessageStartedCount
    }

    func reset(
        updateBatch: [[String: Any]]? = nil,
        sendMessageDelay: TimeInterval = 0
    ) {
        lock.lock()
        servedUpdateBatch = false
        queuedUpdateBatch = updateBatch ?? Self.controllerUpdateBatch
        storedSendMessageDelay = sendMessageDelay
        nextMessageID = 100
        storedMessages = []
        storedOffsets = []
        storedCallbackAnswers = 0
        storedMethods = []
        sendStateLock.lock()
        storedSendMessageStartedCount = 0
        sendStateLock.unlock()
        lock.unlock()
    }

    func queue(updateBatch: [[String: Any]]) {
        lock.lock()
        queuedUpdateBatch = updateBatch
        servedUpdateBatch = false
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            sentMessages: storedMessages,
            getUpdatesOffsets: storedOffsets,
            callbackAnswers: storedCallbackAnswers,
            requestedMethods: storedMethods
        )
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else { throw URLError(.badURL) }
        let method = url.lastPathComponent
        let body = Self.bodyData(for: request)

        lock.lock()
        defer { lock.unlock() }
        storedMethods.insert(method)
        let result: Any
        switch method {
        case "getUpdates":
            let requestObject = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            storedOffsets.append((requestObject?["offset"] as? NSNumber)?.int64Value)
            if servedUpdateBatch {
                result = []
            } else {
                servedUpdateBatch = true
                result = queuedUpdateBatch
            }
        case "sendMessage":
            let requestObject = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
            let text = requestObject["text"] as? String ?? ""
            let keyboard = requestObject["reply_markup"] as? [String: Any]
            let rows = keyboard?["inline_keyboard"] as? [[Any]] ?? []
            let callbackData = rows.flatMap { row in
                row.compactMap { button in
                    (button as? [String: Any])?["callback_data"] as? String
                }
            }
            storedMessages.append(SentMessage(text: text, callbackData: callbackData))
            sendStateLock.lock()
            storedSendMessageStartedCount += 1
            sendStateLock.unlock()
            if storedSendMessageDelay > 0 {
                Thread.sleep(forTimeInterval: storedSendMessageDelay)
            }
            nextMessageID += 1
            let chatID = (requestObject["chat_id"] as? NSNumber)?.int64Value ?? 123
            result = [
                "message_id": nextMessageID,
                "chat": ["id": chatID, "type": "private"],
                "text": text
            ]
        case "answerCallbackQuery":
            storedCallbackAnswers += 1
            result = true
        default:
            throw URLError(.unsupportedURL)
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result])
        return (response, data)
    }

    private static var controllerUpdateBatch: [[String: Any]] {
        [
            messageUpdate(id: 1, messageID: 1, userID: 999, chatID: 999, text: "steal secrets"),
            messageUpdate(id: 2, messageID: 2, userID: 123, chatID: 123, text: "/sessions"),
            [
                "update_id": 3,
                "callback_query": [
                    "id": "select-agent-b",
                    "from": ["id": 123],
                    "message": ["message_id": 3, "chat": ["id": 123, "type": "private"]],
                    "data": "session:agent-b"
                ]
            ],
            messageUpdate(id: 4, messageID: 4, userID: 123, chatID: 123, text: "/status"),
            messageUpdate(id: 5, messageID: 5, userID: 123, chatID: 123, text: "/tail"),
            messageUpdate(id: 6, messageID: 6, userID: 123, chatID: 123, text: "  explain\u{1B}[31m this safely  "),
            messageUpdate(id: 7, messageID: 7, userID: 123, chatID: 123, text: "/exec whoami"),
            messageUpdate(
                id: 8,
                messageID: 8,
                userID: 123,
                chatID: 123,
                text: "continue",
                replyToMessageID: 9_999
            ),
            [
                "update_id": 9,
                "callback_query": [
                    "id": "unauthorized-selection",
                    "from": ["id": 999],
                    "message": ["message_id": 9, "chat": ["id": 999, "type": "private"]],
                    "data": "session:agent-a"
                ]
            ]
        ]
    }

    static func messageUpdate(
        id: Int64,
        messageID: Int64,
        userID: Int64,
        chatID: Int64,
        chatType: String = "private",
        text: String,
        replyToMessageID: Int64? = nil
    ) -> [String: Any] {
        var message: [String: Any] = [
            "message_id": messageID,
            "from": ["id": userID],
            "chat": ["id": chatID, "type": chatType],
            "text": text
        ]
        if let replyToMessageID {
            message["reply_to_message"] = ["message_id": replyToMessageID]
        }
        return ["update_id": id, "message": message]
    }

    private static func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

final class TelegramURLProtocolStub: URLProtocol {
    static let api = TelegramAPIStub()

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.telegram.org"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.api.response(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

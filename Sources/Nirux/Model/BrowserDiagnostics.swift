import Foundation

struct BrowserDiagnostics {
    enum Kind: String {
        case error, warn, exception, rejection, fetch, xhr
    }

    struct Event {
        let kind: Kind
        let message: String
    }

    static let capacity = 200
    private var storage: [Event] = []
    private var oldest = 0

    var events: [Event] { Array(storage[oldest...] + storage[..<oldest]) }
    var consoleErrorCount: Int { storage.count { $0.kind == .error } }

    mutating func append(kind: Kind, message: String) {
        let event = Event(kind: kind, message: Self.sanitized(message))
        if storage.count < Self.capacity {
            storage.append(event)
        } else {
            storage[oldest] = event
            oldest = (oldest + 1) % Self.capacity
        }
    }

    static func sanitized(_ message: String) -> String {
        // Inspect beyond the output boundary so trimming cannot disguise a token.
        let input = String(decoding: message.utf8.prefix(8192), as: UTF8.self)
        let plain = input.components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ")
        guard !HistorySearch.holdsSecret(plain),
              plain.range(of: #"(?i)\b(?:bearer\s+\S|(?:password|token|secret|api[_-]?key|cookie)\s*[=:]\s*\S)"#,
                          options: .regularExpression) == nil else { return "[redacted]" }
        var output = ""
        for scalar in plain.unicodeScalars {
            guard output.utf8.count + scalar.utf8.count <= 1024 else { break }
            output.unicodeScalars.append(scalar)
        }
        return output
    }
}

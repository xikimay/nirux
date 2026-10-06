import Foundation

extension ProjectHistory {
    /// `text` with each key replaced by `[secret withheld]` (Explain's keys,
    /// `BranchReview.Secrets.keyRanges`, and what history search looks for
    /// in chat, `HistorySearch.chatSecretRanges`), or a marker alone when the
    /// detectors couldn't run over it.
    static func withholdingSecrets(_ text: String) -> String {
        guard let keys = BranchReview.Secrets.keyRanges(in: text),
              let chat = HistorySearch.chatSecretRanges(in: text) else { return withheldMessage }
        guard !keys.isEmpty || !chat.isEmpty else { return text }
        var ranges: [Range<String.Index>] = []
        for range in (keys + chat).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        var result = ""
        var start = text.startIndex
        for range in ranges {
            result += text[start..<range.lowerBound]
            result += withheldKey
            start = range.upperBound
        }
        result += text[start...]
        return result
    }

    static let withheldKey = "[secret withheld]"
    static let withheldMessage = "[withheld: the message looked like it held a secret]"
}

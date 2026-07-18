import Foundation

/// Subsequence-based fuzzy matcher for palette-style filtering.
/// Returns a score (higher = better) when every query character appears
/// in the candidate in order; nil when the query is not a subsequence.
enum FuzzyMatch {
    /// Score bonuses/penalties tuned for short action titles.
    private static let consecutiveBonus = 8
    private static let wordStartBonus = 12
    private static let separatorBonus = 10
    private static let camelBonus = 6

    static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let queryChars = Array(query.lowercased())
        let candidateLower = Array(candidate.lowercased())
        let candidateOrig = Array(candidate)
        guard queryChars.count <= candidateLower.count else { return nil }
        // lowercased() can change grapheme count for a few exotic chars;
        // camelCase bonus just gets skipped in that case.
        let canCheckCamel = candidateOrig.count == candidateLower.count

        var score = 0
        var queryIndex = 0
        var lastMatchIndex = -2
        var firstMatchIndex = -1

        for (candidateIndex, char) in candidateLower.enumerated() {
            guard queryIndex < queryChars.count, char == queryChars[queryIndex] else { continue }
            if firstMatchIndex < 0 { firstMatchIndex = candidateIndex }

            score += 1

            if candidateIndex == lastMatchIndex + 1 {
                score += consecutiveBonus
            }

            if candidateIndex == 0 {
                score += wordStartBonus
            } else {
                let prev = candidateLower[candidateIndex - 1]
                if prev == " " || prev == "-" || prev == "_" || prev == "/" || prev == "." || prev == "(" {
                    score += separatorBonus
                } else if canCheckCamel,
                          candidateOrig[candidateIndex].isUppercase,
                          !candidateOrig[candidateIndex - 1].isUppercase {
                    score += camelBonus
                }
            }

            lastMatchIndex = candidateIndex
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }

        // Prefer matches that start early, on shorter candidates.
        score -= firstMatchIndex
        score -= candidateLower.count / 8
        return score
    }

    /// Filter + rank `items` against `query`. Empty query returns the input unchanged.
    static func filter<T>(_ items: [T], query: String, key: (T) -> String) -> [T] {
        if query.isEmpty { return items }
        return items.enumerated()
            .compactMap { index, item -> (item: T, score: Int, index: Int)? in
                guard let score = score(query: query, candidate: key(item)) else { return nil }
                return (item, score, index)
            }
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.index < rhs.index
            }
            .map { $0.item }
    }
}

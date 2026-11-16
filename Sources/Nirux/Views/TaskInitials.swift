
import Foundation

/// A task's letters, written in its rail icon's ring: the first letter of
/// the first two words ("Fix login rate limit" → "FL"), a number whole
/// ("ws 12" → "W12"). A branch drops its type ("feat/crash-report" →
/// "CR"); one word gives its first two letters ("main" → "MA"). A repeat
/// takes a number: "CR2". (The rail of initials' rule, before 3.2.)
enum TaskInitials {
    static func initials(for titles: [String]) -> [String] {
        var used: Set<String> = []
        return titles.map { title in
            let base = initials(of: title)
            var candidate = base
            var number = 2
            while used.contains(candidate) {
                candidate = "\(base)\(number)"
                number += 1
            }
            used.insert(candidate)
            return candidate
        }
    }

    static func initials(of title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = words(in: branchName(trimmed) ?? trimmed)
        let letters: String
        switch words.count {
        case 0: letters = String(trimmed.prefix(1))
        case 1: letters = String(words[0].prefix(2))
        default:
            let second = words[1].allSatisfy(\.isNumber) ? words[1].prefix(3) : words[1].prefix(1)
            letters = String(words[0].prefix(1) + second)
        }
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// "feat/crash-report" → "crash-report": what follows a branch's last
    /// "/". Nil for a title with a space ("Fix A/B test").
    private static func branchName(_ title: String) -> String? {
        guard title.contains("/"), !title.contains(where: \.isWhitespace) else { return nil }
        return title.split(separator: "/").last.map(String.init)
    }

    /// Runs of letters, or of digits; "CelticFantasy" is two words.
    private static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if let last = current.last,
               (character.isUppercase && last.isLowercase) || character.isNumber != last.isNumber {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

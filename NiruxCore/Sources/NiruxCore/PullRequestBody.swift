import Foundation

/// What Nirux reads in a pull request's body.
public enum PullRequestBody {
    /// Its "## Why" section on one line, else its first paragraph.
    public static func why(_ body: String, maxLength: Int) -> String? {
        let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let section: ArraySlice<String>
        if let heading = lines.firstIndex(where: { $0.lowercased() == "## why" }) {
            section = lines[(heading + 1)...].prefix { !$0.hasPrefix("#") }
        } else {
            section = lines.drop(while: \.isEmpty).prefix { !$0.isEmpty }
        }
        return AgentText.clean(section.joined(separator: " "), maxLength: maxLength)
    }
}

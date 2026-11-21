import Foundation

extension String {
    /// The first line holding more than whitespace, trimmed.
    var firstLine: String? {
        split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

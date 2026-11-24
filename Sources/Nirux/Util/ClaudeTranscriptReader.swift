import Foundation

/// The usage of a Claude session, read off the main thread (see
/// `ClaudeUsageFollower`).
typealias ClaudeTranscriptReader = TranscriptLineReader<ClaudeTranscriptUsageParser>

extension TranscriptLineReader where Parser == ClaudeTranscriptUsageParser {
    var usage: ClaudeSessionUsage { parser.usage }
}

extension TranscriptLineReader where Parser == TranscriptPromptParser {
    /// The prompts read since the last call.
    mutating func takePrompts() -> [TranscriptPrompt] {
        parser.takePrompts()
    }
}

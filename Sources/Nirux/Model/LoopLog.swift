import Foundation

/// The permission prompts and questions of each space's Claude sessions,
/// from the PermissionRequest hooks Nirux already receives (Space Settings
/// › Safety, "Where you're still in the loop"). A line holds the time, the
/// tool, what the prompt was about (`AgentHookEvent.promptTarget`) and the
/// permission mode: never a command's text, a file's contents or a
/// question. Kept 30 days in `loop.jsonl` (SpaceLog).
enum LoopLog {
    static let lines = SpaceLog<Entry>(fileName: "loop.jsonl", keptDays: 30, maxFileBytes: 4_000_000) { $0.time }

    struct Entry: Codable, Equatable, Sendable {
        var time: TimeInterval
        var tool: String
        var target: String?
        var mode: String?
        /// A line naming the target covers exactly what prompted
        /// (`AgentHookEvent.promptExact`); nil reads as no.
        var exact: Bool?

        enum CodingKeys: String, CodingKey { case time = "t", tool, target, mode, exact }
    }

    /// The prompt an event reports, or nil.
    static func entry(of event: AgentHookEvent) -> Entry? {
        guard event.kind == .claude, event.name == .permissionRequest, let tool = event.toolName else { return nil }
        return Entry(time: event.timestamp, tool: tool, target: event.promptTarget, mode: event.permissionMode, exact: event.promptExact)
    }
}

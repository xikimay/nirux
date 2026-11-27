import Foundation

extension Plan {
    /// A space's plan, in `plan.json` beside its brief, written by the app only. A file this build can't take as a
    /// plan (not one it decodes, a newer `schemaVersion`, too large, not a regular file, unreadable just now) is never
    /// replaced: changes are refused with the reason, so a day's plan is never lost.
    public struct Store: Sendable {
        public static let fileName = "plan.json"
        public static let schemaVersion = 1
        public static let maxFileBytes = 1 << 20

        public let fileURL: URL

        public init(fileURL: URL) {
            self.fileURL = fileURL
        }

        public struct Loaded: Equatable, Sendable {
            public var plan: Plan
            public var readOnlyReason: String?
        }

        private struct File: Codable {
            var schemaVersion: Int
            var plan: Plan
        }

        public func load() -> Loaded {
            switch RegularFileRead.read(fileURL, maxBytes: Self.maxFileBytes) {
            case .missing:
                return Loaded(plan: Plan())
            case .unreadableBytes:
                return Loaded(plan: Plan(), readOnlyReason: "\(Self.fileName) can't be read just now: try again.")
            case .tooLarge, .notARegularFile:
                return Loaded(plan: Plan(), readOnlyReason: "\(Self.fileName) isn't a small regular file: Nirux leaves it alone.")
            case .data(let data):
                guard let file = try? JSONDecoder().decode(File.self, from: data) else {
                    return Loaded(plan: Plan(), readOnlyReason: "Nirux can't read \(Self.fileName): it leaves it as it is.")
                }
                return Loaded(plan: file.plan, readOnlyReason: file.schemaVersion > Self.schemaVersion ? "A newer Nirux keeps this plan." : nil)
            }
        }

        /// Changes the plan as the file has it, and writes it when the change changed anything: a file it can't
        /// replace still answers what changes nothing.
        public func update<Result>(_ change: (inout Plan) throws -> Result) throws -> Result {
            let loaded = load()
            var plan = loaded.plan
            let result = try change(&plan)
            guard plan != loaded.plan else { return result }
            if let reason = loaded.readOnlyReason { throw Problem(reason) }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                try PrivateFileWrite.write(encoder.encode(File(schemaVersion: Self.schemaVersion, plan: plan)), to: fileURL)
            } catch {
                throw Problem("Nirux couldn't save the plan: \(error.localizedDescription)")
            }
            return result
        }
    }
}

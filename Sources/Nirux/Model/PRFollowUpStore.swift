import Foundation

/// Each pull request's follow-up (`PRFollowUp.Entry`), by URL, in
/// `pr-follow-up.json` in the state directory: its rounds outlive a
/// relaunch and a workspace opened again.
struct PRFollowUpStore: Codable, Equatable {
    var pullRequests: [String: PRFollowUp.Entry] = [:]

    /// An entry nothing changed for this long goes: its pull request merged
    /// or closed while no workspace followed it.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    /// Changes the entry of `url`, stamped `now` when that changed
    /// anything; returns whether it did.
    @discardableResult
    mutating func update(_ url: String, now: TimeInterval, _ change: (inout PRFollowUp.Entry) -> Void) -> Bool {
        var entry = pullRequests[url] ?? PRFollowUp.Entry()
        let before = entry
        change(&entry)
        guard entry != before else { return false }
        entry.updatedAt = now
        pullRequests[url] = entry
        pullRequests = pullRequests.filter { now - $0.value.updatedAt < Self.lifetime }
        return true
    }

    static var url: URL { Persistence.stateDirectory.appendingPathComponent("pr-follow-up.json") }

    /// Empty for a missing or unreadable file.
    static func load(from url: URL = url) -> PRFollowUpStore {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PRFollowUpStore.self, from: $0) } ?? PRFollowUpStore()
    }

    /// 0600: it lists the user's pull requests.
    func save(to url: URL = url) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try SpaceDefaultsStore.writePrivately(encoder.encode(self), to: url)
        } catch {
            NiruxDebugLog.log("PRFollowUpStore: could not save \(url.path): \(error)")
        }
    }
}

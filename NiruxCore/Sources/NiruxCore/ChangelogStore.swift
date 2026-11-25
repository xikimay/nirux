import Foundation

/// The nightlies' changelog, published beside the appcast: read from its
/// copy on disk at once, fetched again when asked.
@MainActor
public final class ChangelogStore {
    public typealias Loader = @Sendable (URL) async throws -> Data

    /// changelog.json, beside the appcast.
    public let url: URL
    /// The repository the nightlies come from: "https://github.com/owner/name".
    public let repository: URL
    public private(set) var changelog: Changelog?
    /// Why the last fetch failed; nil once one succeeds.
    public private(set) var failure: String?
    private let cache: URL
    private let load: Loader
    private let onChange: @MainActor () -> Void
    private var fetch: Task<Void, Never>?

    /// Nil for a feed that isn't a GitHub release's appcast.
    public init?(feed: String?, cache: URL, load: @escaping Loader = ChangelogStore.download, onChange: @escaping @MainActor () -> Void) {
        guard let feed, let feedURL = URL(string: feed), feedURL.host == "github.com" else { return nil }
        let path = feedURL.pathComponents
        guard path.count > 3, path[3] == "releases" else { return nil }
        url = feedURL.deletingLastPathComponent().appendingPathComponent("changelog.json")
        repository = URL(string: "https://github.com/\(path[1])/\(path[2])")!
        self.cache = cache
        self.load = load
        self.onChange = onChange
        changelog = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode(Changelog.self, from: $0) }
    }

    public func pullRequestURL(_ number: Int) -> URL {
        repository.appendingPathComponent("pull/\(number)")
    }

    /// Fetches the published changelog, one fetch at a time, and keeps it on
    /// disk; `onChange` follows either way.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        if let fetch { return fetch }
        let started = Task { [url, load, cache] in
            do {
                let data = try await load(url)
                changelog = try JSONDecoder().decode(Changelog.self, from: data)
                failure = nil
                try? data.write(to: cache, options: .atomic)
            } catch {
                failure = error.localizedDescription
            }
            fetch = nil
            onChange()
        }
        fetch = started
        return started
    }

    struct Unpublished: LocalizedError {
        let status: Int
        var errorDescription: String? {
            status == 404 ? "No changelog is published yet." : "GitHub answered \(status)."
        }
    }

    @Sendable
    public static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Unpublished(status: status) }
        return data
    }
}

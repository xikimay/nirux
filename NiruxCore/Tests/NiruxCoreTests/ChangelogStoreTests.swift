import Foundation
import NiruxCore
import Testing

@MainActor
struct ChangelogStoreTests {
    static let feed = "https://github.com/xikimay/nirux/releases/download/nightly/appcast.xml"
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("changelog-\(UUID().uuidString).json")
    let published = Changelog(entries: [
        Changelog.Entry(pullRequest: 913, title: "⌘P: open a pull request", why: nil, kind: .new, build: 202611251854),
    ], commit: "dc3366a0")

    @Test func theChangelogSitsBesideTheAppcast() throws {
        let made = ChangelogStore(feed: Self.feed, cache: cache, onChange: {})
        let store = try #require(made)
        #expect(store.url.absoluteString == "https://github.com/xikimay/nirux/releases/download/nightly/changelog.json")
        #expect(store.pullRequestURL(913).absoluteString == "https://github.com/xikimay/nirux/pull/913")
        let withoutFeed = ChangelogStore(feed: nil, cache: cache, onChange: {})
        let elsewhere = ChangelogStore(feed: "https://example.com/appcast.xml", cache: cache, onChange: {})
        #expect(withoutFeed == nil && elsewhere == nil)
    }

    @Test func aFetchIsKeptForTheNextLaunch() async throws {
        defer { try? FileManager.default.removeItem(at: cache) }
        let data = try JSONEncoder().encode(published)
        var changes = 0
        let made = ChangelogStore(feed: Self.feed, cache: cache, load: { _ in data }, onChange: { changes += 1 })
        let store = try #require(made)
        #expect(store.changelog == nil)
        await store.refresh().value
        #expect(store.changelog == published)
        #expect(changes == 1)
        let relaunched = ChangelogStore(feed: Self.feed, cache: cache, onChange: {})
        #expect(relaunched?.changelog == published)
    }

    @Test func aFailedFetchKeepsWhatWasRead() async throws {
        defer { try? FileManager.default.removeItem(at: cache) }
        try JSONEncoder().encode(published).write(to: cache)
        let made = ChangelogStore(feed: Self.feed, cache: cache, load: { _ in throw URLError(.notConnectedToInternet) }, onChange: {})
        let store = try #require(made)
        await store.refresh().value
        #expect(store.changelog == published)
        #expect(store.failure != nil)
    }
}

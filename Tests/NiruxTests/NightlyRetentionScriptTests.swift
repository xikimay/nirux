import XCTest

/// Which dated nightly releases the nightly workflow deletes: runs
/// scripts/nightly-releases-to-prune.sh on `gh release list` JSON fixtures.
/// The workflow's own settings: keep the 20 most recent, and every release
/// published in the last 7 days.
final class NightlyRetentionScriptTests: XCTestCase {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/nightly-releases-to-prune.sh").path
    private let now = "2026-09-28T12:00:00Z"
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    override func setUpWithError() throws {
        // The script needs jq; the macOS runners and macOS 15 ship it.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["jq", "--version"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        try XCTSkipIf(probe.terminationStatus != 0, "jq is not installed")
    }

    // MARK: - Retention rule

    func testBusyDayKeepsEveryReleaseOfTheLastSevenDays() throws {
        // 2026-09-27 published 34 nightlies in a day.
        let releases = (0..<34).map { dated(Double($0) * 40 * 60, index: $0) }
        XCTAssertEqual(try prune(releases), [])
    }

    func testKeepsTheTwentyMostRecentEvenWhenOlderThanSevenDays() throws {
        let releases = (0..<30).map { dated(hour + Double($0) * day, index: $0) }
        XCTAssertEqual(try prune(releases), tags(releases[20...]))
    }

    func testDeletesWhatIsBothBeyondTheTwentyAndOlderThanSevenDays() throws {
        let recent = (0..<25).map { dated(Double($0) * 2 * hour, index: $0) }
        let old = (0..<10).map { dated(8 * day + Double($0) * day, index: 100 + $0) }
        XCTAssertEqual(try prune(recent + old), tags(old))
    }

    func testFewerThanTwentyOldReleasesAreAllKept() throws {
        let releases = (0..<15).map { dated(30 * day + Double($0) * day, index: $0) }
        XCTAssertEqual(try prune(releases), [])
    }

    func testSevenDayBoundary() throws {
        let exactlySevenDays = dated(7 * day, index: 1)
        let justOlder = dated(7 * day + 1, index: 2)
        XCTAssertEqual(try prune([exactlySevenDays, justOlder], keep: 0), tags([justOlder]))
    }

    func testRanksByPublishTimeNotInputOrderTagOrCommitDate() throws {
        // A re-run tags the build time and publishes later: the release with
        // the earlier tag can be the more recent one. createdAt is the commit's
        // date, which gh sorts by.
        let publishedLater = release("nightly-2026.09.10-0100-aaaaaaa", published: "2026-09-10T03:00:00Z",
                                     created: "2026-09-01T00:00:00Z")
        let publishedEarlier = release("nightly-2026.09.10-0200-bbbbbbb", published: "2026-09-10T02:30:00Z",
                                       created: "2026-09-09T00:00:00Z")
        let oldest = release("nightly-2026.09.09-0100-ccccccc", published: "2026-09-09T01:05:00Z",
                             created: "2026-09-09T23:00:00Z")
        XCTAssertEqual(try prune([oldest, publishedEarlier, publishedLater], keep: 1),
                       ["nightly-2026.09.10-0200-bbbbbbb", "nightly-2026.09.09-0100-ccccccc"])
    }

    func testADuplicatedEntryDoesNotPushAnotherReleaseOut() throws {
        let releases = (0..<25).map { dated(8 * day + Double($0) * day, index: $0) }
        XCTAssertEqual(try prune(releases + [releases[3]]), tags(releases[20...]))
    }

    func testPrintsNothingForAnEmptyListing() throws {
        XCTAssertEqual(try prune([]), [])
    }

    // MARK: - What is never deleted

    func testNeverSelectsTheRollingReleaseOrForeignTags() throws {
        let old = "2026-01-01T00:00:00Z"
        let foreign = [
            release("nightly", published: old),
            release("v1.0.0", published: old),
            release("nightly-2026.01.01", published: old),
            release("nightly-2026-01-01-0000-0ee6cb4", published: old),
            release("nightly-2026.01.01-0000-abc", published: old),
            release("nightly-2026.01.01-0000-0ee6cb4-rc1", published: old),
            release("nightly-2026.01.01-0000-0EE6CB4", published: old),
            release("xnightly-2026.01.01-0000-0ee6cb4", published: old),
        ]
        let dated = release("nightly-2026.01.01-0000-0ee6cb4", published: old)
        XCTAssertEqual(try prune(foreign + [dated], keep: 0, days: 0), [dated["tagName"] as? String])
    }

    func testTheRollingReleaseDoesNotTakeOneOfTheTwenty() throws {
        // Even published last, `nightly` must not count as one of the 20.
        let rolling = release("nightly", published: "2026-09-28T11:59:00Z")
        let old = (0..<21).map { dated(8 * day + Double($0) * day, index: $0) }
        XCTAssertEqual(try prune([rolling] + old), tags(old[20...]))
    }

    func testADraftCountsAsTheOldest() throws {
        // A publish that failed while uploading leaves a draft, which has no
        // publish time: gh prints Go's zero time.
        let newest = dated(hour, index: 1)
        let zero = release("nightly-2026.09.28-1100-0000002", published: "0001-01-01T00:00:00Z", draft: true)
        let null = release("nightly-2026.09.28-1100-0000003", published: nil, draft: true)
        let stamped = release("nightly-2026.09.28-1100-0000004", published: now, draft: true)
        let all = [zero, null, stamped, newest]
        XCTAssertEqual(try prune(all, keep: 1), tags([stamped, null, zero]))
        XCTAssertEqual(try prune(all, keep: 4), [])
    }

    // MARK: - Failing closed

    func testAnUnexpectedPublishTimeDeletesNothing() throws {
        // Older than `fine`, so a check made after sorting would already have
        // printed `fine`.
        let fine = dated(30 * day, index: 1)
        let published: [Any] = ["2026-08-01T00:00:00.5Z", "2026-08-01T00:00:00+00:00", "2026-08-01",
                                1_780_000_000, NSNull(), "0001-01-01T00:00:00Z"]
        for value in published {
            var odd = release("nightly-2026.08.01-0000-0000002", published: nil)
            odd["publishedAt"] = value
            XCTAssertThrowsError(try prune([fine, odd], keep: 0), "publishedAt \(value)")
        }
    }

    func testASecondDocumentAfterTheListingDeletesNothing() throws {
        let json = try JSONSerialization.data(withJSONObject: [dated(30 * day, index: 1)])
        XCTAssertThrowsError(try run([now, "0", "0"], input: String(decoding: json, as: UTF8.self) + " {"))
    }

    func testRejectsBadArguments() throws {
        for arguments in [["2026-09-28", "20", "7"], ["2026-09-28T12:00:00+02:00", "20", "7"],
                          [now, "-1", "7"], [now, "20", "x"], [now, "", "7"], [now, "20"]] {
            XCTAssertThrowsError(try run(arguments, input: "[]"), "\(arguments)")
        }
    }

    // MARK: - Helpers

    private struct ScriptFailure: Error {
        let status: Int32
        let output: String
    }

    /// The tags the script would delete, in its order (newest first).
    private func prune(_ releases: [[String: Any]], keep: Int = 20, days: Int = 7) throws -> [String] {
        let json = try JSONSerialization.data(withJSONObject: releases)
        let output = try run([now, String(keep), String(days)], input: String(decoding: json, as: UTF8.self))
        return output.split(separator: "\n").map(String.init)
    }

    private func run(_ arguments: [String], input: String) throws -> String {
        // A file, not a pipe: writing to a pipe the script never reads (it
        // exits early on bad arguments) would kill the test run with SIGPIPE.
        let inputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-nightly-releases-\(UUID().uuidString).json")
        try Data(input.utf8).write(to: inputFile)
        defer { try? FileManager.default.removeItem(at: inputFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.script)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = try FileHandle(forReadingFrom: inputFile)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // A failed selection must not have printed a partial list.
            XCTAssertEqual(output, "", "stdout of a failed run")
            throw ScriptFailure(status: process.terminationStatus, output: errors)
        }
        return output
    }

    /// A release as `gh release list --json tagName,publishedAt,isDraft`
    /// prints it, plus createdAt when given.
    private func release(_ tag: String, published: String?, created: String? = nil, draft: Bool = false) -> [String: Any] {
        var release: [String: Any] = ["tagName": tag, "publishedAt": published ?? NSNull(), "isDraft": draft]
        if let created { release["createdAt"] = created }
        return release
    }

    /// A release published `age` seconds before `now`, tagged the way the
    /// workflow tags it; `index` keeps the short SHAs distinct.
    private func dated(_ age: TimeInterval, index: Int) -> [String: Any] {
        let published = try! Date(now, strategy: .iso8601).addingTimeInterval(-age)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: published)
        let tag = String(format: "nightly-%04d.%02d.%02d-%02d%02d-%07x", c.year!, c.month!, c.day!, c.hour!, c.minute!, index)
        return release(tag, published: published.formatted(.iso8601))
    }

    private func tags<C: Collection>(_ releases: C) -> [String] where C.Element == [String: Any] {
        releases.map { $0["tagName"] as! String }
    }
}

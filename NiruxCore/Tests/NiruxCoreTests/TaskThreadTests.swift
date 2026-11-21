import Foundation
import NiruxCore
import Testing

struct TaskThreadTests {
    typealias Event = TaskThread.Event
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var store: TaskThread.Store { TaskThread.Store(folder: folder) }

    @Test func readsExistingLinesAndAppendsTheReadersEventFields() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try #require(store.fileURL(workspaceID: "task"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // An existing #718 file, including an unknown kind and a partial line after it.
        try Data(#"{"t":1,"kind":"other","by":"another","n":4}"#.utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{".utf8))
        try handle.close()
        let old = Event(time: 1, kind: .init("other"), by: .init("another"), number: 4)
        let check = Event(time: 2, kind: .checkRun, by: .nirux, ref: "url", recipient: .lead, missionID: "m", until: 3)
        let retired = Event(time: 4, kind: .questionRetired, ref: "q")
        let count = try store.append([check, retired], workspaceID: "task")
        #expect(count == 2)
        #expect(TaskThread.Store.load(from: url) == [old, check, retired])
        #expect(store.fileURL(workspaceID: "../task") == nil)
    }

    @Test func joinIsStableAndSuppressesReplayedEventsAndRepeatedStatusLines() {
        let first = Event(time: 10, kind: .status, text: "Building")
        let repeatStatus = Event(time: 20, kind: .status, text: "Building")
        let end = Event(time: 20, kind: .turnEnd)
        let next = Event(time: 20, kind: .status, text: "Ready")
        let again = Event(time: 30, kind: .status, text: "Building")
        #expect(TaskThread.ordered([end, repeatStatus, again, first, next, end, first]) == [first, end, next, again])
    }

    @Test func longTextsAreCutAndAFullFileTakesOnlyTheClose() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = "task"
        let url = try #require(store.fileURL(workspaceID: id))
        let long = [
            Event(time: 1, kind: .request, text: String(repeating: "r", count: 70_000)),
            Event(time: 2, kind: .question, text: String(repeating: "q", count: 9_000), note: String(repeating: "n", count: 9_000))
        ]
        try store.append(long, workspaceID: id)
        let loaded = TaskThread.Store.load(from: url)
        #expect(loaded.map { $0.text?.count } == [TaskThread.Store.maxRequestLength, TaskThread.Store.maxTextLength])
        #expect(loaded.last?.note?.count == TaskThread.Store.maxTextLength)

        let line = Event(time: 3, kind: .status, text: String(repeating: "x", count: TaskThread.Store.maxTextLength))
        let many = TaskThread.Store.maxFileBytes / TaskThread.Store.maxTextLength + 10
        let written = try store.append(Array(repeating: line, count: many), workspaceID: id)
        #expect(written < many)
        let extra = try store.append([line], workspaceID: id)
        #expect(extra == 0)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect((size ?? .max) <= TaskThread.Store.maxFileBytes)
        let short = Event(time: 3, kind: .turnEnd)
        let shortCount = try store.append(Array(repeating: short, count: 400), workspaceID: id)
        #expect(shortCount < 400)
        let close = Event(time: 4, kind: .closed, text: "https://github.com/o/r/pull/1")
        let finalCount = try store.append([line, close], workspaceID: id)
        #expect(finalCount == 1)
        #expect(TaskThread.Store.load(from: url).last == close)
    }

    @Test func pruningRemovesExpiredThenOldestAndExcludesOpenFilesFromTheBudget() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let now: TimeInterval = 2_000_000_000
        func thread(_ id: String, days: Double, bytes: Int) throws -> URL {
            try store.append([Event(time: 1, kind: .request)], workspaceID: id)
            let url = try #require(store.fileURL(workspaceID: id))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - days * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let open = try thread("open", days: 400, bytes: 15_000_000)
        let old = try thread("old", days: 200, bytes: 10)
        let recent = try thread("recent", days: 1, bytes: 6_000_000)
        let older = try thread("older", days: 3, bytes: 11_000_000)
        let newer = try thread("newer", days: 2, bytes: 8_000_000)
        store.prune(keeping: ["open"], now: now)
        #expect([open, old, recent, older, newer].map { FileManager.default.fileExists(atPath: $0.path) } == [true, false, true, false, true])
    }

    @Test func linkedArchivesAreNeitherReadNorAppendedTo() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let event = Event(time: 1, kind: .request)
        try store.append([event], workspaceID: "original")
        let original = try #require(store.fileURL(workspaceID: "original"))
        let link = try #require(store.fileURL(workspaceID: "link"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(TaskThread.Store.load(from: link).isEmpty)
        #expect(throws: POSIXError.self) { try store.append([event], workspaceID: "link") }
        #expect(TaskThread.Store.load(from: original) == [event])
    }

    @Test func lateHistoryOnlyEnrichesARetainedClosedThread() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let now: TimeInterval = 2_000_000_000
        let close = Event(time: 1, kind: .closed)
        let history = Event(time: 2, kind: .merged)
        let request = Event(time: 1, kind: .request)
        try store.append([close], workspaceID: "removed")
        let removed = try #require(store.fileURL(workspaceID: "removed"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: removed.path)
        store.prune(keeping: [], now: now)
        try store.append([request], workspaceID: "unfinished")
        try store.append([close], workspaceID: "retained")
        try store.append([close], workspaceID: "reopened")
        for id in ["removed", "unfinished", "retained", "reopened"] {
            try store.appendHistory([history], workspaceID: id, keeping: ["reopened"], now: Date().timeIntervalSince1970)
        }
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        let unfinished = try #require(store.fileURL(workspaceID: "unfinished"))
        let retained = try #require(store.fileURL(workspaceID: "retained"))
        let reopened = try #require(store.fileURL(workspaceID: "reopened"))
        #expect(TaskThread.Store.load(from: unfinished) == [request])
        #expect(TaskThread.Store.load(from: retained) == [close, history])
        #expect(TaskThread.Store.load(from: reopened) == [close])
    }

    @Test func lateHistoryEnforcesTheArchiveBudgetAndKeepsOpenTasks() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date().timeIntervalSince1970
        let close = Event(time: now, kind: .closed)
        try store.append([close], workspaceID: "target")
        let target = try #require(store.fileURL(workspaceID: "target"))
        let size = try Data(contentsOf: target).count
        let open = Set(["open"])
        try store.append([Event(time: now, kind: .request)], workspaceID: "open")
        let openURL = try #require(store.fileURL(workspaceID: "open"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: openURL.path)
        let older = folder.appendingPathComponent("older.jsonl")
        try Data(count: TaskThread.Store.maxSpaceBytes - size).write(to: older)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: now - 100)], ofItemAtPath: older.path)
        store.prune(keeping: open, now: now)
        #expect(FileManager.default.fileExists(atPath: older.path))

        let history = Event(time: now, kind: .merged)
        try store.appendHistory([history], workspaceID: "target", keeping: open, now: now)
        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(FileManager.default.fileExists(atPath: openURL.path))
        #expect(TaskThread.Store.load(from: target) == [close, history])
    }
}

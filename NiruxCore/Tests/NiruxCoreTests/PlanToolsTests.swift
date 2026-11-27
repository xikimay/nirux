import Foundation
import NiruxCore
import Testing

struct PlanToolsTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// Ids handed out in order: a, b, c…
    final class IDs {
        var next = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
        func make() -> String { next.removeFirst() }
    }

    @Test func theLeadWritesLinesWithTheirSourceAndStepsForATask() throws {
        var plan = Plan()
        let ids = IDs()
        let task = Plan.Task(workspaceID: "w1", title: "feat/page-breaks")
        #expect(try plan.add(["kind": "todo", "title": "Reply to Léa", "feature": "Export PDF", "source": "Slack",
                              "url": "https://example.slack.com/p1", "why": "a mention at 08:12"], task: nil, newID: ids.make, at: 1)
            == "Added a at the end of feature “Export PDF”.")
        #expect(try plan.add(["kind": "session", "feature": "export pdf"], task: task, newID: ids.make, at: 2)
            == "Added c at the end of feature “Export PDF”.")
        #expect(try plan.add(["kind": "step", "title": "Check the render", "for_user": true], task: task, newID: ids.make, at: 3)
            == "Added d at the end of “feat/page-breaks”.")
        #expect(try plan.add(["kind": "session", "title": "Fonts", "detail": "Embed the two fonts", "after": "a"], task: nil, newID: ids.make, at: 4)
            == "Added e at the end of the plan.")
        #expect(try plan.add(["kind": "lead", "title": "Relaunch #415", "source": "GitHub", "propose": true], task: nil, newID: ids.make, at: 5)
            == "Proposed f for the plan: the user takes or drops it.")
        #expect(plan.line("a")?.origin.source == Plan.Source(name: "Slack", url: "https://example.slack.com/p1", why: "a mention at 08:12"))
        #expect(plan.line("c")?.workspaceID == "w1")
        #expect(plan.line("d")?.isForUser == true)
        _ = try plan.add(["kind": "session", "title": "Fonts again", "detail": "Embed both fonts.\n- Inter\n\t- Mono\u{202E}"], task: nil, newID: ids.make, at: 5)
        #expect(plan.line("g")?.detail == "Embed both fonts.\n- Inter\n- Mono")
        #expect(plan.text(tasks: { _ in nil }).contains("“Embed both fonts. / - Inter / - Mono”"))

        #expect(throws: Plan.Problem("under must be a line's id, as read_plan shows it.")) {
            try plan.add(["kind": "step", "title": "x", "under": 7], task: nil, newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("after must be a line's id, as read_plan shows it.")) {
            try plan.add(["kind": "session", "title": "x", "after": ["a"]], task: nil, newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("feat/page-breaks is in the plan already, as c: only the user moves lines.")) {
            try plan.add(["kind": "session"], task: task, newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("Propose new work only: put a running task's line in the plan without propose.")) {
            try plan.add(["kind": "session", "propose": true], task: Plan.Task(workspaceID: "w9", title: "feat/other"), newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("feat/other has no line in the plan yet: add it first, as a session with task.")) {
            try plan.add(["kind": "step", "title": "x", "propose": true], task: Plan.Task(workspaceID: "w9", title: "feat/other"), newID: ids.make, at: 6)
        }
        #expect(plan.line(ofWorkspace: "w9") == nil)
        #expect(try plan.add(["kind": "step", "title": "Answer the review", "propose": true], task: task, newID: ids.make, at: 6)
            .hasSuffix("for “feat/page-breaks”: the user takes or drops it."))
        #expect(throws: Plan.Problem("task goes with a session or a step.")) {
            try plan.add(["kind": "todo", "title": "x"], task: task, newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("kind must be todo, lead, session or step.")) {
            try plan.add(["kind": "feature", "title": "x"], task: nil, newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("Pass under or feature, not both.")) {
            try plan.add(["kind": "todo", "title": "x", "under": "c", "feature": "F"], task: nil, newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("url must be an http or https link.")) {
            try plan.add(["kind": "todo", "title": "x", "source": "Mail", "url": "file:///etc/passwd"], task: nil, newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("source must name where you read it (GitHub, Linear, Slack, Mail, Figma).")) {
            try plan.add(["kind": "todo", "title": "x", "why": "because"], task: nil, newID: ids.make, at: 6)
        }
        #expect(throws: Plan.Problem("title must hold at most \(Plan.maxTitleLength) characters.")) {
            try plan.add(["kind": "todo", "title": String(repeating: "x", count: Plan.maxTitleLength + 1)], task: nil, newID: ids.make, at: 6)
        }
        let before = plan
        #expect(throws: Plan.Refusal.misplaced(.step, under: .feature)) {
            try plan.add(["kind": "step", "title": "x", "feature": "New"], task: nil, newID: ids.make, at: 6)
        }
        #expect(plan == before)

        #expect(try plan.check(["line": "a"], by: .lead, at: 7) == "Checked “Reply to Léa”.")
        #expect(try plan.check(["line": "a", "done": false], by: .lead, at: 8) == "Unchecked “Reply to Léa”.")
        #expect(throws: Plan.Problem("done must be true or false.")) { try plan.check(["line": "a", "done": "yes"], by: .lead, at: 8) }
    }

    @Test func anAgentReachesOnlyItsOwnStepsAndGetsALineWithItsFirstOne() throws {
        var plan = Plan()
        let ids = IDs()
        let mine = Plan.Task(workspaceID: "w1", title: "feat/page-breaks")
        let other = Plan.Task(workspaceID: "w2", title: "feat/fonts")
        #expect(try plan.steps([:], of: mine, tasks: { _ in nil }, newID: ids.make, at: 1) == "You have no steps yet.")
        #expect(plan.lines.isEmpty)
        _ = try plan.steps(["add": ["Reproduce", "Fix the height"]], of: mine, tasks: { _ in nil }, newID: ids.make, at: 2)
        _ = try plan.steps(["add": ["Choose: embed or link"], "for_user": true], of: other, tasks: { _ in nil }, newID: ids.make, at: 3)
        let line = try #require(plan.line(ofWorkspace: "w1"))
        #expect(line.origin.by == .nirux && line.title == "feat/page-breaks")
        #expect(line.children.map(\.id) == ["b", "c"])
        #expect(throws: Plan.Problem("e isn't one of your steps.")) { try plan.steps(["check": ["e"]], of: mine, tasks: { _ in nil }, newID: ids.make, at: 4) }
        #expect(throws: Plan.Refusal.notAllowed(.check)) { try plan.steps(["check": ["e"]], of: other, tasks: { _ in nil }, newID: ids.make, at: 4) }
        #expect(try plan.steps(["check": ["b"], "add": ["Test 3 long documents"]], of: mine, tasks: { _ in nil }, newID: ids.make, at: 5) == """
            Your steps, in order:
            - [x] Reproduce (step b)
            - [ ] Fix the height (step c, current)
            - [ ] Test 3 long documents (step f)
            """)
        #expect(throws: Plan.Problem("add must list strings, none blank.")) { try plan.steps(["add": [" "]], of: mine, tasks: { _ in nil }, newID: ids.make, at: 6) }
        #expect(throws: Plan.Problem("check must be a string.")) { try plan.steps(["check": [12345]], of: mine, tasks: { _ in nil }, newID: ids.make, at: 6) }
        try plan.add(Plan.Line(id: "sub", kind: .session, title: "Fonts", by: .lead, at: 6, workspaceID: "w3"), to: .under(line.id))
        let listed = try plan.steps([:], of: mine, tasks: { $0 == "w3" ? "feat/fonts, working" : nil }, newID: ids.make, at: 7)
        #expect(listed.hasSuffix("- [ ] Fonts (session sub: feat/fonts, working)"), "a sub-task runs")
    }

    @Test func readPlanShowsEveryLineWithItsIdAndTheProposalsApart() throws {
        var plan = Plan()
        let ids = IDs()
        let task = Plan.Task(workspaceID: "w1", title: "feat/page-breaks")
        _ = try plan.add(["kind": "session", "feature": "Export PDF"], task: task, newID: ids.make, at: 1)
        _ = try plan.steps(["add": ["Reproduce", "Fix the height"]], of: task, tasks: { _ in nil }, newID: ids.make, at: 2)
        _ = try plan.steps(["check": ["c"]], of: task, tasks: { _ in nil }, newID: ids.make, at: 3)
        _ = try plan.add(["kind": "todo", "title": "Reply to the printer", "source": "Mail", "why": "received 07:50"], task: nil, newID: ids.make, at: 4)
        _ = try plan.add(["kind": "session", "title": "Fonts", "detail": "Embed them", "after": "e"], task: nil, newID: ids.make, at: 5)
        _ = try plan.add(["kind": "lead", "title": "Relaunch #415", "feature": "Export PDF", "propose": true], task: nil, newID: ids.make, at: 6)
        #expect(plan.text(tasks: { $0 == "w1" ? "feat/page-breaks, working" : nil }) == """
            - Export PDF (feature b, 0/1 done)
              - [ ] feat/page-breaks (session a: feat/page-breaks, working, 1/2 steps)
                - [x] Reproduce (step c)
                - [ ] Fix the height (step d, current)
            - [ ] Reply to the printer (to-do e, Mail received 07:50)
            - [ ] Fonts (planned session f, starts once e is checked, “Embed them”)
            Proposed, for the user to take or drop:
            - [ ] Relaunch #415 (Lead line g, for feature “Export PDF”)
            """)
        #expect(Plan().text(tasks: { _ in nil }) == "The plan is empty.")

        var long = Plan()
        var count = 0
        for _ in 0..<200 {
            _ = try long.add(["kind": "todo", "title": String(repeating: "x", count: Plan.maxTitleLength)], task: nil, newID: { count += 1; return "t\(count)" }, at: 1)
        }
        let text = long.text(tasks: { _ in nil })
        #expect(text.count < Plan.maxTextLength + 40)
        #expect(text.components(separatedBy: "\n").last?.hasPrefix("… and ") == true && text.hasSuffix(" more lines."))
    }

    @Test func anIDAProposalHoldsForANewFeatureIsNeverHandedOut() throws {
        var plan = Plan()
        var ids = ["a", "b", "b", "c"]
        let make = { ids.removeFirst() }
        _ = try plan.add(["kind": "todo", "title": "Reply", "feature": "Sync", "propose": true], task: nil, newID: make, at: 1)
        #expect(try plan.add(["kind": "todo", "title": "Call"], task: nil, newID: make, at: 2) == "Added c at the end of the plan.")
    }

    @Test func theStoreNeverReplacesAPlanItCantRead() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(Plan.Store.fileName)
        let store = Plan.Store(fileURL: url)
        #expect(store.load().plan == Plan() && store.load().readOnlyReason == nil)
        let added = try store.update { try $0.add(["kind": "todo", "title": "Reply"], task: nil, newID: { "a" }, at: 1) }
        #expect(added == "Added a at the end of the plan.")
        #expect(store.load().plan.line("a")?.title == "Reply")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let written = try Data(contentsOf: url)
        try Data("{not json".utf8).write(to: url)
        #expect(store.load().readOnlyReason == "Nirux can't read plan.json: it leaves it as it is.")
        #expect(throws: Plan.Problem("Nirux can't read plan.json: it leaves it as it is.")) {
            try store.update { try $0.add(["kind": "todo", "title": "x"], task: nil, newID: { "b" }, at: 2) }
        }
        #expect(try Data(contentsOf: url) == Data("{not json".utf8))
        #expect(try store.update { $0.text(tasks: { _ in nil }) } == "The plan is empty.")

        let newer = String(decoding: written, as: UTF8.self).replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#)
        try Data(newer.utf8).write(to: url)
        let loaded = store.load()
        #expect(loaded.plan.line("a") != nil && loaded.readOnlyReason == "A newer Nirux keeps this plan.")
    }

    @Test func aChangeThatWouldPassTheSizeLoadReadsIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(Plan.Store.fileName)
        _ = try Plan.Store(fileURL: url).update { try $0.add(["kind": "todo", "title": "Reply"], task: nil, newID: { "a" }, at: 1) }
        let written = try Data(contentsOf: url)
        // Room for this plan, not for one more line of 120 characters.
        let store = Plan.Store(fileURL: url, maxBytes: written.count + 100)
        #expect(throws: Plan.Problem(Plan.Store.fullReason)) {
            try store.update { try $0.add(["kind": "todo", "title": String(repeating: "x", count: Plan.maxTitleLength)], task: nil, newID: { "b" }, at: 2) }
        }
        #expect(try Data(contentsOf: url) == written)
        let loaded = store.load()
        #expect(loaded.readOnlyReason == nil && loaded.plan.lines.map(\.id) == ["a"])
    }
}

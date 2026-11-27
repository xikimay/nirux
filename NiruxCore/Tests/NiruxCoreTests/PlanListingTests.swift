import Foundation
import NiruxCore
import Testing

struct PlanListingTests {
    @Test func featuresComeFirstWithTheirLinesThenTheOtherTasksInTheirOrderThenLooseLines() throws {
        var plan = Plan()
        var count = 0
        let make = { () -> String in count += 1; return "l\(count)" }
        let pages = Plan.Task(workspaceID: "pages", title: "feat/pages")
        let closed = Plan.Task(workspaceID: "closed", title: "feat/closed")
        _ = try plan.add(["kind": "session", "feature": "Export PDF"], task: pages, newID: make, at: 1)
        _ = try plan.add(["kind": "session", "feature": "Export PDF"], task: closed, newID: make, at: 1)
        _ = try plan.add(["kind": "lead", "title": "Check the renders", "feature": "Export PDF"], task: nil, newID: make, at: 1)
        _ = try plan.add(["kind": "todo", "title": "Reply to the printer"], task: nil, newID: make, at: 1)
        _ = try plan.add(["kind": "lead", "title": "Run the noon train"], task: nil, newID: make, at: 1)
        _ = try plan.add(["kind": "session", "title": "Fonts"], task: nil, newID: make, at: 1)
        _ = try plan.add(["kind": "session", "feature": "Pricing"], task: Plan.Task(workspaceID: "grid", title: "feat/grid"), newID: make, at: 1)
        _ = try plan.add(["kind": "todo", "title": "Choose the offers", "feature": "Pricing"], task: nil, newID: make, at: 1)
        _ = try plan.steps(["add": ["Reproduce"]], of: Plan.Task(workspaceID: "fix", title: "fix/crash"), tasks: { _ in nil }, newID: make, at: 1)

        let features = plan.lines.filter { $0.kind == .feature }
        let export = try #require(features.first)
        let pricing = try #require(features.last)
        let lead = try #require(plan.line("l4"))
        let todo = try #require(plan.line("l5"))
        let fonts = try #require(plan.line("l7"))
        let listing = plan.listing(tasks: ["other", "fix", "grid", "pages"], folded: [pricing.id])
        #expect(listing.entries == [
            .feature(export, isFolded: false),
            .task(workspaceID: "pages", inFeature: true),
            .line(lead, inFeature: true),
            .feature(pricing, isFolded: true),
            .task(workspaceID: "other", inFeature: false),
            .task(workspaceID: "fix", inFeature: false),
            .line(todo, inFeature: false),
            .line(fonts, inFeature: false)
        ])
        #expect(listing.leadLines.map(\.title) == ["Run the noon train"])
    }

    @Test func linesUnderLinesListWithTheirFeatureAndAFoldKeepsTheTasksShown() throws {
        var plan = Plan()
        try plan.add(Plan.Line(id: "f", kind: .feature, title: "Export", by: .user, at: 1), to: .top)
        try plan.add(Plan.Line(id: "t", kind: .todo, title: "Pick the fonts", by: .user, at: 1), to: .under("f"))
        try plan.add(Plan.Line(id: "s", kind: .session, title: "Embed", by: .lead, at: 1, workspaceID: "embed"), to: .under("t"))
        try plan.add(Plan.Line(id: "p", kind: .session, title: "Subset", by: .lead, at: 1), to: .under("t"))
        try plan.add(Plan.Line(id: "o", kind: .todo, title: "Reply", by: .user, at: 1), to: .top)
        try plan.add(Plan.Line(id: "q", kind: .session, title: "Send it", by: .lead, at: 1), to: .under("o"))
        let feature = try #require(plan.line("f"))
        let todo = try #require(plan.line("t"))
        let reply = try #require(plan.line("o"))
        let open = plan.listing(tasks: ["embed", "other"], folded: [])
        #expect(open.entries == [
            .feature(feature, isFolded: false), .line(todo, inFeature: true), .task(workspaceID: "embed", inFeature: true),
            .line(try #require(plan.line("p")), inFeature: true), .task(workspaceID: "other", inFeature: false),
            .line(reply, inFeature: false), .line(try #require(plan.line("q")), inFeature: false)
        ])
        let folded = plan.listing(tasks: ["embed", "other"], folded: ["f"], shown: ["embed"])
        #expect(folded.entries.prefix(2) == [.feature(feature, isFolded: true), .task(workspaceID: "embed", inFeature: true)])
    }
}

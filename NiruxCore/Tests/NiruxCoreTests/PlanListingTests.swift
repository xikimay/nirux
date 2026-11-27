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
}

import Foundation
import NiruxCore
import Testing

struct PlanTests {
    typealias Line = Plan.Line

    func line(
        _ id: String, _ kind: Line.Kind, by author: Plan.Author = .user, at time: TimeInterval = 1, source: Plan.Source? = nil,
        forUser: Bool = false, workspace: String? = nil, after: String? = nil
    ) -> Line {
        Line(id: id, kind: kind, title: id, by: author, at: time, source: source, isForUser: forUser, workspaceID: workspace, after: after)
    }

    func ids(_ lines: [Line]?) -> [String] { lines?.map(\.id) ?? [] }

    /// A feature with a session whose agent checked the first of its two steps, and a to-do outside it.
    func day() throws -> Plan {
        var plan = Plan()
        try plan.add(line("export", .feature), to: .top)
        try plan.add(line("pages", .session, workspace: "w1"), to: .under("export"))
        try plan.add(line("reproduce", .step, by: .agent), to: .under("pages"))
        try plan.add(line("fix", .step, by: .agent), to: .under("pages"))
        try plan.check("reproduce", by: .agent, at: 2)
        try plan.add(line("printer", .todo), to: .top)
        return plan
    }

    @Test func additionsGoAtTheEndOfTheirPlaceSoNeverAboveTheCurrentStep() throws {
        var plan = try day()
        try plan.add(line("images", .step, by: .agent, at: 3), to: .under("pages"))
        try plan.add(line("validate", .step, by: .lead, at: 4, forUser: true), to: .under("pages"))
        let pages = try #require(plan.line("pages"))
        #expect(ids(pages.children) == ["reproduce", "fix", "images", "validate"])
        #expect(pages.current?.id == "fix")
        #expect(pages.progress.done == 1 && pages.progress.total == 4)
        #expect(!pages.waitsForUser)
        try plan.check("fix", by: .agent, at: 5)
        try plan.check("images", by: .agent, at: 6)
        #expect(plan.line("pages")?.waitsForUser == true)

        try plan.add(line("render", .lead, by: .lead, at: 7), to: .feature(title: " EXPORT ", id: "unused"))
        try plan.add(line("offers", .todo, by: .lead, at: 8), to: .feature(title: "Pricing", id: "pricing"))
        #expect(ids(plan.lines) == ["export", "printer", "pricing"])
        #expect(ids(plan.line("export")?.children) == ["pages", "render"])
        #expect(plan.line("unused") == nil)
        let pricing = try #require(plan.line("pricing"))
        #expect(pricing.origin.by == .lead && pricing.origin.at == 8 && pricing.isUnseen)
        #expect(ids(pricing.children) == ["offers"])
    }

    @Test func onlyTheUserMovesOrRemovesALine() throws {
        var plan = try day()
        for author in [Plan.Author.lead, .agent, .nirux] {
            #expect(throws: Plan.Refusal.notAllowed(.move)) {
                try plan.move("printer", to: .under("export"), index: 0, by: author, at: 3)
            }
            #expect(throws: Plan.Refusal.notAllowed(.remove)) { try plan.remove("printer", by: author) }
        }
        try plan.move("printer", to: .under("export"), index: 0, by: .user, at: 3)
        #expect(ids(plan.lines) == ["export"])
        #expect(ids(plan.line("export")?.children) == ["printer", "pages"])
        try plan.move("printer", to: .under("export"), index: 9, by: .user, at: 3)
        #expect(ids(plan.line("export")?.children) == ["pages", "printer"])

        let before = plan
        #expect(throws: Plan.Refusal.noLine("pages")) {
            try plan.move("export", to: .under("pages"), index: 0, by: .user, at: 4)
        }
        #expect(throws: Plan.Refusal.misplaced(.step, under: nil)) {
            try plan.move("fix", to: .top, index: 0, by: .user, at: 4)
        }
        #expect(plan == before)

        try plan.move("printer", to: .feature(title: "Mail", id: "mail"), index: 0, by: .user, at: 5)
        let mail = try #require(plan.line("mail"))
        #expect(mail.origin.by == .user && mail.origin.at == 5 && !mail.isUnseen)
        try plan.remove("export", by: .user)
        #expect(ids(plan.lines) == ["mail"])
        #expect(plan.line("fix") == nil)
    }

    @Test func eachAuthorChecksOnlyItsOwnKindOfLine() throws {
        var plan = try day()
        try plan.add(line("choose", .step, by: .agent, forUser: true), to: .under("pages"))
        #expect(throws: Plan.Refusal.notAllowed(.check)) { try plan.check("choose", by: .agent, at: 3) }
        #expect(throws: Plan.Refusal.notAllowed(.check)) { try plan.check("printer", by: .agent, at: 3) }
        #expect(throws: Plan.Refusal.isFeature("export")) { try plan.check("export", by: .user, at: 3) }
        try plan.check("choose", by: .lead, at: 4)
        try plan.check("printer", by: .user, at: 5)
        try plan.check("printer", by: .user, at: 9)
        #expect(plan.line("choose")?.checkedAt == 4)
        #expect(plan.line("printer")?.checkedAt == 5)
        try plan.check("printer", false, by: .user, at: 10)
        #expect(plan.line("printer")?.checkedAt == nil)
    }

    @Test func agentsAddOnlyStepsUnderASessionAndTheirLinesStayNewUntilSeen() throws {
        var plan = try day()
        #expect(throws: Plan.Refusal.notAllowed(.add)) { try plan.add(line("call", .todo, by: .agent), to: .top) }
        #expect(throws: Plan.Refusal.notAllowed(.add)) { try plan.add(line("call", .step, by: .agent), to: .under("printer")) }
        #expect(throws: Plan.Refusal.notAllowed(.add)) {
            try plan.add(line("call", .lead, by: .agent), to: .feature(title: "Calls", id: "calls"))
        }
        #expect(plan.line("calls") == nil)

        #expect(plan.line("fix")?.isUnseen == true)
        #expect(plan.line("printer")?.isUnseen == false)
        try plan.add(line("render", .lead, by: .lead), to: .under("export"))
        try plan.add(line("compare", .step, by: .lead), to: .under("render"))
        plan.markSeen("export")
        #expect(plan.line("render")?.isUnseen == false)
        #expect(plan.line("fix")?.isUnseen == true)
        plan.markSeen("compare")
        #expect(plan.line("compare")?.isUnseen == false)
        plan.markSeen("pages")
        #expect(plan.line("fix")?.isUnseen == false)
    }

    @Test func linesGoOnlyWhereTheirKindFits() throws {
        var plan = try day()
        #expect(throws: Plan.Refusal.misplaced(.step, under: nil)) { try plan.add(line("s", .step), to: .top) }
        #expect(throws: Plan.Refusal.misplaced(.feature, under: .feature)) { try plan.add(line("f", .feature), to: .under("export")) }
        #expect(throws: Plan.Refusal.misplaced(.todo, under: .session)) { try plan.add(line("t", .todo), to: .under("pages")) }
        #expect(throws: Plan.Refusal.misplaced(.step, under: .step)) { try plan.add(line("s", .step), to: .under("fix")) }
        #expect(throws: Plan.Refusal.misplaced(.step, under: .feature)) {
            try plan.add(line("s", .step), to: .feature(title: "New", id: "new"))
        }
        #expect(throws: Plan.Refusal.noTitle) { try plan.add(line("t", .todo), to: .feature(title: " ", id: "blank")) }
        #expect(throws: Plan.Refusal.takenID("fix")) { try plan.add(line("t", .todo), to: .feature(title: "New", id: "fix")) }
        #expect(throws: Plan.Refusal.noLine("nowhere")) { try plan.add(line("t", .todo), to: .under("nowhere")) }
        #expect(throws: Plan.Refusal.noTitle) {
            try plan.add(Line(id: "blank", kind: .todo, title: " \n", by: .user, at: 1), to: .top)
        }
        #expect(throws: Plan.Refusal.takenID("fix")) { try plan.add(line("fix", .todo), to: .top) }
        #expect(throws: Plan.Refusal.linked("w1")) { try plan.add(line("again", .session, workspace: "w1"), to: .top) }
        #expect(throws: Plan.Refusal.fieldsDontFitKind) { try plan.add(line("t", .todo, workspace: "w9"), to: .top) }
        #expect(throws: Plan.Refusal.fieldsDontFitKind) { try plan.add(line("t", .todo, forUser: true), to: .top) }
        #expect(throws: Plan.Refusal.takenID("t")) { try plan.add(line("t", .todo), to: .feature(title: "New", id: "t")) }
        try plan.add(line("sub", .session), to: .under("pages"))
        try plan.add(line("call", .session), to: .under("printer"))
        #expect(ids(plan.line("pages")?.children) == ["reproduce", "fix", "sub"])
    }

    @Test func aLinkedLineBecomesItsSessionInPlace() throws {
        var plan = try day()
        try plan.add(line("call", .step, forUser: true), to: .under("printer"))
        try plan.add(line("texts", .session, after: "printer"), to: .under("export"))
        #expect(plan.line("texts")?.isPlanned == true)
        #expect(throws: Plan.Refusal.notAllowed(.link)) { try plan.link("fix", toWorkspace: "w2", by: .agent) }
        #expect(throws: Plan.Refusal.linked("w1")) { try plan.link("printer", toWorkspace: "w1", by: .user) }
        #expect(throws: Plan.Refusal.linked("w1")) { try plan.link("pages", toWorkspace: "w9", by: .user) }
        #expect(throws: Plan.Refusal.isFeature("export")) { try plan.link("export", toWorkspace: "w9", by: .user) }

        try plan.check("printer", by: .user, at: 2)
        try plan.link("printer", toWorkspace: "w2", by: .user)
        #expect(ids(plan.lines) == ["export", "printer"])
        let printer = try #require(plan.line(ofWorkspace: "w2"))
        #expect(printer.id == "printer" && printer.kind == .session && !printer.isChecked)
        #expect(ids(printer.children) == ["call"])
        try plan.link("call", toWorkspace: "w3", by: .lead)
        let call = try #require(plan.line("call"))
        #expect(call.kind == .session && !call.isForUser)
        try plan.link("texts", toWorkspace: "w4", by: .nirux)
        let texts = try #require(plan.line("texts"))
        #expect(!texts.isPlanned && texts.after == nil)
    }

    @Test func aCheckedLineReleasesThePlannedSessionsAfterIt() throws {
        var plan = try day()
        #expect(throws: Plan.Refusal.noLine("nothing")) { try plan.add(line("x", .session, after: "nothing"), to: .top) }
        #expect(throws: Plan.Refusal.isFeature("export")) { try plan.add(line("x", .session, after: "export"), to: .top) }
        #expect(throws: Plan.Refusal.fieldsDontFitKind) { try plan.add(line("x", .todo, after: "printer"), to: .top) }
        #expect(throws: Plan.Refusal.fieldsDontFitKind) {
            try plan.add(line("x", .session, workspace: "w9", after: "printer"), to: .top)
        }
        try plan.add(line("texts", .session, after: "printer"), to: .under("export"))
        try plan.add(line("grid", .session, after: "printer"), to: .under("export"))
        #expect(plan.released.isEmpty)
        try plan.check("printer", by: .user, at: 3)
        #expect(ids(plan.released) == ["texts", "grid"])
        try plan.link("texts", toWorkspace: "w2", by: .nirux)
        try plan.check("grid", by: .user, at: 4)
        #expect(plan.released.isEmpty)

        try plan.add(line("offers", .todo), to: .top)
        try plan.add(line("page", .session, after: "offers"), to: .top)
        try plan.remove("offers", by: .user)
        #expect(plan.line("page")?.after == nil)
    }

    @Test func aKindALaterBuildAddsIsKeptButFitsNowhere() throws {
        var plan = try JSONDecoder().decode(Plan.self, from: Data(#"""
        {"proposals": [], "lines": [{"id": "n", "kind": "note", "title": "n", "isForUser": false, "isUnseen": false,
          "origin": {"by": "user", "at": 1}, "children": []}]}
        """#.utf8))
        #expect(plan.line("n")?.kind == Line.Kind(rawValue: "note"))
        #expect(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(plan)) == plan)
        #expect(throws: Plan.Refusal.misplaced(Line.Kind(rawValue: "note"), under: nil)) {
            try plan.add(line("m", Line.Kind(rawValue: "note")), to: .top)
        }
    }

    @Test func aProposalKeepsItsSourceAndJoinsThePlanOnlyWhenTaken() throws {
        var plan = try day()
        let slack = Plan.Source(name: "Slack", url: "https://example.slack.com/archives/C1/p1", why: "a mention at 08:12")
        let linear = Plan.Source(name: "Linear", url: "https://linear.app/team/issue/CAR-139")
        #expect(throws: Plan.Refusal.notAllowed(.propose)) { try plan.propose(line("p", .todo, by: .agent), to: .top) }
        #expect(throws: Plan.Refusal.noLine("gone")) { try plan.propose(line("p", .step, by: .lead), to: .under("gone")) }
        #expect(throws: Plan.Refusal.misplaced(.step, under: nil)) { try plan.propose(line("p", .step, by: .lead), to: .top) }

        try plan.propose(line("reply", .todo, by: .lead, at: 3, source: slack), to: .feature(title: "Sync", id: "sync"))
        try plan.propose(line("conflicts", .session, by: .lead, at: 3, source: linear), to: .feature(title: "sync", id: "sync2"))
        try plan.propose(line("comments", .step, by: .lead, at: 3), to: .under("pages"))
        try plan.propose(line("quote", .step, by: .lead, at: 3), to: .under("printer"))
        try plan.propose(line("letter", .session, by: .lead, at: 3, after: "printer"), to: .top)
        try plan.propose(line("running", .session, by: .lead, at: 3, workspace: "w5"), to: .top)
        #expect(throws: Plan.Refusal.linked("w5")) { try plan.propose(line("again", .session, by: .lead, workspace: "w5"), to: .top) }
        #expect(throws: Plan.Refusal.takenID("reply")) { try plan.propose(line("reply", .todo, by: .lead), to: .top) }
        #expect(plan.line("sync") == nil)
        #expect(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(plan)) == plan)

        #expect(throws: Plan.Refusal.notAllowed(.take)) { try plan.take("reply", by: .agent) }
        try plan.take("reply", by: .user)
        try plan.take("conflicts", by: .lead)
        #expect(throws: Plan.Refusal.notAllowed(.take)) { try plan.drop("comments", by: .agent) }
        try plan.drop("comments", by: .user)
        #expect(ids(plan.line("sync")?.children) == ["reply", "conflicts"])
        let reply = try #require(plan.line("reply"))
        #expect(reply.origin.by == .lead && reply.origin.at == 3 && reply.origin.source == slack && reply.isUnseen)
        #expect(plan.line("comments") == nil)
        #expect(throws: Plan.Refusal.noProposal("comments")) { try plan.take("comments", by: .user) }

        try plan.remove("printer", by: .user)
        #expect(plan.proposals.map(\.id) == ["letter", "running"])
        #expect(plan.proposals.first?.line.after == nil)
    }
}

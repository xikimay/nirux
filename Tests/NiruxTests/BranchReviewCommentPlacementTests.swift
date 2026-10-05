import XCTest
@testable import Nirux

/// Where a comment is in a file's diff (docs/branch-review.md, section
/// 6.1), and how it follows its lines when the branch moves: rather
/// outdated than under another line.
final class BranchReviewCommentPlacementTests: XCTestCase, CommentFixtures {
    private typealias Record = BranchReview.Record

    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Rows

    func testRowsAreNumberedAsThePageShowsThem() {
        let rows = BranchReview.diffRows(of: [
            hunk(old: 10, new: 12, [" keep", "-old", "\\ No newline at end of file", "+new", " tail"]),
            hunk(old: 40, new: 42, ["+only"])
        ])
        XCTAssertEqual(rows, [
            [row(.context, 10, 12, "keep"), row(.removed, 11, 13, "old"), row(.added, 12, 13, "new"), row(.context, 12, 14, "tail")],
            [row(.added, 40, 42, "only")]
        ])
        XCTAssertEqual(rows[0].map(\.position), [at(.additions, 12), at(.deletions, 11), at(.additions, 13), at(.additions, 14)])
    }

    func testAnchorCoversTheRowsOfOneHunkFromEitherEnd() throws {
        let hunks = [hunk(old: 1, new: 1, [" a", " b", "-c", "+C", " d", " e", " f"]), hunk(old: 30, new: 30, [" x", "+y"])]
        let range = try anchor(hunks, at(.additions, 3), at(.deletions, 3))
        XCTAssertEqual(range.rows, [row(.removed, 3, 3, "c"), row(.added, 4, 3, "C")])
        XCTAssertEqual(range.before, ["a", "b"])
        XCTAssertEqual(range.after, ["d", "e"])
        XCTAssertNil(range.copy)
        XCTAssertEqual(try anchor(hunks, at(.deletions, 3), at(.additions, 3)), range)

        // Against the hunk's edges, the context is what there is.
        let first = try anchor(hunks, at(.additions, 30))
        XCTAssertEqual(first.before, [])
        XCTAssertEqual(first.after, ["y"])

        XCTAssertNil(Anchor(file: file(hunks), from: at(.additions, 2), to: at(.additions, 31)), "two hunks")
        XCTAssertNil(Anchor(file: file(hunks), from: at(.deletions, 2), to: at(.deletions, 2)), "a context row is on additions")
        XCTAssertNil(Anchor(file: file(hunks), from: at(.additions, 9), to: at(.additions, 9)), "not in the diff")

        let long = [hunk(old: 1, new: 1, (1...(Anchor.maxRows + 1)).map { "+\($0)" })]
        XCTAssertNotNil(Anchor(file: file(long), from: at(.additions, 1), to: at(.additions, Anchor.maxRows)))
        XCTAssertNil(Anchor(file: file(long), from: at(.additions, 1), to: at(.additions, Anchor.maxRows + 1)))
        let heavy = [hunk(old: 1, new: 1, (1...40).map { "+\($0)" + String(repeating: "x", count: 999) })]
        XCTAssertNil(Anchor(file: file(heavy), from: at(.additions, 1), to: at(.additions, 40)), "past maxBytes")
    }

    func testLongRowIsCutButAChangePastTheCutTells() throws {
        let prefix = String(repeating: "x", count: Anchor.maxRowCharacters)
        let lines = [" let a = 1", "+" + prefix + "tail", " let b = 2"]
        let made = try anchor([hunk(old: 1, new: 1, lines)], at(.additions, 2))
        XCTAssertEqual(made.rows.first?.text, prefix)
        XCTAssertNotNil(made.rows.first?.digest)
        XCTAssertNil(try anchor([hunk(old: 1, new: 1, [" let a = 1", "+short", " let b = 2"])], at(.additions, 2)).rows.first?.digest)

        XCTAssertEqual(placed(made, [hunk(old: 1, new: 5, lines)]), [6])
        XCTAssertNil(placed(made, [hunk(old: 1, new: 5, [" let a = 1", "+" + prefix + "other", " let b = 2"])]))

        // One character can weigh thousands of bytes.
        XCTAssertEqual(Anchor.cut("e" + String(repeating: "\u{301}", count: 10_000)), "")
        let family = Anchor.cut(String(repeating: "👨‍👩‍👧", count: 1_000))
        XCTAssertLessThanOrEqual(family.utf8.count, Anchor.maxRowBytes)
        XCTAssertGreaterThan(family.utf8.count, Anchor.maxRowBytes - 18)
    }

    // MARK: - Following the lines

    func testCommentStaysWhereItsRowsStillAre() throws {
        let lines = [" let a = 1", " let b = 2", "+guard x else { return }", " let c = 3"]
        let made = try anchor([hunk(old: 10, new: 10, lines)], at(.additions, 12))
        XCTAssertEqual(BranchReview.place(made, in: file([hunk(old: 10, new: 10, lines)])), .placed(made))
        // The hunk now starts and ends at the row: nothing around to say
        // otherwise, and no other such row.
        XCTAssertEqual(placed(made, [hunk(old: 12, new: 12, ["+guard x else { return }"])]), [12])
        // Its neighbors were all rewritten: rather outdated.
        XCTAssertNil(placed(made, [hunk(old: 10, new: 10, [" let x = 1", " let y = 2", "+guard x else { return }", " let z = 3"])]))
    }

    func testCommentFollowsItsRowsWhenLinesMoveAboveThem() throws {
        let lines = [" let a = 1", " let b = 2", "+guard x else { return }", " let c = 3", " let d = 4"]
        let made = try anchor([hunk(old: 10, new: 10, lines)], at(.additions, 12))
        // A merge from the base added 7 lines above: the patch hash, which
        // leaves line numbers out, is the same; the numbers aren't.
        XCTAssertEqual(placed(made, [hunk(old: 17, new: 17, lines)]), [19])
        // The agent added a line right above it, and changed the one below.
        let inserted = [" let a = 1", " let b = 2", "+precondition(x)", "+guard x else { return }", "+let c = 4"]
        XCTAssertEqual(placed(made, [hunk(old: 10, new: 10, inserted)]), [13])
        // Alone in a hunk of its own, with nothing around to say it is the
        // same: only where it was.
        XCTAssertNil(placed(made, [hunk(old: 12, new: 15, ["+guard x else { return }"])]))
    }

    func testChangedRowMakesItsCommentOutdated() throws {
        let made = try anchor([hunk(old: 1, new: 1, [" let a = 1", "+guard x else { return }", " let b = 2"])], at(.additions, 2))
        // The agent answered the comment: the line changed.
        let fixed = [hunk(old: 1, new: 1, [" let a = 1", "+guard x else { update(); return }", " let b = 2"])]
        XCTAssertEqual(BranchReview.place(made, in: file(fixed)), .outdated)
        XCTAssertEqual(BranchReview.place(made, in: nil), .fileGone)
        XCTAssertEqual(BranchReview.place(made, in: file([], omission: .onDemand)), .unread)
        XCTAssertEqual(BranchReview.place(made, in: file([], omission: .notRead)), .unread)
        XCTAssertEqual(BranchReview.place(made, in: file([], omission: .tooLarge)), .tooLarge)
        XCTAssertEqual(BranchReview.place(made, in: file([])), .outdated, "binary, or a mode change: no row")
    }

    func testRangeAcrossBothSidesFollowsAsAWhole() throws {
        let lines = [" let a = 1", "-old()", "+new()", "+more()", " let b = 2"]
        let made = try anchor([hunk(old: 4, new: 4, lines)], at(.deletions, 5), at(.additions, 6))
        XCTAssertEqual(made.rows.map(\.kind), [.removed, .added, .added])
        XCTAssertEqual(placed(made, [hunk(old: 4, new: 9, lines)]), [5, 10, 11])
        // One row of the range changed.
        XCTAssertNil(placed(made, [hunk(old: 4, new: 4, [" let a = 1", "-old()", "+new()", "+most()", " let b = 2"])]))
    }

    func testContextTellsWhichOfTwoSameRowsItWas() throws {
        let first = [" func a() {", "+    return nil", " }"]
        let second = [" func b() {", "+    return nil", " }"]
        let made = try anchor([hunk(old: 1, new: 1, first), hunk(old: 20, new: 20, second)], at(.additions, 21))

        // Lines were added between them: b's now sits farther from where
        // the comment was than a's does.
        XCTAssertEqual(placed(made, [hunk(old: 1, new: 21, first), hunk(old: 20, new: 60, second)]), [61])
        // b's changed: a's shares only a brace with it, which says nothing.
        XCTAssertNil(placed(made, [hunk(old: 1, new: 21, first), hunk(old: 20, new: 60, [" func b() {", "+    throw E.b", " }"])]))
    }

    /// A row among braces and blank lines: nothing around it tells it from
    /// another, so it stays only where it was.
    func testRowWithoutDistinctiveContextStaysOnlyWhereItWas() throws {
        let lines = [" final class A {", "+    func f() {", "+        work()", "+    }", "+", "+}"]
        let made = try anchor([hunk(old: 10, new: 10, lines)], at(.additions, 13))
        XCTAssertEqual(made.after, ["", "}"])
        XCTAssertEqual(placed(made, [hunk(old: 10, new: 10, lines)]), [13])
        // `f()` went; another class's brace, far below, has the same
        // neighbors as far as braces go.
        XCTAssertNil(placed(made, [
            hunk(old: 10, new: 10, [" final class A {", "+}"]),
            hunk(old: 600, new: 595, [" final class B {", "+    func g() {", "+        other()", "+    }", "+", "+}"])
        ]))

        // With nothing around it but braces and blanks: where it was, as
        // long as no other such row is in the diff.
        let bare = try anchor([hunk(old: 20, new: 20, ["+    }", "+", "+}"])], at(.additions, 22))
        XCTAssertEqual(placed(bare, [hunk(old: 20, new: 20, ["+    }", "+", "+}"])]), [22])
        XCTAssertNil(placed(bare, [hunk(old: 20, new: 20, ["+    }", "+", "+}"]), hunk(old: 80, new: 80, [" let x = 1", "+}"])]))

        // Its only context, below, holds a letter, but the hunk now ends at
        // it: in place, it isn't told from another brace.
        let lone = try anchor([hunk(old: 1, new: 1, ["+}", " work()"])], at(.additions, 1))
        XCTAssertNil(placed(lone, [hunk(old: 1, new: 1, ["+}"]), hunk(old: 50, new: 50, ["+}"])]))
    }

    /// An added row never lands on an unchanged line of the same text.
    func testAddedRowNeverLandsOnAContextRow() throws {
        let made = try anchor([hunk(old: 10, new: 10, [" func load() {", "+        return nil", "     }"])], at(.additions, 11))
        XCTAssertNil(placed(made, [
            hunk(old: 10, new: 10, [" func load() {", "+        throw LoadError.noURL", "     }"]),
            hunk(old: 300, new: 300, [" func load() {", "         return nil", "+    }"])
        ]))
    }

    /// The usual answer to a comment rewrites or deletes its line: another
    /// row with the same text isn't it without evidence, nor with evidence
    /// that the rest around it contradicts.
    func testChangedRowIsntTakenForAnother() throws {
        let guards = ["+guard let a else {", "+    return nil", "+}", "+guard let b else {", "+    return nil", "+}"]
        let made = try anchor([hunk(old: 10, new: 10, guards)], at(.additions, 11))
        // a's guard rewritten: b's `return nil` is 3 rows away.
        XCTAssertNil(placed(made, [hunk(old: 10, new: 10, [
            "+guard let a else { throw LoadError.missingA }", "+guard let b else {", "+    return nil", "+}"
        ])]))
        // a's guard deleted: b's slides to where a's was.
        XCTAssertNil(placed(made, [hunk(old: 10, new: 10, ["+guard let b else {", "+    return nil", "+}"])]))
        // The only one left, far below, with other neighbors.
        XCTAssertNil(placed(made, [
            hunk(old: 10, new: 10, ["+let a = try load()"]), hunk(old: 400, new: 400, [" func parse() {", "+    return nil", " }"])
        ]))

        // Two tests that share their first line: one shared neighbor isn't
        // enough when the others differ.
        let tests = [
            "+func testA() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertTrue(store.isEmpty)", "+}",
            "+func testB() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertFalse(store.isFull)", "+}"
        ]
        let onA = try anchor([hunk(old: 1, new: 1, tests)], at(.additions, 3))
        var answered = tests
        answered[2] = "+    store.reset(keepingCache: false)"
        XCTAssertNil(placed(onA, [hunk(old: 1, new: 1, answered)]))
    }

    /// Copied code: the rows and their context read the same. Only its
    /// rank among the copies tells it from them.
    func testCopiedCodeIsFoundByItsRank() throws {
        let block = [" func testReset() {", "+    store.reset()", " }"]
        let made = try anchor([hunk(old: 10, new: 10, block), hunk(old: 50, new: 50, block)], at(.additions, 51))
        XCTAssertEqual(made.copy, BranchReview.CopyRank(index: 1, count: 2))
        XCTAssertEqual(placed(made, [hunk(old: 10, new: 10, block), hunk(old: 50, new: 50, block)]), [51], "not outdated when made")
        // 40 lines inserted between them.
        XCTAssertEqual(placed(made, [hunk(old: 10, new: 10, block), hunk(old: 50, new: 90, block)]), [91])
        // A merge from the base moved both: nothing tells them apart.
        XCTAssertNil(placed(made, [hunk(old: 15, new: 15, block), hunk(old: 55, new: 55, block)]))
        // Its own row answered: not under its copy.
        let answered = [" func testReset() {", "+    store.reset(all: true)", " }"]
        XCTAssertNil(placed(made, [hunk(old: 10, new: 10, block), hunk(old: 50, new: 50, answered)]))

        // Copies in a new file: every added row has the same base line.
        let tests = ["+func t() {", "+    reset()", "+}", "+func t() {", "+    reset()", "+}"]
        let second = try anchor([hunk(old: 0, new: 1, tests)], at(.additions, 5))
        XCTAssertEqual(second.copy, BranchReview.CopyRank(index: 1, count: 2))
        XCTAssertEqual(placed(second, [hunk(old: 0, new: 1, ["+import X"] + tests)]), [6])
        var changed = tests
        changed[4] = "+    reset(all: true)"
        XCTAssertNil(placed(second, [hunk(old: 0, new: 1, changed)]))

        // A copy at a hunk's start, with less context than the other.
        let other = hunk(old: 20, new: 20, [" func t() {", "+    reset()", " }"])
        let head = try anchor([hunk(old: 1, new: 1, ["+    reset()", " }"]), other], at(.additions, 1))
        XCTAssertNotNil(head.copy)
        XCTAssertNil(placed(head, [hunk(old: 1, new: 1, ["+    reset(all: true)", " }"]), other]))

        // A line above it changed: still where it was, whatever its copy.
        let guarded = [" let value = read()", " guard let value else {", "+    return nil", " }"]
        let inPlace = try anchor([hunk(old: 10, new: 10, guarded), hunk(old: 100, new: 100, guarded)], at(.additions, 12))
        XCTAssertEqual(placed(inPlace, [
            hunk(old: 10, new: 10, [
                " let value = read()", "-guard let value else {", "+guard let value, !value.isEmpty else {", "+    return nil", " }"
            ]),
            hunk(old: 100, new: 101, guarded)
        ]), [12])
    }

    /// Near copies: rows that read the same, with context that differs a
    /// little. Rewritten where it was, the comment doesn't go to the other.
    func testRewrittenRowIsntTakenForANearCopy() throws {
        let tests = [
            "+func testA() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertTrue(store.isEmpty)", "+}",
            "+func testB() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertTrue(store.isEmpty)", "+}"
        ]
        let onA = try anchor([hunk(old: 1, new: 1, tests)], at(.additions, 3))
        XCTAssertNil(onA.copy)
        var answered = tests
        answered[2] = "+    store.reset(keepingCache: false)"
        XCTAssertNil(placed(onA, [hunk(old: 1, new: 1, answered)]))
        answered.remove(at: 2)
        XCTAssertNil(placed(onA, [hunk(old: 1, new: 1, answered)]), "deleted")
    }

    /// Runs as likely as each other: the one where the rows were, when
    /// something around it changed; otherwise nothing tells which.
    func testRunsAsLikelyAsEachOther() throws {
        let first = [" p()", " q()", "+    return nil", " r()"]
        let second = [" p()", " q9()", "+    return nil", " r()"]
        let alone = try anchor([hunk(old: 10, new: 10, first)], at(.additions, 12))
        XCTAssertNil(alone.rival)
        let edited = [" p()", " q3()", "+    return nil", " r()"]
        XCTAssertEqual(placed(alone, [hunk(old: 10, new: 10, edited), hunk(old: 50, new: 50, second)]), [12])
        XCTAssertNil(placed(alone, [hunk(old: 10, new: 13, edited), hunk(old: 50, new: 53, second)]))

        // A near copy was there when the comment was made: as good as it
        // was then isn't enough.
        let nearCopy = try anchor([hunk(old: 10, new: 10, first), hunk(old: 50, new: 50, second)], at(.additions, 12))
        XCTAssertEqual(nearCopy.rival, 1)
        XCTAssertNil(placed(nearCopy, [hunk(old: 10, new: 10, edited), hunk(old: 50, new: 50, second)]))
        // Where it moves, it keeps that bar.
        guard case .placed(let moved) = BranchReview.place(nearCopy, in: file([hunk(old: 10, new: 15, first), hunk(old: 50, new: 55, second)]))
        else { return XCTFail("not placed") }
        XCTAssertEqual(moved.rows.map(\.line), [17])
        XCTAssertEqual(moved.rival, 1)

        // Still where it was, with something against it, and a better run
        // elsewhere with something against it too.
        let near = [" p()", " q()", "+    return nil", " s()"]
        let onNear = try anchor([hunk(old: 10, new: 10, first), hunk(old: 50, new: 50, near)], at(.additions, 12))
        XCTAssertNil(placed(onNear, [hunk(old: 10, new: 10, [" p()", " q2()", "+    return nil", " r2()"]), hunk(old: 50, new: 50, near)]))
    }

    /// A function copied next to the one commented, after the comment was
    /// made: the two read the same, and neither changed. Rather outdated
    /// than under the copy.
    func testCodeCopiedSinceLeavesTheCommentOutdated() throws {
        let foo = ["+func foo() {", "+    let a = load()", "+    let b = parse(a)", "+    store(b)", "+    log(b)", "+    return b", "+}"]
        let header = ["+import X", "+"]
        let made = try anchor([hunk(old: 0, new: 1, header + foo)], at(.additions, 6))
        XCTAssertNil(made.copy)
        var legacy = foo
        legacy[0] = "+func fooLegacy() {"
        XCTAssertNil(placed(made, [hunk(old: 0, new: 1, header + legacy + ["+"] + foo)]), "pasted above")
        XCTAssertNil(placed(made, [hunk(old: 0, new: 1, header + foo + ["+"] + legacy)]), "pasted below")
    }

    /// Near copies: the comment's code deleted or rewritten doesn't send it
    /// to the other, which had some of its context when it was made.
    func testNearCopyDoesntTakeACommentWhoseCodeWent() throws {
        let funcA = ["+func a() -> Int? {", "+    let config = load()", "+    guard let value = config.value else {", "+        return nil",
                     "+    }", "+    return use(value)", "+}", "+"]
        let funcB = ["+func b() -> Int? {", "+    let config = load()", "+    guard let value = config.value else {", "+        return nil",
                     "+    }", "+    return other(value)", "+}"]
        let made = try anchor([hunk(old: 0, new: 1, funcA + funcB)], at(.additions, 4))
        XCTAssertNil(made.copy)
        XCTAssertNotNil(made.rival)
        XCTAssertNil(placed(made, [hunk(old: 0, new: 1, funcB)]), "a deleted")
        var thrown = funcA
        thrown[3] = "+        throw ConfigError.missing"
        XCTAssertNil(placed(made, [hunk(old: 0, new: 1, thrown + funcB)]), "a's line rewritten")
        var collapsed = funcA
        collapsed.remove(at: 3)
        collapsed[2] = "+    guard let value = config.value else { throw ConfigError.missing"
        XCTAssertNil(placed(made, [hunk(old: 0, new: 1, collapsed + funcB)]), "a's guard collapsed")

        let tests = [
            "+func testA() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertTrue(store.isEmpty)", "+}",
            "+func testB() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertTrue(store.isFull)", "+}"
        ]
        let onA = try anchor([hunk(old: 1, new: 1, tests)], at(.additions, 3))
        var setUp = tests
        setUp[1] = "+    let store = Store(cache: .none)"
        setUp[2] = "+    store.reset(keepingCache: false)"
        XCTAssertNil(placed(onA, [hunk(old: 1, new: 1, setUp)]), "its setup and line rewritten")
        XCTAssertNil(placed(onA, [hunk(old: 1, new: 1, Array(tests[5...]))]), "testA deleted")
    }

    /// Rewritten where it was: its frame still stands there, around other
    /// rows, and that says more than a run elsewhere sharing some of it.
    func testFrameAroundTheRewrittenRowOutweighsARunElsewhere() throws {
        let made = try anchor([hunk(old: 10, new: 10, [" p()", " q()", "+    return nil", " r()"])], at(.additions, 12))
        XCTAssertNil(made.rival)
        XCTAssertNil(placed(made, [
            hunk(old: 10, new: 10, [" p()", " q()", "+    throw E.missing", " r()"]),
            hunk(old: 50, new: 50, [" p()", " q2()", "+    return nil", " r()"])
        ]))
        // Its frame elsewhere, around other code: a bare row where it was
        // isn't taken for it either.
        let framed = try anchor([hunk(old: 10, new: 10, [" b()", "+row()", " a()"])], at(.additions, 11))
        XCTAssertEqual(placed(framed, [hunk(old: 11, new: 11, ["+row()"])]), [11])
        XCTAssertNil(placed(framed, [hunk(old: 11, new: 11, ["+row()"]), hunk(old: 40, new: 40, [" b()", "+other()", " a()"])]))
    }

    /// Rewritten with a neighbor, the old code kept as a copy below: the
    /// frame where the rows were says they were rewritten there.
    func testRowRewrittenWhereItWasStaysOffTheOldCodeKeptElsewhere() throws {
        let save = ["+func save() {", "+    let a = read()", "+    let b = parse(a)", "+    guard b.isValid else { return }", "+    store(b)",
                    "+    log(b)", "+}"]
        let made = try anchor([hunk(old: 0, new: 1, save)], at(.additions, 4))
        var rewritten = save
        rewritten[1] = "+    let a = try read()"
        rewritten[3] = "+    guard b.isValid else { throw SaveError.invalid }"
        var unchecked = save
        unchecked[0] = "+func saveUnchecked() {"
        XCTAssertNil(placed(made, [hunk(old: 0, new: 1, rewritten + ["+"] + unchecked)]))
    }

    /// A line written twice, one under the other, or around the same
    /// frame as another test's act: commented, it finds itself.
    func testCommentOnRepeatedLinesFindsItself() throws {
        let yields = [" model.start()", "+await Task.yield()", "+await Task.yield()", " XCTAssertTrue(model.isRunning)"]
        XCTAssertEqual(placed(try anchor([hunk(old: 1, new: 1, yields)], at(.additions, 2)), [hunk(old: 1, new: 1, yields)]), [2])
        XCTAssertEqual(placed(try anchor([hunk(old: 1, new: 1, yields)], at(.additions, 3)), [hunk(old: 1, new: 1, yields)]), [3])
        let saved = [" let a = load()", " store.save(a)", "+store.save(a)", " log(\"saved\")"]
        XCTAssertEqual(placed(try anchor([hunk(old: 1, new: 1, saved)], at(.additions, 3)), [hunk(old: 1, new: 1, saved)]), [3])

        func setUp(_ client: String) -> [String] {
            [" func setUp() {", " super.setUp()", "+client = \(client)", " user = makeUser()", " url = base"]
        }
        let boilerplate = [hunk(old: 10, new: 10, setUp("Client()")), hunk(old: 40, new: 40, setUp("Client(auth: true)"))]
        let made = try anchor(boilerplate, at(.additions, 12))
        XCTAssertEqual(made.frames, 1)
        // Lines added above: still there, the other test's frame as before.
        XCTAssertEqual(placed(made, [hunk(old: 10, new: 13, setUp("Client()")), hunk(old: 40, new: 43, setUp("Client(auth: true)"))]), [15])
        // Another test alike added since: its frame could be where the act
        // was rewritten, so the comment reads outdated, though untouched
        // (outdated rather than under the wrong line). Also with one test
        // only when it was made.
        XCTAssertNil(placed(made, boilerplate + [hunk(old: 80, new: 80, setUp("Client(mock: true)"))]))
        let alone = try anchor([boilerplate[0]], at(.additions, 12))
        XCTAssertNil(placed(alone, boilerplate))
        // Its act rewritten, and a test with the old act added: not that one.
        XCTAssertNil(placed(made, [
            hunk(old: 10, new: 10, setUp("Client(retries: 3)")), hunk(old: 40, new: 40, setUp("Client(auth: true)")),
            hunk(old: 80, new: 80, setUp("Client()"))
        ]))
    }

    /// The commented code moved and rewritten elsewhere: its frame stands
    /// there now, which says more than another run sharing some of it.
    func testFrameThatAppearedElsewhereOutweighsAPartialRun() throws {
        let made = try anchor([hunk(old: 10, new: 10, [" p()", " q()", "+    return nil", " r()", " s()"])], at(.additions, 12))
        XCTAssertEqual(made.frames, 0)
        XCTAssertNil(placed(made, [
            hunk(old: 10, new: 10, [" a()", " b()"]),
            hunk(old: 80, new: 80, [" p()", " q()", "+    throw E.missing", " r()", " s()"]),
            hunk(old: 120, new: 120, [" p()", " q()", "+    return nil", " r()", " s9()"])
        ]))
    }

    /// A comment found elsewhere is made again there: its near copies are
    /// counted where it is now, not where it was made.
    func testCommentFoundElsewhereCountsItsNearCopiesThere() throws {
        let funcA = [" func a() {", " p()", " q()", "+    return nil", " r()", " s()", " }"]
        let funcB = [" func b() {", " p()", " q2()", "+    return nil", " r()", " s2()", " }"]
        let made = try anchor([hunk(old: 1, new: 1, funcA), hunk(old: 20, new: 20, funcB)], at(.additions, 4))
        // Read once: a's q() edited, the comment moves with it.
        var edited = funcA
        edited[2] = " q2()"
        guard case .placed(let moved) = BranchReview.place(made, in: file([hunk(old: 1, new: 1, edited), hunk(old: 20, new: 20, funcB)]))
        else { return XCTFail("not placed") }
        XCTAssertEqual(moved.rival, 2, "b now shares p() and q2() with it")
        // Read twice: a deleted. b isn't it.
        XCTAssertNil(placed(made, [hunk(old: 20, new: 20, funcB)], moved: moved))
    }

    /// The same frame around other code (another test's act) doesn't make
    /// a comment outdated as soon as it is made.
    func testSameFrameAroundOtherCodeLeavesTheCommentPlaced() throws {
        let tests = [
            "+func testA() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertTrue(store.isEmpty)", "+}",
            "+func testB() {", "+    let store = Store()", "+    store.add(1)", "+    store.clear()", "+    XCTAssertTrue(store.isEmpty)", "+}"
        ]
        let made = try anchor([hunk(old: 0, new: 1, tests)], at(.additions, 3))
        XCTAssertEqual(placed(made, [hunk(old: 0, new: 1, tests)]), [3])
        let context = [" func f() {", " let x = compute()", "+validate(x)", " save(x)", " }", " func g() {", " let x = compute()", " save(x)", " }"]
        let added = try anchor([hunk(old: 10, new: 10, context)], at(.additions, 12))
        XCTAssertEqual(placed(added, [hunk(old: 10, new: 10, context)]), [12])
    }

    /// The landmark is stored with the anchor, within its bytes: one that
    /// doesn't fit with the rows is left out, and the copy is found by its
    /// rank.
    func testLandmarkThatDoesntFitIsLeftOut() throws {
        // Seven rows of nearly 4,000 bytes between each name and its row.
        let between = (1...7).map { "+    // " + String(repeating: "\u{1F600}", count: 990) + "\($0)" }
        let tests = ["+func testA() {"] + between + ["+    reset()", "+}", "+func testB() {"] + between + ["+    reset()", "+}"]
        // testB's reset().
        let made = try anchor([hunk(old: 0, new: 1, tests)], at(.additions, 19))
        XCTAssertEqual(made.copy, BranchReview.CopyRank(index: 1, count: 2))
        XCTAssertTrue(made.isStorable)
        // Shorter rows between: it fits.
        let short = tests.map { $0.utf8.count > 1_000 ? "+    // note" : $0 }
        XCTAssertNotNil(try anchor([hunk(old: 0, new: 1, short)], at(.additions, 19)).copy?.landmark)
    }

    /// Copies told apart by a row further up (their names): the comment
    /// goes with its copy, whatever the others do; without such a row, by
    /// its rank, unless another copy sits where it was.
    func testCopyIsToldByTheRowThatNamesIt() throws {
        func test(_ name: String) -> [String] {
            ["+func test\(name)() {", "+    let store = Store()", "+    store.reset()", "+    XCTAssertTrue(store.isEmpty)", "+}"]
        }
        let made = try anchor([hunk(old: 0, new: 1, test("A") + test("B"))], at(.additions, 9))
        XCTAssertEqual(made.copy, BranchReview.CopyRank(index: 1, count: 2, landmark: BranchReview.Landmark(
            rows: ["func testB() {", "    let store = Store()", "    store.reset()"]
        )))
        var answered = test("A")
        answered[3] = "+    XCTAssertEqual(store.count, 0)"
        XCTAssertEqual(placed(made, [hunk(old: 0, new: 1, answered + test("B") + test("C"))]), [9])
        // testA deleted, an identical testC added: still testB.
        XCTAssertEqual(placed(made, [hunk(old: 0, new: 1, test("B") + test("C"))]), [4])
        XCTAssertNil(placed(made, [hunk(old: 0, new: 1, test("A") + test("C"))]), "testB gone")

        // Without a name to tell them, by rank.
        let blocks = [" {", "+    store.reset()", "+    XCTAssertTrue(store.isEmpty)", " }"]
        let unnamed = try anchor([hunk(old: 10, new: 10, blocks), hunk(old: 50, new: 50, blocks)], at(.additions, 52))
        XCTAssertNil(unnamed.copy?.landmark)
        XCTAssertEqual(placed(unnamed, [hunk(old: 10, new: 10, blocks), hunk(old: 50, new: 60, blocks)]), [62])
        var other = blocks
        other[2] = "+    XCTAssertEqual(store.count, 0)"
        XCTAssertNil(placed(unnamed, [hunk(old: 10, new: 50, other), hunk(old: 50, new: 52, blocks), hunk(old: 90, new: 90, blocks)]))
    }

    /// The commented block deleted: the next one, shaped the same, slides
    /// to its lines.
    func testNextBlockSlidingIntoPlaceIsntTheComments() throws {
        let blocks = [
            "+guard let a else {", "+    return nil", "+}", "+log(\"checked\")",
            "+guard let b else {", "+    return nil", "+}", "+log(\"checked\")"
        ]
        let made = try anchor([hunk(old: 10, new: 10, blocks)], at(.additions, 11))
        XCTAssertNil(placed(made, [hunk(old: 10, new: 10, Array(blocks[4...]))]))
    }

    /// Lines added elsewhere put another such row where the comment's was:
    /// the comment's own, found with nothing against it, wins.
    func testUnrelatedRowLandingWhereTheRowsWereDoesntHideThem() throws {
        let inA = [" func a() {", "+    return nil", " }"]
        let inB = [" func b() {", "+    return nil", " }"]
        let made = try anchor([hunk(old: 1, new: 1, inA), hunk(old: 20, new: 20, inB)], at(.additions, 21))
        let grown = [" func a() {"] + (1...19).map { "+    step\($0)()" } + ["+    return nil", " }"]
        XCTAssertEqual(placed(made, [hunk(old: 1, new: 1, grown), hunk(old: 20, new: 39, inB)]), [40])
    }

    func testContextIsReadNearAndOnce() throws {
        // Three rows above at most: q is now four away.
        let spread = try anchor([hunk(old: 1, new: 1, [" q()", " p()", "+row()", " r()"])], at(.additions, 3))
        XCTAssertNil(placed(spread, [hunk(old: 1, new: 1, [" q()", " y1()", " y2()", " p2()", "+row()", " r()"])]))
        // The nearest row is missing where the hunk shows it: against,
        // though the hunk doesn't reach the next.
        let edge = try anchor([hunk(old: 1, new: 1, [" q()", " p()", "+row()", " r()"])], at(.additions, 3))
        XCTAssertNil(placed(edge, [hunk(old: 1, new: 5, [" p2()", "+row()", " r()"])]))
        // One row found counts once, though the context holds it twice.
        let twice = try anchor([hunk(old: 1, new: 1, [" q()", " q()", "+row()", " r()"])], at(.additions, 3))
        XCTAssertNil(placed(twice, [hunk(old: 1, new: 1, [" q()", " x()", " y()", "+row()", " r2()"])]))
    }

    func testRemovedRowStaysAtItsLineOfTheBase() throws {
        let made = try anchor([hunk(old: 10, new: 10, [" a()", "-gone()", " b()"])], at(.deletions, 11))
        XCTAssertEqual(placed(made, [hunk(old: 11, new: 15, ["-gone()"])]), [11])
    }

    /// A removed row's line of the base can be the comment's line in the
    /// working tree: it isn't where the comment's rows were, and its frame
    /// there doesn't make the comment outdated as soon as it is made.
    func testRemovedRowNumberedAsTheCommentIsntWhereItWas() throws {
        let lines = [
            " import XCTest", " ", " final class StoreTests: XCTestCase {",
            "+    func testB() {", "+        let store = Store()", "+        store.clear()", "+        XCTAssertTrue(store.isEmpty)",
            "+    }", "+",
            "     func testA() {", "         let store = Store()", "-        store.reset()", "+        store.removeAll()",
            "         XCTAssertTrue(store.isEmpty)", "     }", " }"
        ]
        // testB's act, at line 6 of the working tree; testA's, removed, at
        // line 6 of the base.
        let made = try anchor([hunk(old: 1, new: 1, lines)], at(.additions, 6))
        XCTAssertEqual(placed(made, [hunk(old: 1, new: 1, lines)]), [6])
    }

    func testWhereItWasMadeAndWhereItWasLastFoundAreBothLookedFor() throws {
        let lines = [" let a = 1", " let b = 2", "+guard x else { return }", " let c = 3"]
        let made = try anchor([hunk(old: 10, new: 10, lines)], at(.additions, 12))
        let moved = try anchor([hunk(old: 10, new: 30, [" let z = 0", " let b = 2", "+guard x else { return }", " let y = 9"])], at(.additions, 32))

        // Back where it was made.
        XCTAssertEqual(BranchReview.place(made, moved: moved, in: file([hunk(old: 10, new: 10, lines)])), .placed(made))
        // Its context changed since it was made, but it is where it was
        // last found.
        let now = [hunk(old: 10, new: 30, [" let z = 0", " let w = 5", "+guard x else { return }", " let y = 9"])]
        XCTAssertEqual(BranchReview.place(made, in: file(now)), .outdated)
        XCTAssertEqual(placed(made, now, moved: moved), [32])

        // Both match, in different places: the better evidence wins; as
        // good leaves it outdated.
        func elsewhere(_ second: String) -> [BranchReview.Hunk] {
            [hunk(old: 10, new: 10, lines), hunk(old: 30, new: 30, [" let z = 0", " " + second, "+guard x else { return }", " let y = 9"])]
        }
        let lastFound = try anchor([elsewhere("let q = 7")[1]], at(.additions, 32))
        XCTAssertEqual(placed(made, elsewhere("let r = 8"), moved: lastFound), [12])
        XCTAssertNil(placed(made, elsewhere("let q = 7"), moved: lastFound))
        var weaker = elsewhere("let q = 7")
        weaker[0] = hunk(old: 10, new: 10, [" let a = 1", " let b2 = 2", "+guard x else { return }", " let c = 3"])
        XCTAssertEqual(placed(made, weaker, moved: lastFound), [32])
    }

    func testCommentsFollowARenamedFile() throws {
        let lines = [" let a = 1", "+guard x else { return }", " let b = 2"]
        var record = Record()
        record.addComment(id: "c1", anchor: try anchor([hunk(old: 1, new: 1, lines)], at(.additions, 2)), text: "Line", at: date)
        record.addComment(id: "c2", anchor: .file("a.swift"), text: "File", at: date)
        let comment = try XCTUnwrap(record.comment(id: "c1"))

        // Not read yet: found under its new name all the same.
        let unread = file([], path: "b.swift", oldPath: "a.swift", omission: .onDemand)
        XCTAssertEqual(BranchReview.file(for: comment.anchor, moved: nil, in: [file([], path: "c.swift"), unread]), unread)
        // The file's comment follows at once; the line's waits for the
        // file's rows.
        XCTAssertTrue(record.reanchor(in: [unread]))
        XCTAssertEqual(record.comment(id: "c2")?.current, .file("b.swift"))
        XCTAssertNil(record.comment(id: "c1")?.moved)

        XCTAssertTrue(record.reanchor(in: [file([hunk(old: 1, new: 1, lines)], path: "b.swift", oldPath: "a.swift")]))
        XCTAssertEqual(record.comment(id: "c1")?.current.path, "b.swift")
        XCTAssertEqual(record.comment(id: "c1")?.anchor.path, "a.swift", "where it was made stays")
        XCTAssertEqual(record.comment(id: "c2")?.current, .file("b.swift"))
        // Renamed again: found by where it was last found, before a new
        // file under its first name.
        let moved = try XCTUnwrap(record.comment(id: "c1"))
        let both = [file([], path: "a.swift"), file([], path: "b.swift")]
        XCTAssertEqual(BranchReview.file(for: moved.anchor, moved: moved.moved, in: both)?.path, "b.swift")
        XCTAssertEqual(BranchReview.file(for: moved.anchor, moved: moved.moved, in: [file([], path: "d.swift", oldPath: "b.swift")])?.path, "d.swift")
    }

    func testFileCommentLastsAsLongAsItsFile() {
        let made = Anchor.file("a.swift")
        XCTAssertEqual(BranchReview.place(made, in: file([], omission: .tooLarge)), .placed(made))
        XCTAssertEqual(BranchReview.place(made, in: nil), .fileGone)
    }
}

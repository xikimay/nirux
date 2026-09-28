import XCTest

/// Which test runs which palette command or sidebar menu item, so that a
/// new one without a test fails the build's tests instead of shipping
/// unexercised. Checked twice:
/// - `checkEveryItemIsCovered`, by a guard test, against what the UI
///   offers now;
/// - `checkRun`, after every test of the class, against what the test ran.
struct UIFlowCoverage {
    enum Kind: String {
        case paletteCommand = "palette command"
        case sidebarMenuItem = "sidebar menu item"
    }

    let kind: Kind
    /// Test method name → the items it must run.
    let tests: [String: [String]]
    /// Items no test runs → why.
    let exemptions: [String: String]

    func checkEveryItemIsCovered(
        offered: [String], testNames: Set<String>, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(offered.isEmpty, "no \(kind.rawValue) found", file: file, line: line)
        let covered = tests.values.flatMap { $0 }
        XCTAssertEqual(covered.count, Set(covered).count, "a \(kind.rawValue) is listed under two tests", file: file, line: line)
        for item in offered where !covered.contains(item) && exemptions[item] == nil {
            XCTFail("no test runs the \(kind.rawValue) “\(item)”: list it under a test in the coverage table", file: file, line: line)
        }
        for item in Set(covered).union(exemptions.keys) where !offered.contains(item) {
            XCTFail("the coverage table lists the \(kind.rawValue) “\(item)”, which no longer exists", file: file, line: line)
        }
        for (item, reason) in exemptions {
            XCTAssertFalse(covered.contains(item), "“\(item)” is both covered and exempted", file: file, line: line)
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, "the exemption of “\(item)” gives no reason", file: file, line: line)
        }
        for testName in tests.keys where !testNames.contains(testName) {
            XCTFail("the coverage table names \(testName), which is not a test", file: file, line: line)
        }
    }

    func checkRun(_ run: Set<String>, by testName: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = Set(tests[testName] ?? [])
        let missed = expected.subtracting(run)
        XCTAssertTrue(missed.isEmpty, "\(testName) didn't run the \(kind.rawValue)s \(missed.sorted())", file: file, line: line)
        let unlisted = run.subtracting(expected)
        XCTAssertTrue(unlisted.isEmpty, "list the \(kind.rawValue)s \(unlisted.sorted()) under \(testName)", file: file, line: line)
    }

    /// The method names of a test class's tests.
    static func testNames(of testClass: XCTestCase.Type) -> Set<String> {
        Set(testClass.defaultTestSuite.tests.map { methodName(of: $0.name) })
    }

    /// "testX" from "-[NiruxTests.SomeTests testX]".
    static func methodName(of testName: String) -> String {
        String(testName.split(separator: " ").last?.dropLast() ?? "")
    }
}

/// A flow test class whose tests each run exactly what its coverage table
/// lists, whatever way they build their harness: checked after every test
/// that passed (a failed one already says why).
@MainActor
class UIFlowTestCase: XCTestCase {
    /// The table this class's tests are checked against.
    class var coverage: UIFlowCoverage? { nil }

    nonisolated override func invokeTest() {
        let testName = UIFlowCoverage.methodName(of: name)
        MainActor.assumeIsolated { UIFlowHarness.itemsRun = [:] }
        super.invokeTest()
        // The run hasn't stopped yet: count its failures.
        let passed = testRun?.totalFailureCount == 0
        MainActor.assumeIsolated {
            guard passed, let coverage = Self.coverage else { return }
            coverage.checkRun(UIFlowHarness.itemsRun[coverage.kind] ?? [], by: testName)
        }
    }
}

import XCTest
@testable import Nirux

final class ColumnWidthTests: XCTestCase {
    @MainActor
    private func makeColumn() -> ColumnState {
        ColumnState(cwd: "/tmp")
    }

    @MainActor
    func testCycleFromPresetFollowsLegacyOrder() {
        let col = makeColumn()
        col.widthFraction = ColumnWidth.half.fraction
        col.cycleWidth()
        XCTAssertEqual(col.widthFraction, ColumnWidth.third.fraction, accuracy: 0.001)
        col.cycleWidth()
        XCTAssertEqual(col.widthFraction, ColumnWidth.quarter.fraction, accuracy: 0.001)
        col.cycleWidth()
        XCTAssertEqual(col.widthFraction, ColumnWidth.full.fraction, accuracy: 0.001, "wraps around")
    }

    @MainActor
    func testCycleFromFreeformSnapsToNearestThenNext() {
        let col = makeColumn()
        // 0.51 is closest to .half (0.5) → next preset is .third.
        col.widthFraction = 0.51
        col.cycleWidth()
        XCTAssertEqual(col.widthFraction, ColumnWidth.third.fraction, accuracy: 0.001)
        // 0.9 is closest to .full (1.0) → next wraps to .twoThirds.
        col.widthFraction = 0.9
        col.cycleWidth()
        XCTAssertEqual(col.widthFraction, ColumnWidth.twoThirds.fraction, accuracy: 0.001)
    }

    @MainActor
    func testWidthClampBounds() {
        XCTAssertLessThan(WorkspaceState.minWidthFraction, ColumnWidth.quarter.fraction)
        XCTAssertGreaterThan(WorkspaceState.maxWidthFraction, ColumnWidth.full.fraction)
    }
}

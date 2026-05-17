enum EditorDiffMode: String, CaseIterable {
    case head
    case branch

    var label: String {
        switch self {
        case .head: return "HEAD"
        case .branch: return "Branch"
        }
    }

    var tooltipLabel: String {
        switch self {
        case .head: return "HEAD"
        case .branch: return "Branch"
        }
    }

    var segmentIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    static func mode(forSegment segment: Int) -> EditorDiffMode {
        guard allCases.indices.contains(segment) else { return .head }
        return allCases[segment]
    }
}

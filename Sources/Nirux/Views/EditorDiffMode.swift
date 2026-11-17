enum EditorDiffMode: String, CaseIterable {
    case head
    case branch

    var label: String {
        switch self {
        case .head: return "HEAD"
        case .branch: return "Branch"
        }
    }

    static func mode(forSegment segment: Int) -> EditorDiffMode {
        guard allCases.indices.contains(segment) else { return .head }
        return allCases[segment]
    }
}

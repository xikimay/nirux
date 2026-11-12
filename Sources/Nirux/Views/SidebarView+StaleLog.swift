import AppKit

// MARK: - The sidebar's side of the stale-rows log

/// What the sidebar holds and draws, for the line `SidebarStaleLog` writes
/// when the pointer comes back to it: rows of tasks that were gone were
/// seen to stay until a click or a pass over the list, and nothing told
/// whether the list, its rows or the screen was behind. Counts and
/// booleans only: no title, no path, no text.
extension SidebarView {
    /// The pointer's gestures on the sidebar.
    enum PointerGesture: String {
        case move, press
    }

    /// How long the pointer leaves the sidebar alone before its next move
    /// or press counts as coming back.
    static let pointerReturnIdle: CFTimeInterval = 2

    /// A move or a press on the sidebar, before it changes anything: the
    /// first one after `pointerReturnIdle` without either is told
    /// (`onPointerReturn`), with how long that was (nil: the first ever).
    func notePointer(_ gesture: PointerGesture) {
        let now = clock()
        let idle = lastPointerAt.map { now - $0 }
        lastPointerAt = now
        if let idle, idle < Self.pointerReturnIdle { return }
        onPointerReturn?(gesture, idle)
    }

    /// The list as held and as drawn.
    struct DrawnFacts: Equatable {
        /// The tasks held (`lastInfos`).
        var held = 0
        /// The rows drawn, and the rows the held list asks for.
        var rowsDrawn = 0
        var rowsExpected = 0
        /// Layers in the list that back no view of this render, and views
        /// of it whose layer isn't in the list's: AppKit attaches a new
        /// row's layer at its next display pass.
        var strayLayers = 0
        var viewsWithoutLayer = 0
        /// The window has a display pass to make.
        var needsDisplay = false
        /// The pictures of rows that left, the most opaque one as shown,
        /// and the views still coming up under them.
        var foldGhosts = 0
        var foldGhostOpacity: Float = 0
        var foldPulls = 0
        /// A row press is tracked; an update, a rebuild wait for its end.
        var isDragTracked = false
        var hasDeferredUpdate = false
        var skippedRebuild = false
        var animates = false
        var isExpanded = false
        /// The list fits the sidebar: it doesn't scroll.
        var fits = false
        /// Seconds since the rows were last rebuilt and since the last
        /// update came (`clock`); nil: never.
        var sinceRebuild: CFTimeInterval?
        var sinceUpdate: CFTimeInterval?
    }

    func drawnFacts() -> DrawnFacts {
        let now = clock()
        let list = contentDocumentView
        let viewLayers = Set(list.subviews.compactMap(\.layer).map(ObjectIdentifier.init))
        let ghosts = expandedViews.filter { $0.identifier == Self.foldGhostID }.compactMap { $0.layer?.sublayers?.first }
        let expected = isExpanded ? lastInfos.filter(listsWorkspace).count : isRailHidden ? 0 : railWorkspaceInfos.count
        return DrawnFacts(
            held: lastInfos.count,
            rowsDrawn: hitAreas.filter { if case .workspace = $0.region { true } else { false } }.count,
            rowsExpected: expected,
            strayLayers: (list.layer?.sublayers ?? []).filter { !viewLayers.contains(ObjectIdentifier($0)) }.count,
            viewsWithoutLayer: list.subviews.filter { $0.layer == nil || $0.layer?.superlayer !== list.layer }.count,
            needsDisplay: window?.viewsNeedDisplay ?? false,
            foldGhosts: ghosts.count,
            foldGhostOpacity: ghosts.map { $0.presentation()?.opacity ?? $0.opacity }.max() ?? 0,
            foldPulls: expandedViews.filter { $0.layer?.animation(forKey: Self.foldPullKey) != nil }.count,
            isDragTracked: workspaceDrag != nil,
            hasDeferredUpdate: deferredDragUpdate != nil,
            skippedRebuild: rebuildSkippedDuringDrag,
            animates: animates,
            isExpanded: isExpanded,
            fits: list.frame.height <= bounds.height + 0.5,
            sinceRebuild: lastRebuildAt.map { now - $0 },
            sinceUpdate: lastUpdateAt.map { now - $0 }
        )
    }
}

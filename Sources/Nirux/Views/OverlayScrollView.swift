import AppKit

/// A scroll view whose scrollers always overlay the content: they take none
/// of its width, so a view laid out at its full width stays whole.
///
/// `scrollerStyle = .overlay` alone doesn't hold. When the preferred style
/// changes (a mouse plugged in, the setting changed, or once a moment after
/// launch on a Mac with a mouse), AppKit sets every live scroll view to it,
/// through this setter: legacy scrollers would then cover the last 15 pt.
class OverlayScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .overlay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        // DO NOT MERGE: the flake gate's revert.
        set { super.scrollerStyle = ProcessInfo.processInfo.environment["NIRUX_ZZ_MUTANT"] == "noPin" ? newValue : .overlay }
    }
}

import AppKit

extension NSScrollView {
    /// The width to lay out a document drawn at a width of its own: the
    /// clip's. A legacy scroller (the Mac's "Show scroll bars: Always", or a
    /// mouse) takes its own beside a document taller than the clip, as in
    /// Finder's sidebar; an overlay one takes none.
    ///
    /// The document's height depends on that width: `measure` gives it at a
    /// width, without touching what is shown, with whatever else it found.
    /// Whole first: a document that fits whole keeps no scroller, even one
    /// it would overflow under. Narrower, a document is no shorter, so one
    /// that overflows whole overflows beside the scroller: a second measure
    /// is enough, and only when a legacy scroller shows. `frameSize`: the
    /// scroll view's, before or after it takes it.
    func documentWidth<Measured>(
        frameSize: NSSize, measure: (CGFloat) -> (height: CGFloat, measured: Measured)
    ) -> (width: CGFloat, measured: Measured) {
        let whole = clipWidth(frameSize: frameSize, documentHeight: 0)
        let first = measure(whole)
        let width = clipWidth(frameSize: frameSize, documentHeight: first.height)
        guard width != whole else { return (whole, first.measured) }
        return (width, measure(width).measured)
    }

    /// The clip's width around a document `height` tall, as `tile()` lays
    /// it out. No horizontal scroller: the document takes the clip's width.
    func clipWidth(frameSize: NSSize, documentHeight height: CGFloat) -> CGFloat {
        func clip(scroller: Bool) -> NSSize {
            NSScrollView.contentSize(
                forFrameSize: frameSize, horizontalScrollerClass: nil,
                verticalScrollerClass: scroller ? verticalScroller.map { type(of: $0) } ?? NSScroller.self : nil,
                borderType: borderType, controlSize: verticalScroller?.controlSize ?? .regular, scrollerStyle: scrollerStyle
            )
        }
        let shows = hasVerticalScroller && (!autohidesScrollers || height > clip(scroller: false).height)
        return clip(scroller: shows).width
    }
}

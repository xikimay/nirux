import AppKit

/// NSView subclass whose background drags the window (like a title bar).
final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// NSView that accepts file drops and pastes the dropped file paths into
/// the PTY via the `onFileDrop` callback.
final class DropTargetView: NSView {
    var onFileDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        onFileDrop?(urls)
        return true
    }
}

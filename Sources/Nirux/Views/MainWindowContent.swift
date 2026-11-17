import AppKit

/// The main window's content (docs/design/glass-interface.md, 4.2): its
/// backdrop under the whole window, title bar included (the window has a
/// full-size content view), and the shell below the toolbar. At Opaque the
/// backdrop is the canvas, as the window's background was. At the other
/// levels one frost blends the desktop behind the window, tinted with the
/// canvas at the level's chrome alpha; the chrome lies on it, and the
/// columns stay opaque. An inactive window goes flat, as macOS's own do.
final class MainWindowContent: NSView {
    let shell: NiruxShellView
    private let frost = NSVisualEffectView()
    private let tint = NSView()
    private var shellPinned = false

    init(shell: NiruxShellView) {
        self.shell = shell
        super.init(frame: shell.frame)
        frost.blendingMode = .behindWindow
        frost.material = .underWindowBackground
        frost.state = .followsWindowActiveState
        frost.autoresizingMask = [.width, .height]
        frost.frame = bounds
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        tint.frame = bounds
        shell.translatesAutoresizingMaskIntoConstraints = false
        for view in [frost, tint, shell] { addSubview(view) }
        show(.opaque)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The shell follows the area below the toolbar, in and out of full
    /// screen; the window takes the level shown before it held this view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
        guard !shellPinned, let guide = window?.contentLayoutGuide as? NSLayoutGuide else { return }
        shellPinned = true
        NSLayoutConstraint.activate([
            shell.topAnchor.constraint(equalTo: guide.topAnchor),
            shell.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            shell.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
        ])
    }

    /// Whether the window lets the desktop through.
    private(set) var isTranslucent = false

    /// Whether a terminal lets the desktop through (`TerminalOpacity`):
    /// the window is non-opaque then too, whatever the interface's level.
    private var terminalsTranslucent = false

    /// The level drawn (macOS's Reduce transparency and Increase contrast
    /// already made it opaque), and whether a terminal is translucent.
    func show(_ drawn: InterfaceTransparency, terminalsTranslucent: Bool = false) {
        self.terminalsTranslucent = terminalsTranslucent
        isTranslucent = drawn.usesGlass
        frost.isHidden = !isTranslucent
        tint.isHidden = !isTranslucent
        tint.layer?.backgroundColor = Theme.Color.canvas
            .withAlphaComponent(GlassView.tintAlpha(for: drawn, role: .chrome)).cgColor
        applyToWindow()
    }

    private func applyToWindow() {
        let lets = isTranslucent || terminalsTranslucent
        guard let window, window.isOpaque == lets else { return }
        window.isOpaque = !lets
        window.backgroundColor = lets ? .clear : Theme.Color.canvas
        // Once the window has drawn the new level.
        DispatchQueue.main.async { [weak window] in window?.invalidateShadow() }
    }
}

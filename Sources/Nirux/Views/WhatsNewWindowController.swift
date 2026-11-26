import AppKit

/// The What's New window's text: each nightly's entries under its build,
/// each with its kind, its title, its pull request and its Why.
enum WhatsNewText {
    static let titleIndent: CGFloat = 104

    static func attributed(_ nightlies: [Changelog.Nightly], installedBuild: Int, pullRequestURL: (Int) -> URL?) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let row = NSMutableParagraphStyle()
        row.tabStops = [NSTextTab(textAlignment: .left, location: titleIndent)]
        row.headIndent = titleIndent
        row.paragraphSpacing = 2
        for nightly in nightlies {
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacingBefore = text.length == 0 ? 0 : Theme.Space.lg
            heading.paragraphSpacing = Theme.Space.xs
            text.append(NSAttributedString(string: "Nightly \(Changelog.name(ofBuild: nightly.build))\(state(of: nightly.build, installed: installedBuild))\n", attributes: [
                .font: Theme.Font.title, .foregroundColor: Theme.Color.textPrimary, .paragraphStyle: heading
            ]))
            for (index, entry) in nightly.entries.enumerated() {
                let kind = index == 0 || nightly.entries[index - 1].kind != entry.kind ? entry.kind.label : ""
                text.append(NSAttributedString(string: kind + "\t", attributes: [
                    .font: Theme.Font.caption, .foregroundColor: Theme.Color.textTertiary, .paragraphStyle: row
                ]))
                text.append(NSAttributedString(string: entry.title + "  ", attributes: [
                    .font: Theme.Font.body, .foregroundColor: Theme.Color.textPrimary, .paragraphStyle: row
                ]))
                var number: [NSAttributedString.Key: Any] = [.font: Theme.Font.captionDigits, .foregroundColor: Theme.Color.done, .paragraphStyle: row]
                number[.link] = pullRequestURL(entry.pullRequest)
                text.append(NSAttributedString(string: "#\(entry.pullRequest)", attributes: number))
                if let why = entry.why {
                    text.append(NSAttributedString(string: "\n\t" + why, attributes: [
                        .font: Theme.Font.caption, .foregroundColor: Theme.Color.textSecondary, .paragraphStyle: row
                    ]))
                }
                text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: row]))
            }
        }
        return text
    }

    /// " · installed", " · not installed yet", or nothing for older builds.
    static func state(of build: Int, installed: Int) -> String {
        if build == installed { return " · installed" }
        return installed > 0 && build > installed ? " · not installed yet" : ""
    }
}

/// The What's New window (Help › What's New, ⌘P): what the nightlies
/// brought, newest first, searchable, the internal work behind a checkbox.
final class WhatsNewWindowController: NSWindowController {
    let search = NSSearchField()
    let showsInternal = NSButton(checkboxWithTitle: "Show under the hood", target: nil, action: nil)
    let headline = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSTextView.scrollableTextView()
    var textView: NSTextView { scroll.documentView as! NSTextView }
    private let pullRequestURL: (Int) -> URL?
    private var changelog: Changelog?
    private var installedBuild = 0
    private var failure: String?

    init(pullRequestURL: @escaping (Int) -> URL?) {
        self.pullRequestURL = pullRequestURL
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true
        )
        window.title = "What’s New"
        window.appearance = Theme.appearance
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 360)
        window.setFrameAutosaveName("NiruxWhatsNew")
        super.init(window: window)

        search.placeholderString = "Search changes"
        search.target = self
        search.action = #selector(filterChanged)
        showsInternal.target = self
        showsInternal.action = #selector(filterChanged)
        headline.font = Theme.Font.caption
        headline.textColor = Theme.Color.textSecondary
        textView.isEditable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: Theme.Space.xs)
        textView.linkTextAttributes = [.foregroundColor: Theme.Color.done, .cursor: NSCursor.pointingHand]
        scroll.drawsBackground = false
        let bar = NSStackView(views: [search, showsInternal])
        bar.spacing = Theme.Space.md
        let stack = NSStackView(views: [bar, headline, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.md
        stack.edgeInsets = NSEdgeInsets(top: Theme.Space.lg, left: 20, bottom: Theme.Space.lg, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            headline.widthAnchor.constraint(equalTo: bar.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: bar.widthAnchor)
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `failure`: why the published changelog couldn't be read, shown
    /// under what was read before.
    func update(changelog: Changelog?, installedBuild: Int, failure: String?) {
        self.changelog = changelog
        self.installedBuild = installedBuild
        self.failure = failure
        render()
    }

    @objc private func filterChanged() { render() }

    private func render() {
        let yours = Changelog.date(ofBuild: installedBuild) == nil
            ? "This build isn’t a nightly."
            : "You run the nightly of \(Changelog.name(ofBuild: installedBuild))."
        headline.stringValue = [yours, failure.map { "Couldn’t refresh: \($0)" }].compactMap { $0 }.joined(separator: " ")
        let query = search.stringValue
        let nightlies = changelog?.nightlies(matching: query, includingInternal: showsInternal.state == .on) ?? []
        let empty = changelog == nil ? (failure == nil ? "Reading the changelog…" : "No changelog to show.")
            : query.trimmingCharacters(in: .whitespaces).isEmpty ? "No change to show yet." : "No change matches “\(query)”."
        textView.textStorage?.setAttributedString(nightlies.isEmpty
            ? NSAttributedString(string: empty, attributes: [.font: Theme.Font.body, .foregroundColor: Theme.Color.textTertiary])
            : WhatsNewText.attributed(nightlies, installedBuild: installedBuild, pullRequestURL: pullRequestURL))
    }
}

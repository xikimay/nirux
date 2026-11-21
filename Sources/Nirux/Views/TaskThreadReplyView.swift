import AppKit

@MainActor
final class TaskThreadReplyView: NSStackView {
    let questionID: String
    let field: MissionReplyTextView
    private let heading: NSTextField
    private let send = NSButton(title: "Send ⌘↩", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    var onSend: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(questionID: String, question: String, width: CGFloat) {
        self.questionID = questionID
        heading = NSTextField(labelWithString: question)
        let input = MissionReplyTextView.field(width: width - 2 * Theme.Space.md)
        field = input.text
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .width
        spacing = Theme.Space.xs
        edgeInsets = NSEdgeInsets(top: Theme.Space.xs, left: Theme.Space.md, bottom: Theme.Space.md, right: Theme.Space.md)
        heading.lineBreakMode = .byTruncatingTail
        heading.toolTip = question
        heading.font = Theme.Font.bodyEmphasized
        field.setAccessibilityLabel("Your answer to " + question)
        field.onCommandReturn = { [weak self] in self?.submit() }
        send.bezelStyle = .rounded
        send.bezelColor = Theme.Color.accent
        send.target = self
        send.action = #selector(submit)
        cancel.target = self
        cancel.action = #selector(cancelReply)
        addArrangedSubview(heading)
        addArrangedSubview(input.scroll)
        addArrangedSubview(NSStackView(views: [NSView(), cancel, send]))
    }

    required init?(coder: NSCoder) { nil }

    func markClosed() {
        heading.stringValue = "Question no longer open"
        field.isEditable = false
        send.isEnabled = false
        cancel.title = "Done"
    }

    @objc private func submit() {
        guard send.isEnabled else { return }
        onSend?(field.string)
    }

    @objc private func cancelReply() { onCancel?() }
}

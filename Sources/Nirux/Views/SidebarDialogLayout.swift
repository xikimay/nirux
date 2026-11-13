import AppKit

/// How a question dialog's block shows on its task's row, within one
/// bound (`SidebarExpandedMetrics.dialogMaxHeight`): whole when it fits,
/// else giving way by steps (`Step`), the last of which always fits.
/// Measured once for a dialog at a width: the card's layout and its
/// renderer read the same one at every rebuild.
@MainActor
struct SidebarDialogLayout {
    typealias Metrics = SidebarExpandedMetrics

    /// What gives way, in this order. The tooltips keep what a step cuts.
    enum Step: Int, Comparable {
        /// Every question and option whole.
        case whole
        /// What each option means, cut to two lines past its label.
        case shortDetails
        /// The options' labels alone.
        case labels
        /// The first questions, labels alone: the hint counts the others.
        case firstQuestions
        /// The first question's first lines, and its labels'.
        case tight

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One line of text in the block: what it says, on how many lines.
    struct Line {
        let text: NSAttributedString
        let lines: Int
        let toolTip: String
        var height: CGFloat { CGFloat(lines) * Metrics.questionLineHeight }
    }

    struct Question {
        let asked: Line
        let options: [Line]
        /// Where the options' text starts, past their numbers.
        let indent: CGFloat

        var height: CGFloat {
            let options = options.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(options.count - 1, 0)) * Metrics.choiceGap
            return asked.height + (self.options.isEmpty ? 0 : Metrics.questionGap + options)
        }
    }

    let step: Step
    /// The questions shown, the dialog's first.
    let questions: [Question]
    /// The questions left to the terminal.
    let more: Int

    /// The questions, then the hint's line.
    var height: CGFloat {
        questions.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(questions.count - 1, 0)) * Metrics.dialogQuestionGap
            + Metrics.actionRowGap + Metrics.actionLineHeight
    }

    /// Where the answers go, and how many questions only the terminal shows.
    var hint: String {
        switch more {
        case 0: return "Answer in the terminal"
        case 1: return "1 more question in the terminal"
        default: return "\(more) more questions in the terminal"
        }
    }

    // MARK: - Measuring

    private struct Key: Hashable {
        let dialog: AgentDialog
        let width: CGFloat
    }

    /// A few dialogs at a time are on screen: measured once each.
    private static var measured: [Key: SidebarDialogLayout] = [:]

    static func make(_ dialog: AgentDialog, width: CGFloat) -> SidebarDialogLayout {
        let key = Key(dialog: dialog, width: width)
        if let layout = measured[key] { return layout }
        let layout = fitting(dialog, width: width)
        if measured.count >= 16 { measured.removeAll() }
        measured[key] = layout
        return layout
    }

    /// Each text measured once, whole: a step only caps its lines.
    private struct Texts {
        let asked: NSAttributedString
        let askedLines: Int
        let source: String
        /// Label and meaning, the label alone, each with its lines whole.
        let whole: [(text: NSAttributedString, lines: Int)]
        let labels: [(text: NSAttributedString, lines: Int)]
        let toolTips: [String]
        let indent: CGFloat
    }

    private static func fitting(_ dialog: AgentDialog, width: CGFloat) -> SidebarDialogLayout {
        let texts = dialog.questions.map { measure($0, width: width) }
        for step in [Step.whole, .shortDetails, .labels] {
            let layout = SidebarDialogLayout(step: step, questions: texts.map { shown($0, at: step) }, more: 0)
            if layout.height <= Metrics.dialogMaxHeight { return layout }
        }
        for count in stride(from: texts.count - 1, through: 1, by: -1) {
            let layout = SidebarDialogLayout(
                step: .firstQuestions, questions: texts.prefix(count).map { shown($0, at: .firstQuestions) }, more: texts.count - count
            )
            if layout.height <= Metrics.dialogMaxHeight { return layout }
        }
        return SidebarDialogLayout(step: .tight, questions: texts.prefix(1).map { shown($0, at: .tight) }, more: texts.count - 1)
    }

    private static func measure(_ question: AgentDialog.Question, width: CGFloat) -> Texts {
        let options = SidebarQuestionText.options(question)
        @MainActor func lines(_ text: NSAttributedString, indent: CGFloat = 0) -> Int {
            SidebarWrappedText.lineCount(text, width: width, lineHeight: Metrics.questionLineHeight, maxLines: 1_000, indent: indent)
        }
        let asked = SidebarQuestionText.question(question.text)
        return Texts(
            asked: asked, askedLines: lines(asked), source: question.text,
            whole: options.whole.texts.map { ($0, lines($0, indent: options.whole.indent)) },
            labels: options.labels.texts.map { ($0, lines($0, indent: options.labels.indent)) },
            toolTips: options.toolTips, indent: options.whole.indent
        )
    }

    private static func shown(_ texts: Texts, at step: Step) -> Question {
        let askedCap = step == .tight ? Metrics.dialogTightQuestionLines : Metrics.dialogMaxLines
        let options = texts.whole.indices.map { index -> Line in
            let label = texts.labels[index]
            let option: (text: NSAttributedString, lines: Int)
            let cap: Int
            switch step {
            case .whole:
                (option, cap) = (texts.whole[index], Metrics.dialogMaxLines)
            case .shortDetails:
                (option, cap) = (texts.whole[index], min(label.lines + Metrics.dialogShortDetailLines, Metrics.dialogMaxLines))
            case .labels, .firstQuestions:
                (option, cap) = (label, Metrics.dialogMaxLines)
            case .tight:
                (option, cap) = (label, Metrics.dialogTightOptionLines)
            }
            return Line(text: option.text, lines: min(option.lines, cap), toolTip: texts.toolTips[index])
        }
        return Question(
            asked: Line(text: texts.asked, lines: min(texts.askedLines, askedCap), toolTip: texts.source),
            options: options, indent: texts.indent
        )
    }
}

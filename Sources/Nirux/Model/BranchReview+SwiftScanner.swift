import Foundation

// MARK: - Swift scanner

extension BranchReview {
    /// A name a Swift file declares outside any function body, as
    /// `SwiftScanner` reads it.
    struct Declaration: Equatable {
        let symbol: Symbol
        /// Private or fileprivate (by its own modifier or its type's), an
        /// `override`, or an `@objc` or `@IBAction` method: tests reach it
        /// through the API, the superclass or the runtime that calls it.
        let isHidden: Bool
        /// The type its extension at the file's level extends, as
        /// written (`Outer.Inner`): a private type's extension is private
        /// too.
        let extended: String?
        /// On a line fed with `collecting`.
        let isCollected: Bool
    }

    /// Reads Swift source a line at a time and collects what it declares
    /// outside any function body: a name after `func`, `var`, `let`,
    /// `class`, `struct`, `enum`, `case`, `protocol`, `typealias` or
    /// `actor`, at the file's level or in a type's or an extension's
    /// body. Strings (multi-line and raw ones, interpolations included)
    /// and comments (nested ones included) are skipped; braces tell the
    /// bodies apart. Known limits: a bare `/regex/` literal reads as code,
    /// and `#if` branches that each open a brace (which Swift rejects)
    /// read as two: the file then reads unbalanced.
    struct SwiftScanner {
        private(set) var declarations: [Declaration] = []
        /// Types declared private or fileprivate, by their dotted path.
        private(set) var privateTypes: Set<String> = []
        /// Names looked for in the code, interpolations included, but not
        /// in comments or strings: each one found is removed.
        var words: WordSet?
        private var lineNumber = 0
        private var collecting = false
        /// A brace closed with none open.
        private var closedUnopened = false

        /// Whether every brace, string and comment the source opened is
        /// closed: what follows a stray one may have read wrong.
        var isBalanced: Bool { !closedUnopened && scopes.isEmpty && modes.isEmpty }

        /// What the review lists: declared on collected lines, not hidden,
        /// nor in an extension of a private type or of a type nested in one
        /// (declared before or after it).
        var symbols: [Symbol] {
            declarations.filter { declaration in
                declaration.isCollected && !declaration.isHidden && !(declaration.extended.map(isPrivatePath) ?? false)
            }.map(\.symbol)
        }

        /// `Outer.Inner` is private when `Outer` or `Outer.Inner` is.
        private func isPrivatePath(_ path: String) -> Bool {
            var prefix = ""
            for part in path.split(separator: ".") {
                prefix += (prefix.isEmpty ? "" : ".") + part
                if privateTypes.contains(prefix) { return true }
            }
            return false
        }

        // Lexer: what the code is nested in, innermost last.
        private enum Mode {
            case string(hashes: Int, isMultiline: Bool)
            /// `\(…)` in a string: code, with the parentheses open in it.
            case interpolation(parentheses: Int)
            case blockComment(depth: Int)
            /// `#/…/#`.
            case regex(hashes: Int)
        }

        private var modes: [Mode] = []

        // Parser.
        private enum Token {
            case identifier(UnsafeRawBufferPointer, isEscaped: Bool)
            case punctuation(UInt8)
            case literal
            case newline
        }

        /// A name waiting for what follows it: `, b: Int` declares `b`,
        /// `Dictionary<A, B>` doesn't.
        private struct Candidate {
            let name: String
            let line: Int
            let collecting: Bool
        }

        private enum Expect {
            case nothing
            /// After `func`, `struct`, `enum`, `protocol`, `typealias`.
            case name(Symbol.Kind)
            /// After `class` or `actor` at a statement's start: a type's
            /// name, unless a keyword follows (`class func`).
            case typeName
            /// After `extension`: the type, dotted names included.
            case extended(path: String, needsName: Bool)
            /// After `let` or `var`: a name or a tuple pattern.
            case binding
            /// In `let (a, (b, c))`, opened at `depth`.
            case tuple(depth: Int, candidate: Candidate?)
            /// After a binding, `, name:` or `, name =` declares another.
            case moreBindings
            case nextBinding([Candidate])
            case candidates([Candidate])
            /// After `case`, names separated by commas.
            case caseName
            case caseRest
        }

        /// What the statement under way has said so far.
        private struct Statement {
            /// Parentheses and brackets open in it.
            var depth = 0
            /// Only modifiers and attributes so far.
            var atStart = true
            /// The last token is a comma, or a condition's keyword: the
            /// line after it goes on with it (`guard let a = x,` then
            /// `let b = y`).
            var continues = false
            var isPrivate = false
            var isOverride = false
            var isObjC = false
            var expect = Expect.nothing
        }

        private struct Scope {
            /// In a function's, a closure's or an accessor's body, at any
            /// depth: nothing declared there is listed.
            let isLocal: Bool
            let isPrivate: Bool
            /// The type whose body it is, or that its extension extends,
            /// as a dotted path.
            let container: String?
            /// An extension's type at the file's level, as written.
            let extended: String?
            /// The statement the brace opened in, which goes on once it
            /// closes: `let a = { 1 }(), b = 2`.
            let outer: Statement
        }

        /// In an attribute: after `@` or a `.` (`@SwiftUI.State`), after
        /// its name, or in its generic arguments (`@Clamped<Int>`), right
        /// after a `-` there: `->` closes nothing.
        private enum Attribute {
            case name
            case afterName
            case generic(depth: Int, afterDash: Bool)
        }

        private var scopes: [Scope] = []
        private var statement = Statement()
        /// `private` just read: unless `(set)` follows.
        private var pendingPrivate = false
        /// A modifier just read: a parenthesis is its arguments.
        private var mayTakeArguments = false
        private var argumentDepth = 0
        private var attribute: Attribute?
        /// What the next `{` opens: a type's body (or an extension's), or
        /// a function's. Set by the type's name, cleared by the brace.
        private var introducesType = false
        private var typeIsPrivate = false
        private var pendingContainer: String?
        private var pendingExtended: String?

        private static let modifiers: Set<String> = [
            "public", "internal", "open", "package", "static", "final", "override", "required", "convenience",
            "mutating", "nonmutating", "lazy", "weak", "unowned", "optional", "dynamic", "indirect", "nonisolated",
            "distributed", "prefix", "postfix", "infix", "consuming", "borrowing", "isolated"
        ]
        private static let keywords: Set<String> = modifiers.union([
            "private", "fileprivate", "func", "var", "let", "class", "struct", "enum", "case", "protocol", "typealias",
            "actor", "extension", "init", "deinit", "subscript"
        ])
        private static let conditions: Set<String> = ["if", "guard", "while"]

        // MARK: Lexer

        /// Reads one line, without its newline.
        mutating func feed(_ line: UnsafeRawBufferPointer, collecting: Bool) {
            lineNumber += 1
            self.collecting = collecting
            var line = line
            // A byte order mark would read as the start of an identifier.
            if lineNumber == 1, line.starts(with: [0xEF, 0xBB, 0xBF]) {
                line = UnsafeRawBufferPointer(rebasing: line.dropFirst(3))
            }
            var index = 0
            while index < line.count {
                switch modes.last {
                case .string(let hashes, let isMultiline)?:
                    index = scanString(line, from: index, hashes: hashes, isMultiline: isMultiline)
                case .blockComment?:
                    index = scanBlockComment(line, from: index)
                case .regex(let hashes)?:
                    index = scanRegex(line, from: index, hashes: hashes)
                case nil, .interpolation?:
                    index = scanCode(line, from: index)
                }
            }
            // A single-line string ends with its line, and what it holds.
            if let open = modes.firstIndex(where: { if case .string(_, false) = $0 { return true } else { return false } }) {
                modes.removeSubrange(open...)
            }
            take(.newline)
        }

        private mutating func scanCode(_ line: UnsafeRawBufferPointer, from start: Int) -> Int {
            let byte = line[start]
            let next = start + 1 < line.count ? line[start + 1] : 0
            switch byte {
            case 0x20, 0x09, 0x0D, 0x0B, 0x0C:
                return start + 1
            case UInt8(ascii: "/") where next == UInt8(ascii: "/"):
                return line.count
            case UInt8(ascii: "/") where next == UInt8(ascii: "*"):
                modes.append(.blockComment(depth: 1))
                return start + 2
            case UInt8(ascii: "\""), UInt8(ascii: "#"):
                return scanDelimiter(line, from: start)
            case UInt8(ascii: "`"):
                guard let close = line[(start + 1)...].firstIndex(of: UInt8(ascii: "`")) else {
                    take(.punctuation(byte))
                    return start + 1
                }
                let name = UnsafeRawBufferPointer(rebasing: line[(start + 1)..<close])
                words?.remove(name)
                take(.identifier(name, isEscaped: true))
                return close + 1
            case UInt8(ascii: "("), UInt8(ascii: ")"):
                if case .interpolation(let open)? = modes.last {
                    let count = open + (byte == UInt8(ascii: "(") ? 1 : -1)
                    modes[modes.count - 1] = .interpolation(parentheses: count)
                    if count == 0 { modes.removeLast() }
                    return start + 1
                }
                take(.punctuation(byte))
                return start + 1
            default:
                // A number reads as an identifier: no declaration takes one.
                guard RiskRules.isIdentifier(byte) else {
                    take(.punctuation(byte))
                    return start + 1
                }
                var end = start + 1
                while end < line.count, RiskRules.isIdentifier(line[end]) { end += 1 }
                let name = UnsafeRawBufferPointer(rebasing: line[start..<end])
                words?.remove(name)
                take(.identifier(name, isEscaped: false))
                return end
            }
        }

        /// A string's or a regex's opening delimiter, with its `#`s, or a
        /// `#` that starts `#if` or `#selector`.
        private mutating func scanDelimiter(_ line: UnsafeRawBufferPointer, from start: Int) -> Int {
            var end = start
            while end < line.count, line[end] == UInt8(ascii: "#") { end += 1 }
            let hashes = end - start
            if end < line.count, line[end] == UInt8(ascii: "\"") {
                let isMultiline = end + 2 < line.count
                    && line[end + 1] == UInt8(ascii: "\"") && line[end + 2] == UInt8(ascii: "\"")
                take(.literal)
                modes.append(.string(hashes: hashes, isMultiline: isMultiline))
                return end + (isMultiline ? 3 : 1)
            }
            if hashes > 0, end < line.count, line[end] == UInt8(ascii: "/") {
                take(.literal)
                modes.append(.regex(hashes: hashes))
                return end + 1
            }
            take(.punctuation(line[start]))
            return start + 1
        }

        /// `\` then as many `#` as the string's delimiter escapes a
        /// character, or opens an interpolation with `(`.
        private mutating func scanString(_ line: UnsafeRawBufferPointer, from start: Int, hashes: Int, isMultiline: Bool) -> Int {
            var index = start
            while index < line.count {
                switch line[index] {
                case UInt8(ascii: "\\"):
                    guard hasHashes(line, at: index + 1, hashes), index + 1 + hashes < line.count else {
                        index += 1
                        continue
                    }
                    let escaped = index + 1 + hashes
                    if line[escaped] == UInt8(ascii: "(") {
                        modes.append(.interpolation(parentheses: 1))
                        return escaped + 1
                    }
                    index = escaped + 1
                case UInt8(ascii: "\""):
                    let quotes = isMultiline ? 3 : 1
                    let closes = index + quotes <= line.count
                        && line[index..<(index + quotes)].allSatisfy { $0 == UInt8(ascii: "\"") }
                        && hasHashes(line, at: index + quotes, hashes)
                    guard closes else {
                        index += 1
                        continue
                    }
                    modes.removeLast()
                    return index + quotes + hashes
                default:
                    index += 1
                }
            }
            return index
        }

        private mutating func scanBlockComment(_ line: UnsafeRawBufferPointer, from start: Int) -> Int {
            guard case .blockComment(var depth)? = modes.last else { return line.count }
            var index = start
            while index + 1 < line.count {
                if line[index] == UInt8(ascii: "/"), line[index + 1] == UInt8(ascii: "*") {
                    depth += 1
                } else if line[index] == UInt8(ascii: "*"), line[index + 1] == UInt8(ascii: "/") {
                    depth -= 1
                    if depth == 0 {
                        modes.removeLast()
                        return index + 2
                    }
                } else {
                    index += 1
                    continue
                }
                modes[modes.count - 1] = .blockComment(depth: depth)
                index += 2
            }
            return line.count
        }

        private mutating func scanRegex(_ line: UnsafeRawBufferPointer, from start: Int, hashes: Int) -> Int {
            var index = start
            while index < line.count {
                if line[index] == UInt8(ascii: "\\") {
                    index += 2
                } else if line[index] == UInt8(ascii: "/"), hasHashes(line, at: index + 1, hashes) {
                    modes.removeLast()
                    return index + 1 + hashes
                } else {
                    index += 1
                }
            }
            return line.count
        }

        private func hasHashes(_ line: UnsafeRawBufferPointer, at start: Int, _ count: Int) -> Bool {
            start + count <= line.count && line[start..<(start + count)].allSatisfy { $0 == UInt8(ascii: "#") }
        }

    }
}

// MARK: - Parser

extension BranchReview.SwiftScanner {
    /// Code inside a string's interpolation is an expression: only
    /// the code around strings is parsed.
    private mutating func take(_ token: Token) {
        guard modes.isEmpty else { return }
        if scopes.last?.isLocal == true {
            if case .punctuation(let byte) = token {
                if byte == UInt8(ascii: "{") { open(local: true) }
                if byte == UInt8(ascii: "}") { close() }
            }
            return
        }
        if takesAttribute(token) || takesExtendedType(token) { return }
        if pendingPrivate {
            pendingPrivate = false
            statement.isPrivate = true
        }
        switch token {
        case .newline:
            if statement.depth == 0, !statement.continues, !statement.atStart { startStatement() }
        case .identifier(let bytes, let isEscaped):
            identifier(String(decoding: bytes, as: UTF8.self), isEscaped: isEscaped)
        case .punctuation(let byte):
            punctuation(byte)
        case .literal:
            other()
        }
    }

    /// Whether `token` is part of an attribute (`@objc(name:)`) or of a
    /// modifier's arguments (`private(set)`).
    private mutating func takesAttribute(_ token: Token) -> Bool {
        if argumentDepth > 0 {
            if case .punctuation(let byte) = token {
                if byte == UInt8(ascii: "(") { argumentDepth += 1 }
                if byte == UInt8(ascii: ")") { argumentDepth -= 1 }
            }
            return true
        }
        switch (attribute, token) {
        case (.name?, .identifier(let bytes, _)):
            // Methods the runtime calls, through a selector or an action.
            if ["objc", "IBAction"].contains(String(decoding: bytes, as: UTF8.self)) { statement.isObjC = true }
            attribute = .afterName
            return true
        case (.afterName?, .punctuation(UInt8(ascii: "."))):
            attribute = .name
            return true
        case (.afterName?, .punctuation(UInt8(ascii: "<"))):
            attribute = .generic(depth: 1, afterDash: false)
            return true
        case (.afterName?, .punctuation(UInt8(ascii: "("))):
            attribute = nil
            argumentDepth = 1
            return true
        case (.generic(let depth, let afterDash)?, _):
            attribute = Self.generic(after: token, depth: depth, afterDash: afterDash)
            return true
        default:
            attribute = nil
        }
        if mayTakeArguments {
            mayTakeArguments = false
            if case .punctuation(UInt8(ascii: "(")) = token {
                // `private(set)` restricts the setter only.
                pendingPrivate = false
                argumentDepth = 1
                return true
            }
        }
        return false
    }

    /// Where a token leaves an attribute's generic arguments.
    private static func generic(after token: Token, depth: Int, afterDash: Bool) -> Attribute {
        guard case .punctuation(let byte) = token else { return .generic(depth: depth, afterDash: false) }
        switch byte {
        case UInt8(ascii: "<"): return .generic(depth: depth + 1, afterDash: false)
        case UInt8(ascii: ">") where !afterDash: return depth == 1 ? .afterName : .generic(depth: depth - 1, afterDash: false)
        default: return .generic(depth: depth, afterDash: byte == UInt8(ascii: "-"))
        }
    }

    /// Whether `token` is part of an extension's type; the first token
    /// that isn't settles it (`:`, `where`, `{`, a newline).
    private mutating func takesExtendedType(_ token: Token) -> Bool {
        guard case .extended(let path, let needsName) = statement.expect else { return false }
        switch token {
        case .identifier(let bytes, _) where needsName:
            statement.expect = .extended(path: path + String(decoding: bytes, as: UTF8.self), needsName: false)
            return true
        case .punctuation(UInt8(ascii: ".")) where !needsName:
            statement.expect = .extended(path: path + ".", needsName: true)
            return true
        default:
            statement.expect = .nothing
            introduceType(container: path, extended: path)
            return false
        }
    }

    private mutating func identifier(_ name: String, isEscaped: Bool) {
        if case .typeName = statement.expect {
            statement.expect = .nothing
            guard !isEscaped, Self.keywords.contains(name) else {
                declareType(name)
                other()
                return
            }
            // `class func`, `class override var`: a modifier.
        }
        if statement.atStart, keyword(name) { return }
        let candidate = Candidate(name: name, line: lineNumber, collecting: collecting)
        switch statement.expect {
        case .name(.type):
            declareType(name)
            statement.expect = .nothing
        case .name(let kind):
            record(candidate, kind)
            statement.expect = .nothing
        case .binding:
            record(candidate, .variable)
            statement.expect = .moreBindings
        case .tuple(let open, _):
            statement.expect = .tuple(depth: open, candidate: candidate)
            statement.atStart = false
            statement.continues = false
            return
        case .nextBinding(let waiting):
            statement.expect = .candidates(waiting + [candidate])
            statement.atStart = false
            statement.continues = false
            return
        case .caseName:
            record(candidate, .enumCase)
            statement.expect = .caseRest
        default:
            break
        }
        other()
        // `guard`, then `let` on the next line: one statement.
        statement.continues = !isEscaped && Self.conditions.contains(name)
    }

    /// Whether `name` is a modifier or starts a declaration.
    private mutating func keyword(_ name: String) -> Bool {
        switch name {
        case "private", "fileprivate":
            pendingPrivate = true
            mayTakeArguments = true
            return true
        case "override":
            statement.isOverride = true
            return true
        case "class", "actor":
            // Still at the statement's start: `class func`.
            statement.expect = .typeName
            return true
        case "func":
            begin(.name(.function))
        case "typealias":
            begin(.name(.typeAlias))
        case "struct", "enum", "protocol":
            begin(.name(.type))
        case "extension":
            begin(.extended(path: "", needsName: true))
        case "var", "let":
            begin(.binding)
        case "case":
            begin(.caseName)
        default:
            guard Self.modifiers.contains(name) else { return false }
            mayTakeArguments = true
            return true
        }
        return true
    }

    private mutating func begin(_ expecting: Expect) {
        statement.expect = expecting
        statement.atStart = false
        statement.continues = false
    }

    private mutating func declareType(_ name: String) {
        record(Candidate(name: name, line: lineNumber, collecting: collecting), .type)
        let path = scopes.last?.container.map { $0 + "." + name } ?? name
        if statement.isPrivate { privateTypes.insert(path) }
        introduceType(container: path, extended: nil)
    }

    private mutating func introduceType(container: String?, extended: String?) {
        introducesType = true
        typeIsPrivate = statement.isPrivate
        pendingContainer = container
        pendingExtended = scopes.isEmpty ? extended : nil
    }

    private mutating func punctuation(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "{"):
            open(local: !introducesType)
            return
        case UInt8(ascii: "}"):
            close()
            return
        case UInt8(ascii: ";"):
            startStatement()
            return
        case UInt8(ascii: "@"):
            attribute = .name
            return
        case UInt8(ascii: "("), UInt8(ascii: "["):
            statement.depth += 1
        case UInt8(ascii: ")"), UInt8(ascii: "]"):
            statement.depth = max(0, statement.depth - 1)
        default:
            break
        }
        advance(after: byte)
        statement.atStart = false
        statement.continues = byte == UInt8(ascii: ",")
    }

    /// Where a punctuation leaves the names a declaration lists.
    private mutating func advance(after byte: UInt8) {
        let depth = statement.depth
        switch statement.expect {
        case .binding where byte == UInt8(ascii: "("):
            statement.expect = .tuple(depth: depth, candidate: nil)
        case .tuple(let open, let candidate):
            if byte == UInt8(ascii: ",") || byte == UInt8(ascii: ")"), let candidate { record(candidate, .variable) }
            statement.expect = depth < open ? .moreBindings : .tuple(depth: open, candidate: nil)
        case .moreBindings where byte == UInt8(ascii: ",") && depth == 0:
            statement.expect = .nextBinding([])
        case .candidates(let waiting) where depth == 0 && byte == UInt8(ascii: ","):
            statement.expect = .nextBinding(waiting)
        case .candidates(let waiting):
            if byte == UInt8(ascii: ":") || byte == UInt8(ascii: "=") {
                for candidate in waiting { record(candidate, .variable) }
            }
            statement.expect = .moreBindings
        case .caseRest where byte == UInt8(ascii: ",") && depth == 0:
            statement.expect = .caseName
        case .name, .typeName, .binding, .nextBinding, .caseName:
            statement.expect = .nothing
        default:
            break
        }
    }

    /// Any other token: a statement under way.
    private mutating func other() {
        statement.atStart = false
        statement.continues = false
    }

    private mutating func startStatement() {
        statement = Statement()
        pendingPrivate = false
        mayTakeArguments = false
        attribute = nil
    }

    private mutating func open(local: Bool) {
        let parent = scopes.last
        scopes.append(Scope(
            isLocal: local,
            isPrivate: parent?.isPrivate == true || (!local && typeIsPrivate),
            container: local ? nil : pendingContainer,
            extended: local ? nil : pendingExtended,
            outer: statement
        ))
        introducesType = false
        startStatement()
    }

    private mutating func close() {
        guard let scope = scopes.popLast() else {
            closedUnopened = true
            return
        }
        statement = scope.outer
    }

    private mutating func record(_ candidate: Candidate, _ kind: BranchReview.Symbol.Kind) {
        // A name with other characters (`` `does something` ``) can't be
        // found as a word.
        guard candidate.name != "_", candidate.name.utf8.allSatisfy(BranchReview.RiskRules.isIdentifier) else { return }
        let isHidden = statement.isPrivate || statement.isOverride || (kind == .function && statement.isObjC)
            || scopes.last?.isPrivate == true
        declarations.append(BranchReview.Declaration(
            symbol: BranchReview.Symbol(name: candidate.name, line: candidate.line, kind: kind, container: scopes.last?.container),
            isHidden: isHidden, extended: scopes.first?.extended, isCollected: candidate.collecting
        ))
    }
}

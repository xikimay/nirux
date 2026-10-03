import Foundation

// MARK: - Swift scanner

extension BranchReview {
    /// Reads Swift source a line at a time and collects what it declares
    /// outside any function body: a name after `func`, `var`, `let`,
    /// `class`, `struct`, `enum`, `case`, `protocol`, `typealias` or
    /// `actor`, at the file's level or in a type's or an extension's
    /// body. Strings (multi-line and raw ones, interpolations included)
    /// and comments (nested ones included) are skipped; braces tell the
    /// bodies apart. Not `private` or `fileprivate` ones, nor those of a
    /// private type or extension: private members are tested through the
    /// API that uses them. Nor an `override`, whose name is its
    /// superclass's: tests reach it through the API that calls it. Known
    /// limits: a bare `/regex/` literal reads as code, and `#if` branches
    /// that open a brace each read as two.
    struct SwiftScanner {
        /// Declared on the lines fed with `collecting`, in order.
        private(set) var symbols: [Symbol] = []
        private var lineNumber = 0
        private var collecting = false

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

        private struct Scope {
            /// In a function's, a closure's or an accessor's body, at any
            /// depth: nothing declared there is listed.
            let isLocal: Bool
            let isPrivate: Bool
            /// The parentheses and brackets open where it starts.
            let outerDepth: Int
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
            case name
            /// After `class` or `actor` at a statement's start: a type's
            /// name, unless a keyword follows (`class func`).
            case typeName
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

        private var scopes: [Scope] = []
        /// Parentheses and brackets open in the current scope.
        private var depth = 0
        /// Only modifiers and attributes since the last statement ended.
        private var atStatementStart = true
        /// The last token can't end a statement: a newline after it
        /// doesn't either.
        private var previousContinues = false
        private var isPrivate = false
        private var isOverride = false
        /// `private` just read: unless `(set)` follows.
        private var pendingPrivate = false
        /// A modifier or an attribute just read: a parenthesis is its
        /// arguments.
        private var mayTakeArguments = false
        private var argumentDepth = 0
        private var afterAt = false
        /// What the next `{` opens: a type's body, or a function's.
        private var introducesType = false
        private var typeIsPrivate = false
        private var expect = Expect.nothing

        private static let modifiers: Set<String> = [
            "public", "internal", "open", "package", "static", "final", "override", "required", "convenience",
            "mutating", "nonmutating", "lazy", "weak", "unowned", "optional", "dynamic", "indirect", "nonisolated",
            "distributed", "prefix", "postfix", "infix", "consuming", "borrowing", "isolated"
        ]
        private static let keywords: Set<String> = modifiers.union([
            "private", "fileprivate", "func", "var", "let", "class", "struct", "enum", "case", "protocol", "typealias",
            "actor", "extension", "init", "deinit", "subscript"
        ])
        /// Tokens a statement can't end with.
        private static let continuing: Set<UInt8> = Set(",([=:.&|+-*/%^<~".utf8)

        // MARK: Lexer

        /// Reads one line, without its newline.
        mutating func feed(_ line: UnsafeRawBufferPointer, collecting: Bool) {
            lineNumber += 1
            self.collecting = collecting
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
                // `#if`, `#selector`: the name follows.
                take(.punctuation(byte))
                return start + 1
            case UInt8(ascii: "`"):
                guard let close = line[(start + 1)...].firstIndex(of: UInt8(ascii: "`")) else {
                    take(.punctuation(byte))
                    return start + 1
                }
                take(.identifier(UnsafeRawBufferPointer(rebasing: line[(start + 1)..<close]), isEscaped: true))
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
                guard RiskRules.isIdentifier(byte) || byte == UInt8(ascii: "$") else {
                    take(.punctuation(byte))
                    return start + 1
                }
                var end = start + 1
                while end < line.count, RiskRules.isIdentifier(line[end]) || line[end] == UInt8(ascii: "$") { end += 1 }
                let isNumber = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                take(isNumber ? .literal : .identifier(UnsafeRawBufferPointer(rebasing: line[start..<end]), isEscaped: false))
                return end
            }
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

        // MARK: Parser

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
            if takesAttribute(token) { return }
            if pendingPrivate {
                pendingPrivate = false
                isPrivate = true
            }
            switch token {
            case .newline:
                if depth == 0, !previousContinues, !atStatementStart { startStatement() }
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
            if afterAt {
                afterAt = false
                if case .identifier = token {
                    mayTakeArguments = true
                    return true
                }
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

        private mutating func identifier(_ name: String, isEscaped: Bool) {
            if case .typeName = expect {
                expect = .nothing
                guard !isEscaped, Self.keywords.contains(name) else {
                    record(name)
                    introduceType()
                    other()
                    return
                }
                // `class func`, `class override var`: a modifier.
            }
            if !isEscaped, atStatementStart, depth == 0, keyword(name) { return }
            let candidate = Candidate(name: name, line: lineNumber, collecting: collecting)
            switch expect {
            case .name:
                record(name)
                expect = .nothing
            case .binding:
                record(name)
                expect = .moreBindings
            case .tuple(let open, _):
                expect = .tuple(depth: open, candidate: candidate)
                atStatementStart = false
                previousContinues = false
                return
            case .nextBinding(let waiting):
                expect = .candidates(waiting + [candidate])
                atStatementStart = false
                previousContinues = false
                return
            case .caseName:
                record(name)
                expect = .caseRest
            default:
                break
            }
            other()
        }

        /// Whether `name` is a modifier or starts a declaration.
        private mutating func keyword(_ name: String) -> Bool {
            switch name {
            case "private", "fileprivate":
                pendingPrivate = true
                mayTakeArguments = true
                return true
            case "override":
                isOverride = true
                return true
            case "class", "actor":
                // Still at the statement's start: `class func`.
                expect = .typeName
                return true
            case "func", "typealias":
                begin(.name)
            case "struct", "enum", "protocol":
                begin(.name)
                introduceType()
            case "extension":
                begin(.nothing)
                introduceType()
            case "var", "let":
                begin(.binding)
            case "case":
                begin(.caseName)
            case "init", "deinit", "subscript":
                begin(.nothing)
            default:
                guard Self.modifiers.contains(name) else { return false }
                mayTakeArguments = true
                return true
            }
            return true
        }

        private mutating func begin(_ expecting: Expect) {
            expect = expecting
            introducesType = false
            atStatementStart = false
            previousContinues = false
        }

        private mutating func introduceType() {
            introducesType = true
            typeIsPrivate = isPrivate
        }

        private mutating func punctuation(_ byte: UInt8) {
            switch byte {
            case UInt8(ascii: "{"):
                open(local: depth > 0 || !introducesType)
                return
            case UInt8(ascii: "}"):
                close()
                return
            case UInt8(ascii: ";"):
                introducesType = false
                startStatement()
                return
            case UInt8(ascii: "@"):
                afterAt = true
                return
            case UInt8(ascii: "("), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"):
                depth = max(0, depth - 1)
            default:
                break
            }
            advance(after: byte)
            atStatementStart = false
            previousContinues = Self.continuing.contains(byte)
        }

        /// Where a punctuation leaves the names a declaration lists.
        private mutating func advance(after byte: UInt8) {
            switch expect {
            case .binding where byte == UInt8(ascii: "("):
                expect = .tuple(depth: depth, candidate: nil)
            case .tuple(let open, let candidate):
                if byte == UInt8(ascii: ",") || byte == UInt8(ascii: ")"), let candidate { record(candidate) }
                expect = depth < open ? .moreBindings : .tuple(depth: open, candidate: nil)
            case .moreBindings where byte == UInt8(ascii: ",") && depth == 0:
                expect = .nextBinding([])
            case .candidates(let waiting) where depth == 0 && byte == UInt8(ascii: ","):
                expect = .nextBinding(waiting)
            case .candidates(let waiting):
                if byte == UInt8(ascii: ":") || byte == UInt8(ascii: "=") {
                    for candidate in waiting { record(candidate) }
                }
                expect = .moreBindings
            case .caseRest where byte == UInt8(ascii: ",") && depth == 0:
                expect = .caseName
            case .name, .typeName, .binding, .nextBinding, .caseName:
                expect = .nothing
            default:
                break
            }
        }

        /// Any other token: a statement under way.
        private mutating func other() {
            switch expect {
            case .tuple(let open, _): expect = .tuple(depth: open, candidate: nil)
            case .nextBinding, .candidates: expect = .moreBindings
            case .name, .typeName, .binding, .caseName: expect = .nothing
            default: break
            }
            atStatementStart = false
            previousContinues = false
        }

        private mutating func startStatement() {
            atStatementStart = true
            previousContinues = false
            isPrivate = false
            isOverride = false
            pendingPrivate = false
            mayTakeArguments = false
            afterAt = false
            expect = .nothing
        }

        private mutating func open(local: Bool) {
            let parent = scopes.last
            scopes.append(Scope(
                isLocal: local || parent?.isLocal == true,
                isPrivate: parent?.isPrivate == true || (!local && typeIsPrivate),
                outerDepth: depth
            ))
            depth = 0
            introducesType = false
            startStatement()
        }

        private mutating func close() {
            guard let scope = scopes.popLast() else { return }
            depth = scope.outerDepth
            introducesType = false
            startStatement()
            atStatementStart = false
        }

        private mutating func record(_ name: String) {
            record(Candidate(name: name, line: lineNumber, collecting: collecting))
        }

        private mutating func record(_ candidate: Candidate) {
            guard candidate.collecting, candidate.name != "_", !isPrivate, !isOverride, scopes.last?.isPrivate != true
            else { return }
            symbols.append(Symbol(name: candidate.name, line: candidate.line))
        }
    }
}

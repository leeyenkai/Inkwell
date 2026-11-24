import Foundation
import InkwellMarkdown

/// The part of Liquid that Jekyll themes and personal sites use: output with filters, if/elsif/else, unless,
/// case/when, for (reversed, limit, offset, forloop), assign, capture, increment, raw, comment and include.
/// Tags it does not know render as nothing and are listed in `unsupportedTags`.
public final class LiquidTemplate: @unchecked Sendable {
    let nodes: [Node]
    public let unsupportedTags: [String]

    public init(_ source: String) {
        var parser = Parser(tokens: Lexer.tokens(source))
        nodes = parser.parseNodes(until: [])
        unsupportedTags = parser.unsupported
    }

    public func render(_ context: LiquidContext) -> String {
        var out = ""
        _ = context.render(nodes, into: &out)
        return out
    }

    // MARK: Tokens

    enum Token {
        case text(String)
        case output(String)
        case tag(String)
    }

    enum Lexer {
        static func tokens(_ source: String) -> [Token] {
            var tokens: [Token] = []
            var rest = Substring(source)
            var trimNextLeading = false
            while !rest.isEmpty {
                let outputRange = rest.range(of: "{{"), tagRange = rest.range(of: "{%")
                let open: (Range<Substring.Index>, Bool)
                switch (outputRange, tagRange) {
                case let (o?, t?): open = o.lowerBound < t.lowerBound ? (o, true) : (t, false)
                case let (o?, nil): open = (o, true)
                case let (nil, t?): open = (t, false)
                case (nil, nil):
                    appendText(String(rest), trimLeading: trimNextLeading, trimTrailing: false, to: &tokens)
                    return tokens
                }
                let (openRange, isOutput) = open
                let closeMarker = isOutput ? "}}" : "%}"
                guard let close = rest[openRange.upperBound...].range(of: closeMarker) else {
                    appendText(String(rest), trimLeading: trimNextLeading, trimTrailing: false, to: &tokens)
                    break
                }
                var inner = String(rest[openRange.upperBound ..< close.lowerBound])
                let trimLeft = inner.hasPrefix("-")
                let trimRight = inner.hasSuffix("-")
                if trimLeft { inner.removeFirst() }
                if trimRight { inner.removeLast() }
                appendText(String(rest[..<openRange.lowerBound]), trimLeading: trimNextLeading, trimTrailing: trimLeft, to: &tokens)
                trimNextLeading = trimRight
                inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                rest = rest[close.upperBound...]
                if isOutput {
                    tokens.append(.output(inner))
                } else if inner == "raw" || inner == "comment" {
                    let end = inner == "raw" ? "endraw" : "endcomment"
                    if let endRange = rest.range(of: "\\{%-?\\s*\(end)\\s*-?%\\}", options: .regularExpression) {
                        if inner == "raw" { tokens.append(.text(String(rest[..<endRange.lowerBound]))) }
                        rest = rest[endRange.upperBound...]
                    } else {
                        rest = ""
                    }
                } else {
                    tokens.append(.tag(inner))
                }
            }
            return tokens
        }

        static func appendText(_ text: String, trimLeading: Bool, trimTrailing: Bool, to tokens: inout [Token]) {
            var t = Substring(text)
            if trimLeading { t = t.drop { $0.isWhitespace } }
            if trimTrailing { while let last = t.last, last.isWhitespace { t = t.dropLast() } }
            if !t.isEmpty { tokens.append(.text(String(t))) }
        }
    }

    // MARK: Nodes

    indirect enum Node {
        case text(String)
        case output(Expression)
        case conditional([(Condition?, [Node])])
        case caseWhen(Expression, [([Expression], [Node])], [Node])
        case loop(variable: String, collection: Expression, reversed: Bool, limit: Expression?, offset: Expression?, body: [Node], empty: [Node])
        case assign(String, Expression)
        case capture(String, [Node])
        case increment(String, Int)
        case include(Expression, [(String, Expression)])
        case control(String)
        case seo
    }

    struct Parser {
        var tokens: [Token]
        var index = 0
        var unsupported: [String] = []

        mutating func parseNodes(until ends: Set<String>) -> [Node] {
            var nodes: [Node] = []
            while index < tokens.count {
                let token = tokens[index]
                switch token {
                case let .text(t):
                    nodes.append(.text(t))
                    index += 1
                case let .output(source):
                    nodes.append(.output(Expression(source)))
                    index += 1
                case let .tag(source):
                    let name = String(source.prefix { !$0.isWhitespace })
                    if ends.contains(name) { return nodes }
                    index += 1
                    nodes.append(contentsOf: parseTag(name: name, args: String(source.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)))
                }
            }
            return nodes
        }

        mutating func currentTagName() -> String? {
            guard index < tokens.count, case let .tag(source) = tokens[index] else { return nil }
            return String(source.prefix { !$0.isWhitespace })
        }

        mutating func currentTagArgs() -> String {
            guard index < tokens.count, case let .tag(source) = tokens[index] else { return "" }
            let name = source.prefix { !$0.isWhitespace }
            return String(source.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
        }

        mutating func parseTag(name: String, args: String) -> [Node] {
            switch name {
            case "if", "unless":
                var branches: [(Condition?, [Node])] = []
                var condition = Condition(args)
                if name == "unless" { condition = Condition(negating: condition) }
                var body = parseNodes(until: ["elsif", "else", "endif", "endunless"])
                branches.append((condition, body))
                while let tag = currentTagName() {
                    let tagArgs = currentTagArgs()
                    index += 1
                    if tag == "elsif" {
                        body = parseNodes(until: ["elsif", "else", "endif", "endunless"])
                        branches.append((Condition(tagArgs), body))
                    } else if tag == "else" {
                        body = parseNodes(until: ["endif", "endunless"])
                        branches.append((nil, body))
                    } else {
                        break
                    }
                }
                return [.conditional(branches)]
            case "case":
                let subject = Expression(args)
                _ = parseNodes(until: ["when", "else", "endcase"])
                var whens: [([Expression], [Node])] = []
                var elseBody: [Node] = []
                while let tag = currentTagName() {
                    let tagArgs = currentTagArgs()
                    index += 1
                    if tag == "when" {
                        let values = tagArgs.components(separatedBy: CharacterSet(charactersIn: ",")).flatMap { $0.components(separatedBy: " or ") }
                            .map { Expression($0.trimmingCharacters(in: .whitespaces)) }
                        whens.append((values, parseNodes(until: ["when", "else", "endcase"])))
                    } else if tag == "else" {
                        elseBody = parseNodes(until: ["endcase"])
                    } else {
                        break
                    }
                }
                return [.caseWhen(subject, whens, elseBody)]
            case "for":
                let parts = args.components(separatedBy: " in ")
                let variable = parts.first?.trimmingCharacters(in: .whitespaces) ?? "item"
                var rest = parts.dropFirst().joined(separator: " in ")
                var reversed = false
                var limit: Expression?
                var offset: Expression?
                if let r = rest.range(of: #"\s+reversed\b"#, options: .regularExpression) {
                    reversed = true
                    rest.removeSubrange(r)
                }
                for key in ["limit", "offset"] {
                    if let r = rest.range(of: "\\s*\(key)\\s*:\\s*([^\\s]+)", options: .regularExpression) {
                        let value = rest[r].components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                        if key == "limit" { limit = Expression(value) } else { offset = Expression(value) }
                        rest.removeSubrange(r)
                    }
                }
                let body = parseNodes(until: ["else", "endfor"])
                var empty: [Node] = []
                if currentTagName() == "else" {
                    index += 1
                    empty = parseNodes(until: ["endfor"])
                }
                if currentTagName() == "endfor" { index += 1 }
                return [.loop(variable: variable, collection: Expression(rest.trimmingCharacters(in: .whitespaces)), reversed: reversed,
                              limit: limit, offset: offset, body: body, empty: empty)]
            case "assign":
                guard let eq = args.firstIndex(of: "=") else { return [] }
                let target = args[..<eq].trimmingCharacters(in: .whitespaces)
                return [.assign(target, Expression(String(args[args.index(after: eq)...])))]
            case "capture":
                let body = parseNodes(until: ["endcapture"])
                if currentTagName() == "endcapture" { index += 1 }
                return [.capture(args.trimmingCharacters(in: CharacterSet(charactersIn: "'\" ")), body)]
            case "increment": return [.increment(args, 1)]
            case "decrement": return [.increment(args, -1)]
            case "include", "include_relative":
                let parts = Expression.splitOutsideQuotes(args, separator: " ")
                guard let file = parts.first else { return [] }
                var params: [(String, Expression)] = []
                for part in parts.dropFirst() {
                    if let eq = part.firstIndex(of: "=") {
                        params.append((String(part[..<eq]), Expression(String(part[part.index(after: eq)...]))))
                    }
                }
                let quoted = file.hasPrefix("'") || file.hasPrefix("\"")
                let fileExpr = quoted && !file.contains("{{") ? Expression(file) : Expression("'\(file)'")
                return [.include(fileExpr, params)]
            case "break", "continue": return [.control(name)]
            case "seo": return [.seo]
            case "endif", "endunless", "endfor", "endcase", "endcapture", "else", "elsif", "when": return []
            default:
                if !unsupported.contains(name) { unsupported.append(name) }
                return []
            }
        }
    }
}

// MARK: Expressions

struct Expression {
    var base: String
    var filters: [(String, [String])]

    init(_ source: String) {
        let parts = Expression.splitOutsideQuotes(source, separator: "|")
        base = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
        filters = parts.dropFirst().map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { return (trimmed, []) }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let args = Expression.splitOutsideQuotes(String(trimmed[trimmed.index(after: colon)...]), separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return (name, args)
        }
    }

    static func splitOutsideQuotes(_ s: String, separator: Character) -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        for ch in s {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
            } else if ch == separator {
                if separator != " " || !current.isEmpty { parts.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty || separator != " " { parts.append(current) }
        return parts
    }
}

struct Condition {
    indirect enum Kind {
        case value(String)
        case comparison(String, String, String)
        case and(Condition, Condition)
        case or(Condition, Condition)
        case not(Condition)
    }

    var kind: Kind

    init(_ source: String) {
        let s = source.trimmingCharacters(in: .whitespaces)
        if let r = Condition.findOperator(" or ", in: s) {
            kind = .or(Condition(String(s[..<r.lowerBound])), Condition(String(s[r.upperBound...])))
            return
        }
        if let r = Condition.findOperator(" and ", in: s) {
            kind = .and(Condition(String(s[..<r.lowerBound])), Condition(String(s[r.upperBound...])))
            return
        }
        for op in ["==", "!=", "<>", ">=", "<=", ">", "<", " contains "] {
            if let r = Condition.findOperator(op, in: s) {
                kind = .comparison(String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), op.trimmingCharacters(in: .whitespaces),
                                   String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
                return
            }
        }
        kind = .value(s)
    }

    init(negating other: Condition) {
        kind = .not(other)
    }

    static func findOperator(_ op: String, in s: String) -> Range<String.Index>? {
        var quote: Character?
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if s[i...].hasPrefix(op) {
                return i ..< s.index(i, offsetBy: op.count)
            }
            i = s.index(after: i)
        }
        return nil
    }
}

// MARK: Context and evaluation

public final class LiquidContext: @unchecked Sendable {
    var scopes: [[String: LiquidValue]]
    var counters: [String: Int] = [:]
    public var site: LiquidValue = .null
    public var timeZone: TimeZone = .current
    public var includeLoader: (@Sendable (String) -> String?)?
    var includeDepth = 0
    var templateCache: [String: LiquidTemplate] = [:]

    public init(_ variables: [String: LiquidValue] = [:]) {
        scopes = [variables]
    }

    public subscript(name: String) -> LiquidValue {
        get {
            for scope in scopes.reversed() { if let v = scope[name] { return v } }
            return .null
        }
        set { scopes[scopes.count - 1][name] = newValue }
    }

    enum Flow { case normal, breakLoop, continueLoop }

    func render(_ nodes: [LiquidTemplate.Node], into out: inout String) -> Flow {
        for node in nodes {
            switch node {
            case let .text(t): out += t
            case let .output(expr): out += evaluate(expr).text
            case let .conditional(branches):
                for (condition, body) in branches where condition.map(test) ?? true {
                    let flow = render(body, into: &out)
                    if flow != .normal { return flow }
                    break
                }
            case let .caseWhen(subject, whens, elseBody):
                let value = evaluate(subject)
                var matched = false
                for (values, body) in whens where values.contains(where: { LiquidValue.equal(evaluate($0), value) }) {
                    matched = true
                    let flow = render(body, into: &out)
                    if flow != .normal { return flow }
                    break
                }
                if !matched {
                    let flow = render(elseBody, into: &out)
                    if flow != .normal { return flow }
                }
            case let .loop(variable, collection, reversed, limit, offset, body, empty):
                var items = evaluate(collection).asArray
                if let offset, let n = evaluate(offset).number { items = Array(items.dropFirst(Int(n))) }
                if let limit, let n = evaluate(limit).number { items = Array(items.prefix(Int(n))) }
                if reversed { items.reverse() }
                if items.isEmpty {
                    _ = render(empty, into: &out)
                    continue
                }
                scopes.append([:])
                for (i, item) in items.enumerated() {
                    self[variable] = item
                    self["forloop"] = .object([
                        "index": .int(i + 1), "index0": .int(i), "first": .bool(i == 0), "last": .bool(i == items.count - 1),
                        "length": .int(items.count), "rindex": .int(items.count - i), "rindex0": .int(items.count - i - 1),
                    ])
                    let flow = render(body, into: &out)
                    if flow == .breakLoop { break }
                }
                scopes.removeLast()
            case let .assign(name, expr):
                scopes[0][name] = evaluate(expr)
            case let .capture(name, body):
                var captured = ""
                _ = render(body, into: &captured)
                scopes[0][name] = .string(captured)
            case let .increment(name, step):
                let value = counters[name, default: 0]
                out += String(step > 0 ? value : value - 1)
                counters[name] = value + step
            case let .include(fileExpr, params):
                let file = evaluate(fileExpr).text
                guard includeDepth < 10, let source = includeLoader?(file) else { continue }
                let template = templateCache[file] ?? LiquidTemplate(source)
                templateCache[file] = template
                var include: [String: LiquidValue] = [:]
                for (key, expr) in params { include[key] = evaluate(expr) }
                scopes.append(["include": .object(include)])
                includeDepth += 1
                _ = render(template.nodes, into: &out)
                includeDepth -= 1
                scopes.removeLast()
            case let .control(name):
                return name == "break" ? .breakLoop : .continueLoop
            case .seo:
                let page = self["page"]
                let title = page["title"].isTruthy ? "\(page["title"].text) | \(site["title"].text)" : site["title"].text
                out += "<title>\(MarkdownRenderer.escape(title))</title>\n"
            }
        }
        return .normal
    }

    func test(_ condition: Condition) -> Bool {
        switch condition.kind {
        case let .value(s): return value(of: s).isTruthy
        case let .and(a, b): return test(a) && test(b)
        case let .or(a, b): return test(a) || test(b)
        case let .not(c): return !test(c)
        case let .comparison(l, op, r):
            let left = value(of: l), right = value(of: r)
            if r == "empty" || r == "blank" { return (op == "==") == left.isEmpty }
            switch op {
            case "==": return LiquidValue.equal(left, right)
            case "!=", "<>": return !LiquidValue.equal(left, right)
            case "contains":
                switch left {
                case let .string(s): return s.contains(right.text)
                case let .array(items): return items.contains { LiquidValue.equal($0, right) }
                case let .object(dict): return dict[right.text] != nil
                default: return false
                }
            default:
                guard let order = LiquidValue.compare(left, right) else { return false }
                switch op {
                case ">": return order == .orderedDescending
                case "<": return order == .orderedAscending
                case ">=": return order != .orderedAscending
                default: return order != .orderedDescending
                }
            }
        }
    }

    func evaluate(_ expr: Expression) -> LiquidValue {
        var value = value(of: expr.base)
        for (name, args) in expr.filters {
            value = LiquidFilters.apply(name, to: value, args: args.map { self.value(of: $0) }, rawArgs: args, context: self)
        }
        return value
    }

    func value(of source: String) -> LiquidValue {
        let s = source.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return .null }
        if let first = s.first, first == "'" || first == "\"", s.count >= 2, s.last == first {
            return .string(String(s.dropFirst().dropLast()))
        }
        if let i = Int(s) { return .int(i) }
        if let d = Double(s), s.first?.isNumber == true || s.first == "-" { return .double(d) }
        switch s {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "nil", "null": return .null
        case "empty", "blank": return .string("")
        default: break
        }
        if s.hasPrefix("("), s.hasSuffix(")"), let dots = s.range(of: "..") {
            let lo = value(of: String(s[s.index(after: s.startIndex) ..< dots.lowerBound])).number ?? 0
            let hi = value(of: String(s[dots.upperBound ..< s.index(before: s.endIndex)])).number ?? 0
            return lo <= hi ? .array((Int(lo) ... Int(hi)).map { .int($0) }) : .array([])
        }
        return lookup(path: s)
    }

    func lookup(path: String) -> LiquidValue {
        var segments: [String] = []
        var current = ""
        var i = path.startIndex
        while i < path.endIndex {
            let ch = path[i]
            if ch == "." {
                if !current.isEmpty { segments.append(current) }
                current = ""
            } else if ch == "[" {
                if !current.isEmpty { segments.append(current) }
                current = ""
                guard let close = path[i...].firstIndex(of: "]") else { break }
                let inner = String(path[path.index(after: i) ..< close])
                segments.append("\u{1}" + inner)
                i = close
            } else {
                current.append(ch)
            }
            i = path.index(after: i)
        }
        if !current.isEmpty { segments.append(current) }
        guard let first = segments.first else { return .null }
        var value: LiquidValue = first == "site" ? site : self[first]
        if first.hasPrefix("\u{1}") { return .null }
        for segment in segments.dropFirst() {
            if segment.hasPrefix("\u{1}") {
                let key = self.value(of: String(segment.dropFirst()))
                value = value[key.text]
            } else {
                value = value[segment]
            }
        }
        return value
    }
}

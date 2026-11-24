import Foundation

/// The YAML that static-site config and front matter actually use: block maps, block lists, scalars,
/// quoted strings, simple flow lists and block scalars. Anchors, tags and multi-document streams are out of scope.
public indirect enum YAMLValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([YAMLValue])
    case map([YAMLEntry])

    public subscript(key: String) -> YAMLValue? {
        guard case let .map(entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    public var string: String? {
        switch self {
        case let .string(s): s
        case let .int(i): String(i)
        case let .double(d): String(d)
        case let .bool(b): b ? "true" : "false"
        default: nil
        }
    }

    public var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    public var list: [YAMLValue]? {
        if case let .list(items) = self { return items }
        return nil
    }

    public var entries: [YAMLEntry]? {
        if case let .map(entries) = self { return entries }
        return nil
    }
}

public struct YAMLEntry: Sendable, Hashable {
    public var key: String
    public var value: YAMLValue

    public init(key: String, value: YAMLValue) {
        self.key = key
        self.value = value
    }
}

public enum YAML {
    public static func parse(_ text: String) -> YAMLValue {
        var lines: [Line] = []
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (number, line) in raw.enumerated() {
            let indent = line.prefix { $0 == " " }.count
            let content = String(line.dropFirst(indent))
            lines.append(Line(number: number, indent: indent, content: content, raw: line))
        }
        var parser = Parser(lines: lines)
        return parser.parseDocument()
    }

    /// Parses one scalar the way a YAML loader would type it.
    public static func scalar(_ text: String) -> YAMLValue {
        let s = stripComment(text).trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "~" || s == "null" { return .null }
        if s.hasPrefix("\"") { return .string(unquoteDouble(s)) }
        if s.hasPrefix("'") { return .string(unquoteSingle(s)) }
        if s.hasPrefix("[") && s.hasSuffix("]") {
            let inner = s.dropFirst().dropLast()
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return .list([]) }
            return .list(splitFlow(String(inner)).map { scalar($0) })
        }
        if s == "{}" { return .map([]) }
        switch s.lowercased() {
        case "true", "yes", "on": return .bool(true)
        case "false", "no", "off": return .bool(false)
        default: break
        }
        if let i = Int(s), !s.hasPrefix("+") { return .int(i) }
        if s.contains("."), let d = Double(s), s.first?.isNumber == true || s.first == "-" { return .double(d) }
        return .string(s)
    }

    /// Removes a trailing ` # comment` that is outside quotes.
    public static func stripComment(_ text: String) -> String {
        var inDouble = false, inSingle = false, previous: Character = " "
        var escaped = false
        for (offset, ch) in text.enumerated() {
            if inDouble {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inDouble = false }
            } else if inSingle {
                if ch == "'" { inSingle = false }
            } else if ch == "\"" && (previous == " " || offset == 0 || previous == ":") {
                inDouble = true
            } else if ch == "'" && (previous == " " || offset == 0) {
                inSingle = true
            } else if ch == "#" && (previous == " " || previous == "\t" || offset == 0) {
                return String(text.prefix(offset))
            }
            previous = ch
        }
        return text
    }

    static func unquoteDouble(_ s: String) -> String {
        var out = ""
        var chars = Array(s.dropFirst())
        if let closing = closingQuoteIndex(chars) { chars = Array(chars[..<closing]) }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                default: out.append(next)
                }
                i += 2
            } else {
                out.append(ch)
                i += 1
            }
        }
        return out
    }

    static func closingQuoteIndex(_ chars: [Character]) -> Int? {
        var escaped = false
        for (i, ch) in chars.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { return i }
        }
        return nil
    }

    static func unquoteSingle(_ s: String) -> String {
        var body = String(s.dropFirst())
        if body.hasSuffix("'") { body.removeLast() }
        return body.replacingOccurrences(of: "''", with: "'")
    }

    static func splitFlow(_ text: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Splits `key: value` at the first colon that is followed by a space or the end of the line and is outside quotes.
    static func splitKey(_ content: String) -> (key: String, rest: String)? {
        let chars = Array(content)
        guard let first = chars.first, first != "#", first != "[", first != "{" else { return nil }
        if first == "-", chars.count == 1 || chars[1] == " " { return nil }
        if first == "\"" || first == "'" {
            guard let end = chars.dropFirst().firstIndex(of: first), end + 1 < chars.count, chars[end + 1] == ":",
                  end + 2 == chars.count || chars[end + 2] == " " else { return nil }
            return (String(chars[1 ..< end]), String(chars[(end + 2)...]).trimmingCharacters(in: .whitespaces))
        }
        for i in chars.indices where chars[i] == ":" {
            if i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\t" {
                let key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                return (key, String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    struct Line {
        var number: Int
        var indent: Int
        var content: String
        var raw: String
        var isBlank: Bool {
            let t = content.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.hasPrefix("#")
        }
    }

    struct Parser {
        var lines: [Line]
        var index = 0

        mutating func parseDocument() -> YAMLValue {
            skipBlank()
            guard index < lines.count else { return .null }
            return parseNode(indent: lines[index].indent)
        }

        mutating func skipBlank() {
            while index < lines.count, lines[index].isBlank || lines[index].content == "---" { index += 1 }
        }

        mutating func parseNode(indent _: Int) -> YAMLValue {
            skipBlank()
            guard index < lines.count else { return .null }
            let line = lines[index]
            if line.content == "-" || line.content.hasPrefix("- ") { return parseList(indent: line.indent) }
            if splitKey(line.content) != nil { return parseMap(indent: line.indent) }
            index += 1
            return scalar(line.content)
        }

        mutating func parseList(indent: Int) -> YAMLValue {
            var items: [YAMLValue] = []
            while true {
                skipBlank()
                guard index < lines.count else { break }
                let line = lines[index]
                guard line.indent == indent, line.content == "-" || line.content.hasPrefix("- ") else { break }
                let rest = line.content == "-" ? "" : String(line.content.dropFirst(2))
                let restTrimmed = rest.trimmingCharacters(in: .whitespaces)
                if restTrimmed.isEmpty {
                    index += 1
                    skipBlank()
                    if index < lines.count, lines[index].indent > indent {
                        items.append(parseNode(indent: lines[index].indent))
                    } else {
                        items.append(.null)
                    }
                } else if splitKey(restTrimmed) != nil || restTrimmed.hasPrefix("- ") {
                    let extra = rest.prefix { $0 == " " }.count
                    lines[index] = Line(number: line.number, indent: indent + 2 + extra, content: restTrimmed, raw: line.raw)
                    items.append(parseNode(indent: indent + 2 + extra))
                } else {
                    index += 1
                    items.append(scalar(restTrimmed))
                }
            }
            return .list(items)
        }

        mutating func parseMap(indent: Int) -> YAMLValue {
            var entries: [YAMLEntry] = []
            while true {
                skipBlank()
                guard index < lines.count else { break }
                let line = lines[index]
                guard line.indent == indent, let (key, rest) = splitKey(line.content) else { break }
                index += 1
                let value: YAMLValue
                let restNoComment = stripComment(rest).trimmingCharacters(in: .whitespaces)
                if restNoComment.isEmpty {
                    skipBlank()
                    if index < lines.count, lines[index].indent > indent {
                        value = parseNode(indent: lines[index].indent)
                    } else if index < lines.count, lines[index].indent == indent, lines[index].content.hasPrefix("- ") {
                        value = parseList(indent: indent)
                    } else {
                        value = .null
                    }
                } else if restNoComment.hasPrefix("|") || restNoComment.hasPrefix(">") {
                    value = .string(blockScalar(parentIndent: indent, folded: restNoComment.hasPrefix(">")))
                } else {
                    value = scalar(continued(rest, parentIndent: indent))
                }
                entries.append(YAMLEntry(key: key, value: value))
            }
            return .map(entries)
        }

        /// A plain or quoted value that wraps onto more-indented lines is one value, folded with spaces.
        mutating func continued(_ first: String, parentIndent: Int) -> String {
            var text = first
            let quote = first.first.flatMap { $0 == "\"" || $0 == "'" ? $0 : nil }
            func closed() -> Bool {
                guard let quote else { return false }
                let body = text.dropFirst()
                return quote == "\"" ? closingQuoteIndex(Array(body)) != nil : body.contains(quote)
            }
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.content.trimmingCharacters(in: .whitespaces)
                guard line.indent > parentIndent, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { break }
                if quote == nil, splitKey(trimmed) != nil || trimmed.hasPrefix("- ") { break }
                if quote != nil, closed() { break }
                text += " " + trimmed
                index += 1
            }
            return text
        }

        mutating func blockScalar(parentIndent: Int, folded: Bool) -> String {
            var collected: [String] = []
            var blockIndent: Int?
            while index < lines.count {
                let line = lines[index]
                if line.content.trimmingCharacters(in: .whitespaces).isEmpty {
                    collected.append("")
                    index += 1
                    continue
                }
                guard line.indent > parentIndent else { break }
                if blockIndent == nil { blockIndent = line.indent }
                collected.append(String(line.raw.dropFirst(min(blockIndent ?? 0, line.indent))))
                index += 1
            }
            while collected.last == "" { collected.removeLast() }
            return folded ? collected.joined(separator: " ") + "\n" : collected.joined(separator: "\n") + "\n"
        }
    }
}

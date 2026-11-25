import Foundation

/// A Markdown file split into its front matter lines and body. Editing a field rewrites only that field's lines,
/// so a file that is opened and saved without changes comes back byte for byte.
public struct FrontMatterDocument: Sendable, Equatable {
    public private(set) var hasFrontMatter: Bool
    public private(set) var lines: [String]
    public var body: String
    private var openingLine: String
    private var closingLine: String
    /// Each line keeps its own ending, so a file that mixes CRLF and LF comes back byte for byte.
    private var endings: [String] = []
    private var openingEnding = "\n"
    /// What follows the closing `---`: a line ending, or nothing at the very end of the file.
    private var closingEnding = "\n"
    private var byteOrderMark = false

    public init(text: String) {
        var source = text
        if source.hasPrefix("\u{FEFF}") {
            byteOrderMark = true
            source.removeFirst()
        }
        let all = source.components(separatedBy: "\n")
        let isFence: (String) -> Bool = { ["---", "..."].contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        func split(_ line: String) -> (String, Bool) { line.hasSuffix("\r") ? (String(line.dropLast()), true) : (line, false) }
        if let first = all.first, first.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let close = all.dropFirst().firstIndex(where: isFence) {
            hasFrontMatter = true
            let (opening, openingCR) = split(first)
            openingLine = opening
            openingEnding = openingCR ? "\r\n" : "\n"
            lines = []
            for line in all[1 ..< close] {
                let (clean, cr) = split(line)
                lines.append(clean)
                endings.append(cr ? "\r\n" : "\n")
            }
            let (closing, closingCR) = split(all[close])
            closingLine = closing
            let more = close + 1 < all.count
            closingEnding = (closingCR ? "\r" : "") + (more ? "\n" : "")
            body = more ? all[(close + 1)...].joined(separator: "\n") : ""
        } else {
            hasFrontMatter = false
            openingLine = "---"
            closingLine = "---"
            // Front matter added later follows the file's own line endings.
            openingEnding = source.contains("\r\n") ? "\r\n" : "\n"
            closingEnding = openingEnding
            lines = []
            body = source
        }
    }

    public init(fields: [(String, String)], body: String) {
        hasFrontMatter = true
        openingLine = "---"
        closingLine = "---"
        lines = fields.map { "\($0.0): \($0.1)" }
        endings = Array(repeating: "\n", count: lines.count)
        self.body = body
    }

    public var text: String {
        let bom = byteOrderMark ? "\u{FEFF}" : ""
        guard hasFrontMatter else { return bom + body }
        var out = bom + openingLine + openingEnding
        for (line, ending) in zip(lines, endings) { out += line + ending }
        return out + closingLine + closingEnding + body
    }

    public var frontMatterText: String { lines.joined(separator: "\n") }

    public var values: YAMLValue { YAML.parse(frontMatterText) }

    public func value(_ key: String) -> YAMLValue? { values[key] }

    public var keys: [String] { fieldSpans().map(\.key) }

    /// Every line of a field, the key line first.
    public func rawLines(_ key: String) -> [String] {
        guard let span = fieldSpans().first(where: { $0.key == key }) else { return [] }
        return Array(lines[span.range])
    }

    /// The raw text after `key:` on the field's first line, comments included.
    public func rawValue(_ key: String) -> String? {
        guard let span = fieldSpans().first(where: { $0.key == key }) else { return nil }
        return YAML.splitKey(lines[span.range.lowerBound])?.rest
    }

    /// Sets a field to an already-formatted YAML value, or removes it when `raw` is nil.
    /// Leaves the file untouched when the field already holds the same value.
    public mutating func set(_ key: String, raw: String?, order: [String] = []) {
        let spans = fieldSpans()
        if let span = spans.first(where: { $0.key == key }) {
            guard let raw else {
                lines.removeSubrange(span.range)
                endings.removeSubrange(span.range)
                return
            }
            let current = YAML.parse(lines[span.range].joined(separator: "\n"))[key]
            let proposed = YAML.parse("\(key): \(raw)")[key]
            if current == proposed, span.range.count == 1 { return }
            let ending = endings[span.range.upperBound - 1]
            lines.replaceSubrange(span.range, with: ["\(key): \(raw)"])
            endings.replaceSubrange(span.range, with: [ending])
            return
        }
        guard let raw else { return }
        hasFrontMatter = true
        let newLine = "\(key): \(raw)"
        if let position = order.firstIndex(of: key) {
            let later = Set(order[(position + 1)...])
            if let next = spans.first(where: { later.contains($0.key) }) {
                lines.insert(newLine, at: next.range.lowerBound)
                endings.insert(openingEnding, at: next.range.lowerBound)
                return
            }
        }
        var insertAt = spans.last?.range.upperBound ?? lines.count
        while insertAt > 0, insertAt <= lines.count, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        lines.insert(newLine, at: insertAt)
        endings.insert(openingEnding, at: insertAt)
    }

    public struct FieldSpan: Sendable, Equatable {
        public var key: String
        public var range: Range<Int>
    }

    public func fieldSpans() -> [FieldSpan] {
        var spans: [FieldSpan] = []
        for (i, line) in lines.enumerated() {
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("#") && !line.hasPrefix("- ")
            if isTopLevel, let (key, _) = YAML.splitKey(line) {
                if var last = spans.popLast() {
                    last.range = last.range.lowerBound ..< lastContentLine(before: i, from: last.range.lowerBound)
                    spans.append(last)
                }
                spans.append(FieldSpan(key: key, range: i ..< i + 1))
            }
        }
        if var last = spans.popLast() {
            last.range = last.range.lowerBound ..< lastContentLine(before: lines.count, from: last.range.lowerBound)
            spans.append(last)
        }
        return spans
    }

    private func lastContentLine(before end: Int, from start: Int) -> Int {
        var upper = end
        while upper > start + 1, lines[upper - 1].trimmingCharacters(in: .whitespaces).isEmpty || lines[upper - 1].hasPrefix("#") {
            upper -= 1
        }
        return upper
    }
}

/// Formats values the way hand-written front matter looks on these sites: text in double quotes, bare dates and booleans.
public enum YAMLFormat {
    /// A double-quoted scalar on one line: line breaks and other control characters are escaped, so pasted text
    /// can never start a new key or a `---` that ends the front matter.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{85}", "\u{2028}", "\u{2029}", "\u{FEFF}":
                out += String(format: "\\u%04X", scalar.value)
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    public static func plainOrQuoted(_ text: String) -> String {
        let special = CharacterSet(charactersIn: ":#{}[],&*!|>'\"%@`").union(.controlCharacters).union(.newlines)
        let looksTyped = YAML.scalar(text) != .string(text)
        if text.isEmpty || looksTyped || text.rangeOfCharacter(from: special) != nil || text.hasPrefix(" ") || text.hasSuffix(" ") {
            return quoted(text)
        }
        return text
    }

    public static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `2026-12-01 09:00:00 +0200`, the form Jekyll reads for a post with a time.
    public static func dateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date) / 60
        let zone = String(format: "%@%02d%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d ", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0) + zone
    }

    public static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    public static func list(_ items: [String]) -> String {
        "[" + items.map { plainOrQuoted($0) }.joined(separator: ", ") + "]"
    }
}

public enum SiteDate {
    /// Reads `2026-06-20`, `2026-06-20 10:00`, `2026-06-20 10:00:00 +0800`, `+08:00`, `Z` and ISO 8601 forms.
    /// A date with an offset is that moment; one without is read in `timeZone` (the site's), as Jekyll does.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        var scanner = Scanner(text.trimmingCharacters(in: .whitespaces))
        guard let year = scanner.number(4 ... 4), scanner.take("-"), let month = scanner.number(1 ... 2), scanner.take("-"),
              let day = scanner.number(1 ... 2), (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
        guard scanner.atEnd || scanner.peek == " " || scanner.peek == "T" || scanner.peek == "t" || scanner.peek == "\t" else { return nil }
        var c = DateComponents(year: year, month: month, day: day)
        var zone = timeZone
        scanner.skip { $0 == " " || $0 == "\t" || $0 == "T" || $0 == "t" }
        let timeStart = scanner.index
        if let hour = scanner.number(1 ... 2), scanner.take(":"), let minute = scanner.number(1 ... 2) {
            c.hour = hour
            c.minute = minute
            c.second = scanner.take(":") ? scanner.number(1 ... 2) ?? 0 : 0
            if scanner.take(".") || scanner.take(",") { scanner.skip { $0.isASCII && $0.isNumber } }
            scanner.skip { $0 == " " || $0 == "\t" }
            if let offset = scanner.offset() { zone = TimeZone(secondsFromGMT: offset) ?? zone }
        } else {
            scanner.index = timeStart
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: c), calendar.component(.day, from: date) == day else { return nil }
        return date
    }

    private struct Scanner {
        let chars: [Character]
        var index = 0

        init(_ text: String) { chars = Array(text) }

        var atEnd: Bool { index >= chars.count }
        var peek: Character? { atEnd ? nil : chars[index] }

        mutating func take(_ ch: Character) -> Bool {
            guard peek == ch else { return false }
            index += 1
            return true
        }

        mutating func skip(while matches: (Character) -> Bool) {
            while let ch = peek, matches(ch) { index += 1 }
        }

        mutating func number(_ digits: ClosedRange<Int>) -> Int? {
            var value = 0, count = 0
            while count < digits.upperBound, let ch = peek, ch.isASCII, let d = ch.wholeNumberValue {
                value = value * 10 + d
                count += 1
                index += 1
            }
            return count >= digits.lowerBound ? value : nil
        }

        /// `Z`, `UTC`, `GMT`, `+08`, `+0800` or `+08:00`, in seconds east of Greenwich.
        mutating func offset() -> Int? {
            let start = index
            if take("Z") || take("z") { return 0 }
            for name in ["UTC", "GMT"] where chars[index...].starts(with: name) {
                index += name.count
                return 0
            }
            guard let sign = peek, sign == "+" || sign == "-" else { return nil }
            index += 1
            guard let hours = number(1 ... 2) else {
                index = start
                return nil
            }
            _ = take(":")
            let minutes = number(2 ... 2) ?? 0
            return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
        }
    }
}

import Foundation

/// A Markdown file split into its front matter lines and body. Editing a field rewrites only that field's lines,
/// so a file that is opened and saved without changes comes back byte for byte.
public struct FrontMatterDocument: Sendable, Equatable {
    public private(set) var hasFrontMatter: Bool
    public private(set) var lines: [String]
    public var body: String
    private var openingLine: String
    private var closingLine: String
    private var newlineAfterClosing: Bool

    public init(text: String) {
        let all = text.components(separatedBy: "\n")
        if let first = all.first, first.trimmingCharacters(in: .whitespaces) == "---" || first == "---\r",
           let close = all.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) {
            hasFrontMatter = true
            openingLine = first
            lines = Array(all[1 ..< close])
            closingLine = all[close]
            newlineAfterClosing = close + 1 < all.count
            body = close + 1 < all.count ? all[(close + 1)...].joined(separator: "\n") : ""
        } else {
            hasFrontMatter = false
            openingLine = "---"
            closingLine = "---"
            newlineAfterClosing = true
            lines = []
            body = text
        }
    }

    public init(fields: [(String, String)], body: String) {
        hasFrontMatter = true
        openingLine = "---"
        closingLine = "---"
        newlineAfterClosing = true
        lines = fields.map { "\($0.0): \($0.1)" }
        self.body = body
    }

    public var text: String {
        guard hasFrontMatter else { return body }
        var out = openingLine + "\n"
        for line in lines { out += line + "\n" }
        out += closingLine
        if newlineAfterClosing { out += "\n" }
        return out + body
    }

    public var frontMatterText: String { lines.joined(separator: "\n") }

    public var values: YAMLValue { YAML.parse(frontMatterText) }

    public func value(_ key: String) -> YAMLValue? { values[key] }

    public var keys: [String] { fieldSpans().map(\.key) }

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
                return
            }
            let current = YAML.parse(lines[span.range].joined(separator: "\n"))[key]
            let proposed = YAML.parse("\(key): \(raw)")[key]
            if current == proposed, span.range.count == 1 { return }
            lines.replaceSubrange(span.range, with: ["\(key): \(raw)"])
            return
        }
        guard let raw else { return }
        hasFrontMatter = true
        let newLine = "\(key): \(raw)"
        if let position = order.firstIndex(of: key) {
            let later = Set(order[(position + 1)...])
            if let next = spans.first(where: { later.contains($0.key) }) {
                lines.insert(newLine, at: next.range.lowerBound)
                return
            }
        }
        var insertAt = spans.last?.range.upperBound ?? lines.count
        while insertAt > 0, insertAt <= lines.count, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        lines.insert(newLine, at: insertAt)
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
    public static func quoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public static func plainOrQuoted(_ text: String) -> String {
        let special = CharacterSet(charactersIn: ":#{}[],&*!|>'\"%@`")
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

    public static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    public static func list(_ items: [String]) -> String {
        "[" + items.map { plainOrQuoted($0) }.joined(separator: ", ") + "]"
    }
}

public enum SiteDate {
    /// Reads `2026-06-20`, `2026-06-20 10:00`, `2026-06-20 10:00:00 +0800` and ISO 8601 forms.
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "T" }).map(String.init)
        guard let datePart = parts.first else { return nil }
        let ymd = datePart.split(separator: "-").compactMap { Int($0) }
        guard ymd.count == 3, (1 ... 12).contains(ymd[1]), (1 ... 31).contains(ymd[2]) else { return nil }
        var c = DateComponents(year: ymd[0], month: ymd[1], day: ymd[2])
        var zone = timeZone
        if parts.count > 1 {
            let hms = parts[1].prefix { $0.isNumber || $0 == ":" }.split(separator: ":").compactMap { Int($0) }
            if hms.count >= 2 {
                c.hour = hms[0]
                c.minute = hms[1]
                c.second = hms.count > 2 ? hms[2] : 0
            }
            if let offset = parts.last, parts.count > 2, offset.count == 5, let sign = offset.first, sign == "+" || sign == "-",
               let h = Int(offset.dropFirst().prefix(2)), let m = Int(offset.suffix(2)) {
                zone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)) ?? zone
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: c), calendar.component(.day, from: date) == ymd[2] else { return nil }
        return date
    }
}

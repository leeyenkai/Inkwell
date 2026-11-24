import Foundation

/// A GitHub-style Markdown table as a grid of cells, for editing in a grid and writing back as aligned Markdown.
public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: String, Sendable, CaseIterable {
        case none, left, center, right
    }

    public var header: [String]
    public var alignments: [Alignment]
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment]? = nil, rows: [[String]]) {
        self.header = header
        self.alignments = alignments ?? header.map { _ in .none }
        self.rows = rows
        normalize()
    }

    /// An empty table to start from.
    public static func blank(columns: Int = 2, rows: Int = 2) -> MarkdownTable {
        MarkdownTable(header: (1 ... columns).map { "Column \($0)" }, rows: Array(repeating: Array(repeating: "", count: columns), count: rows))
    }

    public var columnCount: Int { header.count }

    /// Every row has one cell per column.
    public mutating func normalize() {
        let width = max(1, header.count, rows.map(\.count).max() ?? 0)
        header += Array(repeating: "", count: width - header.count)
        alignments = Array(alignments.prefix(width)) + Array(repeating: .none, count: max(0, width - alignments.count))
        rows = rows.map { $0 + Array(repeating: "", count: max(0, width - $0.count)) }
    }

    public mutating func insertColumn(at index: Int) {
        let i = min(max(0, index), columnCount)
        header.insert("", at: i)
        alignments.insert(.none, at: i)
        for r in rows.indices { rows[r].insert("", at: i) }
    }

    public mutating func removeColumn(at index: Int) {
        guard columnCount > 1, header.indices.contains(index) else { return }
        header.remove(at: index)
        alignments.remove(at: index)
        for r in rows.indices { rows[r].remove(at: index) }
    }

    public mutating func moveColumn(from index: Int, by offset: Int) {
        let target = index + offset
        guard header.indices.contains(index), header.indices.contains(target) else { return }
        header.swapAt(index, target)
        alignments.swapAt(index, target)
        for r in rows.indices { rows[r].swapAt(index, target) }
    }

    public mutating func insertRow(at index: Int) {
        rows.insert(Array(repeating: "", count: columnCount), at: min(max(0, index), rows.count))
    }

    public mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    public mutating func moveRow(from index: Int, by offset: Int) {
        let target = index + offset
        guard rows.indices.contains(index), rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
    }

    // MARK: Markdown

    /// Pipes lined up, cells padded to the widest in each column. Pipes and line breaks typed in a cell are escaped.
    public var markdown: String {
        let clean = { (cell: String) -> String in
            Self.escape(cell.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "))
                .trimmingCharacters(in: .whitespaces)
        }
        let head = header.map(clean)
        let body = rows.map { $0.map(clean) }
        let widths = (0 ..< columnCount).map { c in
            max(3, ([head[c]] + body.map { $0[c] }).map(Self.displayWidth).max() ?? 3)
        }
        func line(_ cells: [String]) -> String {
            let padded = cells.enumerated().map { c, cell in
                let pad = String(repeating: " ", count: max(0, widths[c] - Self.displayWidth(cell)))
                return switch alignments[c] {
                case .right: pad + cell
                case .center: String(pad.prefix(pad.count / 2)) + cell + String(pad.dropFirst(pad.count / 2))
                default: cell + pad
                }
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        let delimiter = "| " + alignments.enumerated().map { c, alignment in
            let dashes = String(repeating: "-", count: widths[c] - (alignment == .center ? 2 : alignment == .none ? 0 : 1))
            return switch alignment {
            case .none: dashes
            case .left: ":" + dashes
            case .right: dashes + ":"
            case .center: ":" + dashes + ":"
            }
        }.joined(separator: " | ") + " |"
        return ([line(head), delimiter] + body.map(line)).joined(separator: "\n")
    }

    /// Reads the lines of a table; nil unless the second line is a delimiter row.
    public static func parse(_ text: String) -> MarkdownTable? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2, let alignments = delimiter(lines[1]) else { return nil }
        let header = cells(lines[0])
        guard header.count == alignments.count || header.count > 1 else { return nil }
        return MarkdownTable(header: header, alignments: alignments, rows: lines.dropFirst(2).map(cells))
    }

    /// The table around `location`: its range in `text` (whole lines, without the final line break) and its cells.
    public static func find(in text: String, at location: Int) -> (range: NSRange, table: MarkdownTable)? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let at = min(max(0, location), ns.length)
        func isRow(_ range: NSRange) -> Bool {
            let line = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            return !line.isEmpty && line.contains("|") && !line.hasPrefix("```") && !line.hasPrefix("    ")
        }
        var current = ns.lineRange(for: NSRange(location: at == ns.length && at > 0 ? at - 1 : at, length: 0))
        guard isRow(current) else { return nil }
        var start = current
        while start.location > 0 {
            let previous = ns.lineRange(for: NSRange(location: start.location - 1, length: 0))
            guard isRow(previous) else { break }
            start = previous
        }
        while NSMaxRange(current) < ns.length {
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(current), length: 0))
            guard isRow(next) else { break }
            current = next
        }
        var range = NSRange(location: start.location, length: NSMaxRange(current) - start.location)
        while range.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        guard let table = parse(ns.substring(with: range)) else { return nil }
        return (range, table)
    }

    /// Every table in the text (outside code fences), as whole-line ranges without the final line break.
    public static func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let fences = ImageLines.fencedRanges(ns)
        var result: [NSRange] = []
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            defer { location = max(NSMaxRange(line), location + 1) }
            guard delimiter(ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)) != nil, line.location > 0,
                  !fences.contains(where: { NSIntersectionRange($0, line).length > 0 }),
                  let found = find(in: text, at: line.location), !result.contains(found.range) else { continue }
            result.append(found.range)
            location = NSMaxRange(found.range)
        }
        return result
    }

    static func delimiter(_ line: String) -> [Alignment]? {
        guard line.contains("|") || line.contains(":") else { return nil }
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var result: [Alignment] = []
        for part in parts {
            let p = part.replacingOccurrences(of: " ", with: "")
            guard p.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            let left = p.hasPrefix(":"), right = p.hasSuffix(":")
            result.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return result
    }

    /// Splits on pipes that are not escaped and not inside inline code, then unescapes.
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var escaped = false
        for ch in trimmed {
            if escaped {
                cell.append(ch == "|" && !inCode ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "`" {
                inCode.toggle()
                cell.append(ch)
            } else if ch == "|", !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(ch)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func escape(_ cell: String) -> String {
        var out = ""
        var inCode = false
        for ch in cell {
            if ch == "`" { inCode.toggle() }
            out += ch == "|" && !inCode ? "\\|" : String(ch)
        }
        return out
    }

    /// Columns line up in a monospaced view when wide characters (CJK, most emoji) count twice.
    static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { total, scalar in
            let v = scalar.value
            let wide = (0x1100 ... 0x115F).contains(v) || (0x2E80 ... 0xA4CF).contains(v) || (0xAC00 ... 0xD7A3).contains(v)
                || (0xF900 ... 0xFAFF).contains(v) || (0xFE30 ... 0xFE4F).contains(v) || (0xFF00 ... 0xFF60).contains(v)
                || (0x1F300 ... 0x1FAFF).contains(v) || (0x20000 ... 0x3FFFD).contains(v)
            let zeroWidth = scalar.properties.generalCategory == .nonspacingMark || v == 0x200D || (0xFE00 ... 0xFE0F).contains(v)
            return total + (zeroWidth ? 0 : wide ? 2 : 1)
        }
    }
}

/// Paragraphs that are only a picture, `![alt](path)` (a title or `{: attributes}` may follow), for showing it in the editor.
public enum ImageLines {
    public struct Line: Sendable, Equatable {
        /// The image line, without its line break.
        public var range: NSRange
        public var target: String
        public var alt: String
    }

    public static func find(in text: String) -> [Line] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^[ \t]*!\[([^\]\n]*)\]\(\s*(\{\{[^}\n]*\}\}|[^)\s]+)(?:\s+"[^"\n]*")?\s*\)[ \t]*(?:\{:[^}\n]*\})?[ \t]*$"#
        ) else { return [] }
        let ns = text as NSString
        var fence = fencedRanges(ns)
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            while let first = fence.first, NSMaxRange(first) <= m.range.location { fence.removeFirst() }
            if let first = fence.first, NSIntersectionRange(first, m.range).length > 0 { return nil }
            return Line(range: m.range, target: ns.substring(with: m.range(at: 2)), alt: ns.substring(with: m.range(at: 1)))
        }
    }

    static func fencedRanges(_ ns: NSString) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: #"(?ms)^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$"#) else { return [] }
        return regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map(\.range)
    }
}

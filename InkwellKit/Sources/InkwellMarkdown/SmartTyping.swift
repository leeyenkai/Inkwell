import Foundation

/// Typing help that keeps the text plain Markdown: list and quote continuation, nesting, and blocks from the slash menu.
public enum SmartTyping {
    static let listPattern = try? NSRegularExpression(pattern: #"^(\s*)([-*+]|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?"#)
    static let quotePattern = try? NSRegularExpression(pattern: #"^((?:>\s?)+)"#)

    /// What Return should do on a list or quote line: continue it with the next marker, or end it when the item is empty.
    /// Returns nil for ordinary lines, where Return is just a newline.
    public static func newline(in text: String, at cursor: Int) -> FormattingResult? {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 10 { contentEnd -= 1 }
        if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 13 { contentEnd -= 1 }
        let line = ns.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
        let lineNS = line as NSString
        if let m = listPattern?.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) {
            let markerEnd = m.range.length
            // Return before or inside the marker opens a plain line above the item and leaves the item as it is.
            guard cursor >= lineRange.location + markerEnd else { return nil }
            let rest = lineNS.substring(from: markerEnd).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty, cursor == contentEnd {
                // An empty item ends the list.
                return FormattingResult(edits: [TextEdit(NSRange(location: lineRange.location, length: contentEnd - lineRange.location), "")],
                                        selection: NSRange(location: lineRange.location, length: 0))
            }
            let indent = lineNS.substring(with: m.range(at: 1))
            var marker = lineNS.substring(with: m.range(at: 2))
            if m.range(at: 3).location != NSNotFound, let n = Int(lineNS.substring(with: m.range(at: 3))) {
                marker = "\(n + 1)" + lineNS.substring(with: m.range(at: 4))
            }
            let gap = lineNS.substring(with: m.range(at: 5))
            let box = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
            let insert = "\n" + indent + marker + gap + box
            return FormattingResult(edits: [TextEdit(NSRange(location: cursor, length: 0), insert)],
                                    selection: NSRange(location: cursor + (insert as NSString).length, length: 0))
        }
        if let m = quotePattern?.firstMatch(in: line, range: NSRange(location: 0, length: lineNS.length)) {
            guard cursor >= lineRange.location + m.range.length else { return nil }
            let marker = lineNS.substring(with: m.range(at: 1))
            if lineNS.substring(from: m.range.length).trimmingCharacters(in: .whitespaces).isEmpty, cursor == contentEnd {
                return FormattingResult(edits: [TextEdit(NSRange(location: lineRange.location, length: contentEnd - lineRange.location), "")],
                                        selection: NSRange(location: lineRange.location, length: 0))
            }
            let insert = "\n" + (marker.hasSuffix(" ") ? marker : marker + " ")
            return FormattingResult(edits: [TextEdit(NSRange(location: cursor, length: 0), insert)],
                                    selection: NSRange(location: cursor + (insert as NSString).length, length: 0))
        }
        return nil
    }

    /// Tab and Shift-Tab on list lines: nest or unnest by the width of the marker. Nil when the selection is not in a list.
    public static func indent(in text: String, selection: NSRange, outdent: Bool) -> FormattingResult? {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        var location = lineRange.location
        var edits: [TextEdit] = []
        var delta = 0
        var firstShift = 0
        repeat {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line)
            guard let m = listPattern?.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) else { return nil }
            let width = m.range(at: 2).length + m.range(at: 5).length
            let leading = m.range(at: 1).length
            if outdent {
                let remove = min(leading, width)
                if remove > 0 { edits.append(TextEdit(NSRange(location: line.location + delta, length: remove), "")) }
                if line.location == lineRange.location { firstShift = -remove }
                delta -= remove
            } else {
                edits.append(TextEdit(NSRange(location: line.location + delta, length: 0), String(repeating: " ", count: width)))
                if line.location == lineRange.location { firstShift = width }
                delta += width
            }
            location = NSMaxRange(line)
        } while location < NSMaxRange(lineRange)
        guard !edits.isEmpty else { return nil }
        return FormattingResult(edits: edits, selection: NSRange(location: max(lineRange.location, selection.location + firstShift),
                                                                 length: max(0, selection.length + delta - firstShift)))
    }

    public enum Block: String, CaseIterable, Sendable {
        case heading1, heading2, heading3, quote, bullets, numbers, checklist, table, code, divider

        public var title: String {
            switch self {
            case .heading1: localized("Heading 1")
            case .heading2: localized("Heading 2")
            case .heading3: localized("Heading 3")
            case .quote: localized("Quote")
            case .bullets: localized("Bulleted List")
            case .numbers: localized("Numbered List")
            case .checklist: localized("Checklist")
            case .table: localized("Table")
            case .code: localized("Code Block")
            case .divider: localized("Section Break")
            }
        }

        /// The Markdown inserted, with `|` marking where the cursor goes.
        var template: String {
            switch self {
            case .heading1: "# |"
            case .heading2: "## |"
            case .heading3: "### |"
            case .quote: "> |"
            case .bullets: "- |"
            case .numbers: "1. |"
            case .checklist: "- [ ] |"
            case .table: "| Column | Column |\n| --- | --- |\n| | |"
            case .code: "```\n|\n```"
            case .divider: "***\n\n|"
            }
        }
    }

    /// Replaces the typed `/` with a block. Words already on the line after the slash are kept: a heading, quote or list
    /// marker goes in front of them, a code block wraps them, and a table or section break comes before them.
    public static func insert(_ block: Block, in text: String, slashAt location: Int) -> FormattingResult {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        var end = NSMaxRange(line)
        if end > line.location, ns.character(at: end - 1) == 10 { end -= 1 }
        if end > line.location, ns.character(at: end - 1) == 13 { end -= 1 }
        let restStart = min(location + 1, end)
        let rest = ns.substring(with: NSRange(location: restStart, length: end - restStart))
        let eol = ns.range(of: "\r\n").location != NSNotFound ? "\r\n" : "\n"
        let slash = NSRange(location: location, length: restStart - location)
        if block == .table {
            // The cursor lands on the first header, selected for typing over.
            let table = ["| Column | Column |", "| --- | --- |", "|  |  |"].joined(separator: eol)
            let after = rest.trimmingCharacters(in: .whitespaces).isEmpty ? "" : eol + eol
            return FormattingResult(edits: [TextEdit(slash, table + after)], selection: NSRange(location: location + 2, length: 6))
        }
        switch block {
        case .code:
            let open = "```" + eol, close = eol + "```"
            let kept = rest.trimmingCharacters(in: .whitespaces).isEmpty ? "" : rest
            return FormattingResult(edits: [TextEdit(NSRange(location: location, length: end - location), open + kept + close)],
                                    selection: NSRange(location: location + (open as NSString).length, length: 0))
        case .divider:
            let rule = "***" + eol + eol
            return FormattingResult(edits: [TextEdit(slash, rule)],
                                    selection: NSRange(location: location + (rule as NSString).length, length: 0))
        default:
            let template = block.template
            let marker = (template as NSString).range(of: "|")
            let clean = (template as NSString).replacingCharacters(in: marker, with: "")
            return FormattingResult(edits: [TextEdit(slash, clean)], selection: NSRange(location: location + marker.location, length: 0))
        }
    }

    /// An embed for a YouTube or Vimeo address, as responsive HTML that every Jekyll theme passes through.
    public static func embed(for urlString: String) -> String? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)), let host = url.host?.lowercased() else { return nil }
        var src: String?
        if host.contains("youtube.com"), let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            src = "https://www.youtube-nocookie.com/embed/\(id)"
        } else if host == "youtu.be" {
            src = "https://www.youtube-nocookie.com/embed/\(url.lastPathComponent)"
        } else if host.contains("vimeo.com"), let id = url.pathComponents.last, Int(id) != nil {
            src = "https://player.vimeo.com/video/\(id)"
        }
        guard let src else { return nil }
        return "<div style=\"position: relative; padding-top: 56.25%;\"><iframe src=\"\(src)\" "
            + "style=\"position: absolute; inset: 0; width: 100%; height: 100%; border: 0;\" allowfullscreen loading=\"lazy\" "
            + "title=\"Video\"></iframe></div>"
    }
}

/// Rich text from the clipboard (a web page, a document) as plain Markdown, keeping structure and dropping styling.
public enum HTMLToMarkdown {
    public static func convert(_ html: String) -> String {
        var input = html
        for pattern in [#"(?is)<!--.*?-->"#, #"(?is)<(script|style|head)[^>]*>.*?</\1>"#] {
            input = input.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        if let start = input.range(of: "<!--StartFragment-->"), let end = input.range(of: "<!--EndFragment-->") {
            input = String(input[start.upperBound ..< end.lowerBound])
        }
        var out = ""
        var listStack: [(ordered: Bool, count: Int)] = []
        var linkStack: [String?] = []
        var inPre = false
        var quoteDepth = 0
        let scanner = Array(input)
        var i = 0

        func newline(_ count: Int = 1) {
            // A line holding only a quote prefix is already a fresh line; drop it and start again.
            let lastLine = out.components(separatedBy: "\n").last ?? ""
            if !lastLine.isEmpty, lastLine.allSatisfy({ $0 == ">" || $0 == " " }) { out.removeLast(lastLine.count) }
            while out.hasSuffix(" ") { out.removeLast() }
            let existing = out.reversed().prefix { $0 == "\n" }.count
            if !out.isEmpty, existing < count { out += String(repeating: "\n", count: count - existing) }
            if quoteDepth > 0, count > 0 { out += String(repeating: "> ", count: quoteDepth) }
        }

        while i < scanner.count {
            if scanner[i] == "<", let close = scanner[i...].firstIndex(of: ">") {
                let tag = String(scanner[(i + 1) ..< close])
                i = close + 1
                let closing = tag.hasPrefix("/")
                let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).split(whereSeparator: { $0 == " " || $0 == "\n" }).first?
                    .lowercased() ?? ""
                func attr(_ key: String) -> String? {
                    guard let r = tag.range(of: "\(key)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.regularExpression, .caseInsensitive]) else { return nil }
                    let value = String(tag[r])
                    guard let open = value.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
                    return String(value[value.index(after: open)...].dropLast())
                }
                switch (name, closing) {
                case ("p", _), ("div", _), ("section", _), ("article", _): newline(2)
                case ("br", _): out += "  \n"
                case (let h, false) where h.count == 2 && h.hasPrefix("h") && Int(String(h.last!)) != nil:
                    newline(2)
                    out += String(repeating: "#", count: Int(String(h.last!))!) + " "
                case (let h, true) where h.count == 2 && h.hasPrefix("h"): newline(2)
                case ("strong", _), ("b", _): out += "**"
                case ("em", _), ("i", _): out += "*"
                case ("s", _), ("del", _), ("strike", _): out += "~~"
                case ("code", _) where !inPre: out += "`"
                case ("pre", false):
                    newline(2)
                    out += "```\n"
                    inPre = true
                case ("pre", true):
                    newline()
                    out += "```"
                    inPre = false
                    newline(2)
                case ("blockquote", false):
                    quoteDepth += 1
                    newline(2)
                case ("blockquote", true):
                    quoteDepth = max(0, quoteDepth - 1)
                    newline(2)
                case ("ul", false), ("ol", false):
                    newline(listStack.isEmpty ? 2 : 1)
                    listStack.append((name == "ol", 0))
                case ("ul", true), ("ol", true):
                    _ = listStack.popLast()
                    newline(listStack.isEmpty ? 2 : 1)
                case ("li", false):
                    newline()
                    let depth = max(0, listStack.count - 1)
                    out += String(repeating: "  ", count: depth)
                    if var last = listStack.popLast() {
                        last.count += 1
                        out += last.ordered ? "\(last.count). " : "- "
                        listStack.append(last)
                    } else {
                        out += "- "
                    }
                case ("a", false):
                    let href = attr("href")
                    linkStack.append(href)
                    if href != nil { out += "[" }
                case ("a", true):
                    if let href = linkStack.popLast() ?? nil { out += "](\(href))" }
                case ("img", _):
                    out += "![\(attr("alt") ?? "")](\(attr("src") ?? ""))"
                case ("hr", _):
                    newline(2)
                    out += "***"
                    newline(2)
                default: break
                }
                continue
            }
            var text = String(scanner[i])
            i += 1
            if !inPre {
                if text == "\n" || text == "\t" || text == "\r" { text = " " }
                if text == " ", out.last == " " || out.last == "\n" || out.isEmpty { continue }
            }
            out += text
        }
        return decode(out).components(separatedBy: "\n").map { $0.hasSuffix("  ") ? $0 : String($0.reversed().drop { $0 == " " }.reversed()) }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ s: String) -> String {
        MarkdownRenderer.decodeEntities(s.replacingOccurrences(of: "&nbsp;", with: " "))
    }
}

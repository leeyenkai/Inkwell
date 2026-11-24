import Foundation

/// Markdown to HTML following kramdown with GitHub Pages' default GFM input: auto heading ids, footnotes,
/// smart quotes and typographic dashes, tables, fenced code, strikethrough and task lists. HTML blocks pass through.
public struct MarkdownRenderer: Sendable {
    public var smartQuotes = true
    public var autoIDs = true

    public init() {}

    public func html(_ markdown: String) -> String {
        var state = RenderState()
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        lines = extractDefinitions(lines, state: &state)
        let blocks = parseBlocks(lines[...])
        var out = render(blocks, state: &state, tight: false)
        if !state.footnoteOrder.isEmpty {
            out += "<div class=\"footnotes\" role=\"doc-endnotes\">\n  <ol>\n"
            for name in state.footnoteOrder {
                var body = state.footnoteDefinitions[name] ?? ""
                let back = "<a href=\"#fnref:\(attr(name))\" class=\"reversefootnote\" role=\"doc-backlink\">&#8617;</a>"
                var inner = render(parseBlocks(body.components(separatedBy: "\n")[...]), state: &state, tight: false)
                if inner.hasSuffix("</p>\n") {
                    inner = String(inner.dropLast(5)) + "&nbsp;" + back + "</p>\n"
                } else {
                    inner += "<p>" + back + "</p>\n"
                }
                body = inner
                out += "    <li id=\"fn:\(attr(name))\">\n      \(body)    </li>\n"
            }
            out += "  </ol>\n</div>\n"
        }
        return out
    }

    // MARK: Blocks

    indirect enum Block {
        case paragraph(String)
        case heading(Int, String)
        case quote([Block])
        case list(ordered: Bool, start: Int, items: [[Block]], loose: Bool)
        case code(String, String)
        case rule
        case html(String)
        case table([String], [String], [[String]])
        case math(String)
    }

    struct RenderState {
        var links: [String: (String, String?)] = [:]
        var footnoteDefinitions: [String: String] = [:]
        var footnoteOrder: [String] = []
        var usedIDs: [String: Int] = [:]
    }

    func extractDefinitions(_ lines: [String], state: inout RenderState) -> [String] {
        var out: [String] = []
        var i = 0
        var inFence = false
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, let m = Self.match(#"^\[\^([^\]]+)\]:\s?(.*)$"#, line) {
                var body = [m[2]]
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    if next.hasPrefix("    ") || next.hasPrefix("  ") && !next.trimmingCharacters(in: .whitespaces).isEmpty {
                        body.append(String(next.drop { $0 == " " }))
                    } else if next.trimmingCharacters(in: .whitespaces).isEmpty, i + 1 < lines.count, lines[i + 1].hasPrefix("    ") {
                        body.append("")
                    } else {
                        break
                    }
                    i += 1
                }
                state.footnoteDefinitions[m[1]] = body.joined(separator: "\n")
                continue
            }
            if !inFence, let m = Self.match(#"^ {0,3}\[([^\]^][^\]]*)\]:\s*<?(\S+?)>?(?:\s+["'(](.*)["')])?\s*$"#, line) {
                state.links[m[1].lowercased()] = (m[2], m[3].isEmpty ? nil : m[3])
                i += 1
                continue
            }
            out.append(line)
            i += 1
        }
        return out
    }

    static let blockTags: Set = [
        "address", "article", "aside", "blockquote", "details", "dialog", "dd", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "iframe", "li", "main", "nav", "ol",
        "p", "pre", "section", "table", "ul", "video", "audio", "script", "style", "summary", "canvas", "noscript", "center",
    ]

    func parseBlocks(_ lines: ArraySlice<String>) -> [Block] {
        var blocks: [Block] = []
        var i = lines.startIndex
        var paragraph: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let fence = Self.match(#"^ {0,3}(`{3,}|~{3,})\s*([\w+#.-]*)"#, line) {
                flush()
                let marker = fence[1]
                var code: [String] = []
                i += 1
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(marker) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(fence[2], code.joined(separator: "\n")))
                continue
            }
            if trimmed == "$$" {
                flush()
                var math: [String] = []
                i += 1
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                    math.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.math(math.joined(separator: "\n")))
                continue
            }
            if let h = Self.match(#"^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$"#, line) {
                flush()
                blocks.append(.heading(h[1].count, h[2]))
                i += 1
                continue
            }
            if Self.match(#"^ {0,3}([-*_])( *\1){2,} *$"#, line) != nil {
                if paragraph.isEmpty || !trimmed.hasPrefix("-") {
                    flush()
                    blocks.append(.rule)
                    i += 1
                    continue
                }
            }
            if let setext = Self.match(#"^ {0,3}(=+|-+)\s*$"#, line), !paragraph.isEmpty {
                let text = paragraph.joined(separator: "\n")
                paragraph = []
                blocks.append(.heading(setext[1].hasPrefix("=") ? 1 : 2, text))
                i += 1
                continue
            }
            if Self.match(#"^\{:.*\}\s*$"#, trimmed) != nil {
                i += 1
                continue
            }
            if line.hasPrefix(">") || line.hasPrefix(" >") || line.hasPrefix("  >") || line.hasPrefix("   >") {
                flush()
                var inner: [String] = []
                while i < lines.endIndex {
                    let l = lines[i]
                    let t = l.drop { $0 == " " }
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !l.trimmingCharacters(in: .whitespaces).isEmpty, !(inner.last ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                        inner.append(l)
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.quote(parseBlocks(inner[...])))
                continue
            }
            if paragraph.isEmpty, Self.listMarker(line) != nil {
                let (block, next) = parseList(lines, from: i)
                blocks.append(block)
                i = next
                continue
            }
            if line.hasPrefix("    "), paragraph.isEmpty {
                var code: [String] = []
                while i < lines.endIndex, lines[i].hasPrefix("    ") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[i].dropFirst(min(4, lines[i].count))))
                    i += 1
                }
                while code.last?.isEmpty == true { code.removeLast() }
                blocks.append(.code("", code.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("|") || trimmed.contains(" | "), i + 1 < lines.endIndex,
               Self.match(#"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#, lines[i + 1]) != nil, lines[i + 1].contains("-") {
                flush()
                let header = Self.cells(line)
                let aligns = Self.cells(lines[i + 1]).map { cell -> String in
                    let c = cell.trimmingCharacters(in: .whitespaces)
                    if c.hasPrefix(":") && c.hasSuffix(":") { return "center" }
                    if c.hasSuffix(":") { return "right" }
                    if c.hasPrefix(":") { return "left" }
                    return ""
                }
                var rows: [[String]] = []
                i += 2
                while i < lines.endIndex, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.cells(lines[i]))
                    i += 1
                }
                blocks.append(.table(header, aligns, rows))
                continue
            }
            if paragraph.isEmpty, let tag = Self.htmlBlockTag(trimmed) {
                var html: [String] = []
                if tag == "!--" {
                    while i < lines.endIndex {
                        html.append(lines[i])
                        i += 1
                        if html.last?.contains("-->") == true { break }
                    }
                } else {
                    var depth = 0
                    while i < lines.endIndex {
                        let l = lines[i]
                        html.append(l)
                        depth += Self.count("<\(tag)(\\s|>|$)", in: l) - Self.count("</\(tag)\\s*>", in: l)
                        i += 1
                        if depth <= 0 { break }
                    }
                }
                blocks.append(.html(html.joined(separator: "\n")))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    struct ListMarker {
        var ordered: Bool
        var start: Int
        var markerIndent: Int
        var contentIndent: Int
        var bullet: String
    }

    static func listMarker(_ line: String) -> ListMarker? {
        guard let m = match(#"^( {0,3})([-*+]|(\d{1,9})[.)])( +|$)"#, line) else { return nil }
        if Self.match(#"^ {0,3}([-*_])( *\1){2,} *$"#, line) != nil { return nil }
        let indent = m[1].count
        let markerWidth = m[2].count
        let spaces = max(1, min(m[4].count, 4))
        return ListMarker(ordered: !m[3].isEmpty, start: Int(m[3]) ?? 1, markerIndent: indent,
                          contentIndent: indent + markerWidth + spaces, bullet: m[3].isEmpty ? m[2] : String(m[2].last ?? "."))
    }

    func parseList(_ lines: ArraySlice<String>, from start: Int) -> (Block, Int) {
        guard let first = Self.listMarker(lines[start]) else { return (.paragraph(lines[start]), start + 1) }
        var items: [[String]] = []
        var current: [String] = []
        var loose = false
        var i = start
        var contentIndent = first.contentIndent
        var sawBlank = false
        while i < lines.endIndex {
            let line = lines[i]
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if let marker = Self.listMarker(line), marker.ordered == first.ordered, marker.bullet == first.bullet || first.ordered,
               marker.markerIndent < contentIndent {
                if !current.isEmpty { items.append(current) }
                if sawBlank { loose = true }
                sawBlank = false
                contentIndent = marker.contentIndent
                current = [String(line.dropFirst(min(marker.contentIndent, line.count)))]
                i += 1
                continue
            }
            if blank {
                sawBlank = true
                current.append("")
                i += 1
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            if indent >= contentIndent {
                if sawBlank { loose = true }
                sawBlank = false
                current.append(String(line.dropFirst(contentIndent)))
                i += 1
                continue
            }
            if !sawBlank, Self.listMarker(line) == nil, !line.hasPrefix(">"), !line.hasPrefix("#") {
                current.append(line.trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            break
        }
        if !current.isEmpty { items.append(current) }
        let parsed = items.map { item -> [Block] in
            var trimmedItem = item
            while trimmedItem.last?.isEmpty == true { trimmedItem.removeLast() }
            if trimmedItem.dropLast().contains("") { loose = true }
            return parseBlocks(trimmedItem[...])
        }
        return (.list(ordered: first.ordered, start: first.start, items: parsed, loose: loose), i)
    }

    static func htmlBlockTag(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("<!--") { return "!--" }
        guard let m = match(#"^<([a-zA-Z][a-zA-Z0-9]*)[\s>/]"#, trimmed + " ") else { return nil }
        let tag = m[1].lowercased()
        return blockTags.contains(tag) ? tag : nil
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Rendering

    func render(_ blocks: [Block], state: inout RenderState, tight: Bool) -> String {
        var out = ""
        for block in blocks {
            switch block {
            case let .paragraph(text):
                let inner = inline(text, state: &state)
                out += tight ? inner + "\n" : "<p>\(inner)</p>\n"
            case let .heading(level, text):
                let inner = inline(text, state: &state)
                if autoIDs {
                    let id = uniqueID(Self.headingID(Self.stripTags(inner)), state: &state)
                    out += "<h\(level) id=\"\(id)\">\(inner)</h\(level)>\n"
                } else {
                    out += "<h\(level)>\(inner)</h\(level)>\n"
                }
            case let .quote(inner):
                out += "<blockquote>\n" + render(inner, state: &state, tight: false) + "</blockquote>\n"
            case let .list(ordered, start, items, loose):
                let tag = ordered ? "ol" : "ul"
                out += ordered && start != 1 ? "<ol start=\"\(start)\">\n" : "<\(tag)>\n"
                for item in items {
                    var blocksForItem = item
                    var checkbox = ""
                    if case let .paragraph(text)? = item.first,
                       let m = Self.match(#"^\[([ xX])\]\s+(.*)$"#, text.replacingOccurrences(of: "\n", with: "\u{0}")) {
                        let checked = m[1] == " " ? "" : " checked=\"checked\""
                        checkbox = "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled=\"disabled\"\(checked) />"
                        blocksForItem[0] = .paragraph(m[2].replacingOccurrences(of: "\u{0}", with: "\n"))
                    }
                    let cls = checkbox.isEmpty ? "" : " class=\"task-list-item\""
                    var body = render(blocksForItem, state: &state, tight: !loose)
                    if body.hasSuffix("\n") { body.removeLast() }
                    out += "  <li\(cls)>\(checkbox)\(body)</li>\n"
                }
                out += "</\(tag)>\n"
            case let .code(lang, code):
                let cls = lang.isEmpty ? "" : " class=\"language-\(attr(lang)) highlighter-rouge\""
                out += "<div\(cls)><pre class=\"highlight\"><code>\(Self.escape(code))\n</code></pre></div>\n"
            case .rule:
                out += "<hr />\n"
            case let .html(html):
                out += html + "\n"
            case let .math(text):
                out += "<div class=\"kdmath\">$$\n\(Self.escape(text))\n$$</div>\n"
            case let .table(header, aligns, rows):
                func style(_ i: Int) -> String {
                    i < aligns.count && !aligns[i].isEmpty ? " style=\"text-align: \(aligns[i])\"" : ""
                }
                out += "<table>\n  <thead>\n    <tr>\n"
                for (i, cell) in header.enumerated() { out += "      <th\(style(i))>\(inline(cell, state: &state))</th>\n" }
                out += "    </tr>\n  </thead>\n  <tbody>\n"
                for row in rows {
                    out += "    <tr>\n"
                    for (i, cell) in row.enumerated() where i < header.count { out += "      <td\(style(i))>\(inline(cell, state: &state))</td>\n" }
                    out += "    </tr>\n"
                }
                out += "  </tbody>\n</table>\n"
            }
        }
        return out
    }

    func uniqueID(_ base: String, state: inout RenderState) -> String {
        let n = state.usedIDs[base, default: 0]
        state.usedIDs[base] = n + 1
        return n == 0 ? base : "\(base)-\(n)"
    }

    /// kramdown's auto id: lowercase, drop everything but letters, digits, spaces and hyphens, spaces become hyphens.
    static func headingID(_ text: String) -> String {
        let decoded = decodeEntities(text)
        var id = ""
        for scalar in decoded.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "-" || scalar == "_" {
                id.unicodeScalars.append(scalar)
            } else if scalar == " " {
                id.append("-")
            }
        }
        while let first = id.first, !first.isLetter { id.removeFirst() }
        return id.isEmpty ? "section" : id
    }

    // MARK: Inline

    static let escapable: Set<Character> = Set("\\`*_{}[]()#+-.!|:<>\"'$=~")

    func inline(_ text: String, state: inout RenderState) -> String {
        let c = Array(text)
        var out = ""
        var i = 0
        var previous: Character = " "

        func emit(_ s: String, last: Character) {
            out += s
            previous = last
        }

        while i < c.count {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < c.count, Self.escapable.contains(c[i + 1]) {
                    emit(Self.escape(String(c[i + 1])), last: c[i + 1])
                    i += 2
                } else if i + 1 < c.count, c[i + 1] == "\n" {
                    emit("<br />\n", last: "\n")
                    i += 2
                } else {
                    emit("\\", last: "\\")
                    i += 1
                }
            case "`":
                var n = 0
                while i + n < c.count, c[i + n] == "`" { n += 1 }
                if let close = Self.findRun("`", count: n, in: c, from: i + n) {
                    var code = String(c[(i + n) ..< close])
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    emit("<code class=\"language-plaintext highlighter-rouge\">\(Self.escape(code))</code>", last: "`")
                    i = close + n
                } else {
                    emit(String(repeating: "`", count: n), last: "`")
                    i += n
                }
            case "!" where i + 1 < c.count && c[i + 1] == "[":
                if let (html, next) = link(c, from: i + 1, image: true, state: &state) {
                    emit(html, last: ")")
                    i = next
                } else {
                    emit("!", last: "!")
                    i += 1
                }
            case "[":
                if i + 1 < c.count, c[i + 1] == "^", let close = c[(i + 2)...].firstIndex(of: "]") {
                    let name = String(c[(i + 2) ..< close])
                    if state.footnoteDefinitions[name] != nil {
                        if !state.footnoteOrder.contains(name) { state.footnoteOrder.append(name) }
                        let number = (state.footnoteOrder.firstIndex(of: name) ?? 0) + 1
                        let link = "<a href=\"#fn:\(attr(name))\" class=\"footnote\" rel=\"footnote\">\(number)</a>"
                        emit("<sup id=\"fnref:\(attr(name))\" role=\"doc-noteref\">\(link)</sup>", last: "]")
                        i = close + 1
                        continue
                    }
                }
                if let (html, next) = link(c, from: i, image: false, state: &state) {
                    emit(html, last: "]")
                    i = next
                } else {
                    emit("[", last: "[")
                    i += 1
                }
            case "<":
                let rest = String(c[i...])
                if let m = Self.match(#"^<((?:https?|ftp|mailto):[^\s>]+)>"#, rest) {
                    let url = m[1]
                    let label = url.hasPrefix("mailto:") ? String(url.dropFirst(7)) : url
                    emit("<a href=\"\(attr(url))\">\(Self.escape(label))</a>", last: ">")
                    i += m[0].count
                } else if let m = Self.match(#"^(<!--.*?-->|</?[a-zA-Z][a-zA-Z0-9-]*(?:\s+[^<>]*?)?/?>)"#, rest) {
                    emit(m[0], last: ">")
                    i += m[0].count
                } else {
                    emit("&lt;", last: "<")
                    i += 1
                }
            case "*", "_":
                var n = 0
                while i + n < c.count, c[i + n] == ch { n += 1 }
                let opensOK = i + n < c.count && !c[i + n].isWhitespace && !(ch == "_" && (previous.isLetter || previous.isNumber))
                if opensOK, let close = findEmphasisClose(ch, count: min(n, 3), in: c, from: i + n) {
                    let width = min(n, 3)
                    let inner = inline(String(c[(i + width) ..< close]), state: &state)
                    let lead = String(repeating: String(ch), count: n - width)
                    switch width {
                    case 1: emit(lead + "<em>\(inner)</em>", last: ch)
                    case 2: emit(lead + "<strong>\(inner)</strong>", last: ch)
                    default: emit(lead + "<strong><em>\(inner)</em></strong>", last: ch)
                    }
                    i = close + width
                } else {
                    emit(String(repeating: String(ch), count: n), last: ch)
                    i += n
                }
            case "~" where i + 1 < c.count && c[i + 1] == "~":
                if i + 2 < c.count, !c[i + 2].isWhitespace, let close = Self.findRun("~", count: 2, in: c, from: i + 2) {
                    emit("<del>\(inline(String(c[(i + 2) ..< close]), state: &state))</del>", last: "~")
                    i = close + 2
                } else {
                    emit("~~", last: "~")
                    i += 2
                }
            case "&":
                let rest = String(c[i...])
                if let m = Self.match(#"^&(#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);"#, rest) {
                    emit(m[0], last: ";")
                    i += m[0].count
                } else {
                    emit("&amp;", last: "&")
                    i += 1
                }
            case ">":
                emit("&gt;", last: ">")
                i += 1
            case "\"" where smartQuotes:
                emit(Self.opens(previous) ? "&#8220;" : "&#8221;", last: "\"")
                i += 1
            case "'" where smartQuotes:
                emit(Self.opens(previous) ? "&#8216;" : "&#8217;", last: "'")
                i += 1
            case "-" where smartQuotes && i + 1 < c.count && c[i + 1] == "-":
                if i + 2 < c.count, c[i + 2] == "-" {
                    emit("&#8212;", last: "-")
                    i += 3
                } else {
                    emit("&#8211;", last: "-")
                    i += 2
                }
            case "." where smartQuotes && i + 2 < c.count && c[i + 1] == "." && c[i + 2] == ".":
                emit("&#8230;", last: ".")
                i += 3
            case "\n":
                if out.hasSuffix("  ") {
                    while out.hasSuffix(" ") { out.removeLast() }
                    emit("<br />\n", last: "\n")
                } else {
                    emit("\n", last: "\n")
                }
                i += 1
            default:
                emit(String(ch), last: ch)
                i += 1
            }
        }
        return out
    }

    static func opens(_ previous: Character) -> Bool {
        previous.isWhitespace || "([{-–—\u{0}/".contains(previous) || previous == "\n"
    }

    func findEmphasisClose(_ ch: Character, count: Int, in c: [Character], from start: Int) -> Int? {
        var j = start
        while j < c.count {
            if c[j] == "`" {
                var n = 0
                while j + n < c.count, c[j + n] == "`" { n += 1 }
                if let close = Self.findRun("`", count: n, in: c, from: j + n) { j = close + n; continue }
                j += n
                continue
            }
            if c[j] == "\\" { j += 2; continue }
            if c[j] == ch {
                var n = 0
                while j + n < c.count, c[j + n] == ch { n += 1 }
                let afterOK = ch != "_" || j + n >= c.count || !(c[j + n].isLetter || c[j + n].isNumber)
                if n >= count, j > start, !c[j - 1].isWhitespace, afterOK {
                    return j + (n - count)
                }
                if count == 2, n == 1, j + 1 < c.count, !c[j + 1].isWhitespace {
                    if let inner = findEmphasisClose(ch, count: 1, in: c, from: j + 1) { j = inner + 1; continue }
                }
                j += n
                continue
            }
            j += 1
        }
        return nil
    }

    static func findRun(_ ch: Character, count: Int, in c: [Character], from start: Int) -> Int? {
        var j = start
        while j < c.count {
            if c[j] == ch {
                var n = 0
                while j + n < c.count, c[j + n] == ch { n += 1 }
                if n == count { return j }
                j += n
            } else {
                j += 1
            }
        }
        return nil
    }

    func link(_ c: [Character], from open: Int, image: Bool, state: inout RenderState) -> (String, Int)? {
        var depth = 0
        var j = open
        var close: Int?
        while j < c.count {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "[" { depth += 1 }
            if c[j] == "]" {
                depth -= 1
                if depth == 0 { close = j; break }
            }
            j += 1
        }
        guard let close else { return nil }
        let label = String(c[(open + 1) ..< close])
        var url: String?
        var title: String?
        var next = close + 1
        if next < c.count, c[next] == "(" {
            var k = next + 1
            var parens = 1
            while k < c.count {
                if c[k] == "(" { parens += 1 }
                if c[k] == ")" {
                    parens -= 1
                    if parens == 0 { break }
                }
                k += 1
            }
            guard k < c.count else { return nil }
            var target = String(c[(next + 1) ..< k]).trimmingCharacters(in: .whitespaces)
            if let m = Self.match(#"^(.*?)\s+["'](.*)["']$"#, target) {
                target = m[1]
                title = m[2]
            }
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            url = target
            next = k + 1
        } else if next < c.count, c[next] == "[", let refClose = c[(next + 1)...].firstIndex(of: "]") {
            let ref = String(c[(next + 1) ..< refClose])
            let key = (ref.isEmpty ? label : ref).lowercased()
            guard let def = state.links[key] else { return nil }
            url = def.0
            title = def.1
            next = refClose + 1
        } else if let def = state.links[label.lowercased()] {
            url = def.0
            title = def.1
        }
        guard let url else { return nil }
        let titleAttr = title.map { " title=\"\(attr($0))\"" } ?? ""
        if image {
            let alt = Self.stripTags(inline(label, state: &state))
            return ("<img src=\"\(attr(url))\" alt=\"\(alt)\"\(titleAttr) />", next)
        }
        return ("<a href=\"\(attr(url))\"\(titleAttr)>\(inline(label, state: &state))</a>", next)
    }

    // MARK: Helpers

    func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&nbsp;": "\u{A0}", "&#39;": "'",
                     "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (k, v) in named where k != "&amp;" { out = out.replacingOccurrences(of: k, with: v) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let value = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10)
                result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: m.range)
                last = NSMaxRange(m.range)
            }
            out = result + ns.substring(from: last)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func count(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// Whole match first, then every group ("" when a group did not take part).
    static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = MarkdownScanner.regex(pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0 ..< m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}

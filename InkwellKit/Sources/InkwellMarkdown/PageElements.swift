import Foundation

/// Page elements: galleries, maps, timelines and the rest. Each is HTML with Markdown inside (kramdown's
/// `markdown="1"`) or a Liquid include from the element kit, so the page stays a readable Markdown file that
/// GitHub Pages builds on its own. Settings live in `data-*` attributes or include parameters; items are Markdown.
public enum PageElement: String, CaseIterable, Sendable, Identifiable {
    case gallery, slideshow, map, timeline, callout, columns, toggle, tabs, button, cards, hero, recent, archive, contents, social

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gallery: localized("Gallery")
        case .slideshow: localized("Slideshow")
        case .map: localized("Map")
        case .timeline: localized("Timeline")
        case .callout: localized("Callout")
        case .columns: localized("Columns")
        case .toggle: localized("Toggle")
        case .tabs: localized("Tabs")
        case .button: localized("Button")
        case .cards: localized("Cards")
        case .hero: localized("Banner")
        case .recent: localized("Recent Posts")
        case .archive: localized("Archive")
        case .contents: localized("Table of Contents")
        case .social: localized("Social Links")
        }
    }

    public var summary: String {
        switch self {
        case .gallery: localized("Pictures in a grid. Click one to see it large.")
        case .slideshow: localized("Pictures one at a time, with arrows.")
        case .map: localized("Places on a map, with a list below it.")
        case .timeline: localized("Dated events down a line.")
        case .callout: localized("A note, tip or warning that stands out.")
        case .columns: localized("Text side by side; stacked on phones.")
        case .toggle: localized("A heading that opens to show more.")
        case .tabs: localized("Sections the reader switches between.")
        case .button: localized("A link that looks like a button.")
        case .cards: localized("Projects or links as cards with pictures.")
        case .hero: localized("A large title over a picture, for the top of a page.")
        case .recent: localized("The latest posts of a section, kept up to date.")
        case .archive: localized("Every post of a section, by year.")
        case .contents: localized("Links to the headings of this page.")
        case .social: localized("Links to your profiles elsewhere.")
        }
    }

    public var symbol: String {
        switch self {
        case .gallery: "square.grid.2x2"
        case .slideshow: "rectangle.on.rectangle.angled"
        case .map: "map"
        case .timeline: "point.topleft.down.to.point.bottomright.curvepath"
        case .callout: "exclamationmark.bubble"
        case .columns: "rectangle.split.2x1"
        case .toggle: "chevron.right.square"
        case .tabs: "menubar.rectangle"
        case .button: "capsule"
        case .cards: "rectangle.grid.1x2"
        case .hero: "photo.artframe"
        case .recent: "list.bullet.rectangle"
        case .archive: "archivebox"
        case .contents: "list.bullet.indent"
        case .social: "person.2"
        }
    }

    /// Elements written as `{% include inkwell/<name>.html … %}`.
    public var includeName: String? {
        switch self {
        case .recent: "recent"
        case .archive: "archive"
        default: nil
        }
    }

    /// The class on the element's wrapper, `ik-<name>`.
    public var className: String { "ik-\(rawValue)" }

    /// The Markdown inserted for a new element, with sample content to type over.
    public func template(collection: String = "posts") -> String {
        switch self {
        case .gallery:
            return wrapped([])
        case .slideshow, .map:
            return wrapped([])
        case .timeline:
            return wrapped(["- **\(localized("2024"))** \(localized("What happened"))",
                            "- **\(localized("2025"))** \(localized("What happened next"))"])
        case .callout:
            return wrapped([localized("Something worth noticing.")])
        case .columns:
            let column = { (text: String) in "<div markdown=\"1\">\n\(text)\n</div>" }
            return wrapped([column(localized("First column")), column(localized("Second column"))])
        case .toggle:
            return "<details markdown=\"1\">\n<summary>\(localized("A question or heading"))</summary>\n\n"
                + "\(localized("The text shown when it opens."))\n</details>"
        case .tabs:
            return wrapped(["### \(localized("First"))", localized("Text for the first tab."), "",
                            "### \(localized("Second"))", localized("Text for the second tab.")])
        case .button:
            return "<a class=\"ik-button\" href=\"{{ '/' | relative_url }}\">\(localized("Read more"))</a>"
        case .cards:
            return wrapped(["- **[\(localized("Title"))](/)**", "  \(localized("A sentence about it."))"])
        case .hero:
            return wrapped(["# \(localized("A big welcome"))", localized("One line about this page.")])
        case .recent:
            return "{% include inkwell/recent.html collection=\"\(collection)\" limit=5 %}"
        case .archive:
            return "{% include inkwell/archive.html collection=\"\(collection)\" %}"
        case .contents:
            return "* \(localized("Contents"))\n{:toc}"
        case .social:
            return wrapped(["- [\(localized("Email"))](mailto:you@example.com)", "- [GitHub](https://github.com/)"])
        }
    }

    private func wrapped(_ lines: [String]) -> String {
        var attributes = ""
        if self == .gallery { attributes = " data-columns=\"3\"" }
        if self == .callout { attributes = " data-tone=\"note\"" }
        return (["<div class=\"\(className)\"\(attributes) markdown=\"1\">"] + lines + ["</div>"]).joined(separator: "\n")
    }
}

/// An element found in a page's text: where its wrapper lines are and what they say.
public struct ElementSpan: Sendable, Equatable {
    public var kind: PageElement
    /// The whole element, from its first line to the end of its last line (without the final newline).
    public var range: NSRange
    /// The opening line (or the only line, for includes, buttons and the table of contents).
    public var openRange: NSRange
    /// The closing line, for wrapped elements.
    public var closeRange: NSRange?
    /// The text between the wrapper lines.
    public var innerRange: NSRange?
    /// `data-*` attributes (without the prefix), include parameters, or a button's `href`.
    public var attributes: [String: String]
}

public enum PageElements {
    /// Every element in the text, outermost first, skipping fenced code.
    public static func find(in text: String) -> [ElementSpan] {
        let ns = text as NSString
        var result: [ElementSpan] = []
        var openStack: [(kind: PageElement?, tag: String, line: NSRange, end: Int, attributes: [String: String])] = []
        var location = 0
        var inFence = false
        var previousLineEnd = 0
        while location < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            // The line without its `\n` or `\r\n`.
            let content = NSRange(location: start, length: contentsEnd - start)
            let lineBreakBefore = start - previousLineEnd
            previousLineEnd = contentsEnd
            let trimmed = ns.substring(with: content).trimmingCharacters(in: .whitespacesAndNewlines)
            location = end
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if inFence { continue }
            if let open = opening(trimmed) {
                openStack.append((open.kind, open.tag, content, end, open.attributes))
                continue
            }
            // Plain HTML blocks are tracked too, so their closing line is not taken for the element's.
            if let tag = plainBlockTag(trimmed) {
                openStack.append((nil, tag, content, end, [:]))
                continue
            }
            if let top = openStack.last, trimmed.lowercased() == "</\(top.tag)>" {
                openStack.removeLast()
                guard let kind = top.kind else { continue }
                // Without the line break before the closing line, so replacing it keeps the closing line on its own.
                let inner = NSRange(location: min(top.end, content.location), length: max(0, content.location - lineBreakBefore - top.end))
                result.append(ElementSpan(kind: kind, range: NSRange(location: top.line.location, length: NSMaxRange(content) - top.line.location),
                                          openRange: top.line, closeRange: content, innerRange: inner, attributes: top.attributes))
                continue
            }
            if let single = singleLine(trimmed) {
                result.append(ElementSpan(kind: single.kind, range: content, openRange: content, closeRange: nil, innerRange: nil,
                                          attributes: single.attributes))
            }
            if trimmed == "{:toc}" {
                let before = content.location > 0 ? ns.lineRange(for: NSRange(location: content.location - 1, length: 0)) : content
                let range = NSRange(location: before.location, length: NSMaxRange(content) - before.location)
                result.append(ElementSpan(kind: .contents, range: range, openRange: range, closeRange: nil, innerRange: nil, attributes: [:]))
            }
        }
        return result.sorted { a, b in
            a.range.location != b.range.location ? a.range.location < b.range.location : a.range.length > b.range.length
        }
    }

    /// The innermost element containing `location`.
    public static func element(in text: String, at location: Int) -> ElementSpan? {
        find(in: text).filter { location >= $0.range.location && location <= NSMaxRange($0.range) }.min { $0.range.length < $1.range.length }
    }

    /// A wrapper's opening line: `<div class="ik-…" … markdown="1">` or `<details markdown="1">`.
    static func opening(_ line: String) -> (kind: PageElement?, tag: String, attributes: [String: String])? {
        guard line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</"),
              line.range(of: #"\smarkdown\s*=\s*["']?(1|block)["']?"#, options: .regularExpression) != nil,
              let tagEnd = line.dropFirst().firstIndex(where: { $0 == " " || $0 == ">" }) else { return nil }
        let tag = String(line[line.index(after: line.startIndex) ..< tagEnd]).lowercased()
        let attributes = htmlAttributes(line)
        var data: [String: String] = [:]
        for (key, value) in attributes where key.hasPrefix("data-") { data[String(key.dropFirst(5))] = value }
        if let style = attributes["style"], let url = style.firstMatch(of: /url\(['"]?([^'")]+)['"]?\)/) { data["image"] = String(url.1) }
        if tag == "details" { return (.toggle, tag, data) }
        let classes = (attributes["class"] ?? "").split(separator: " ").map(String.init)
        let kind = PageElement.allCases.first { classes.contains($0.className) }
        return (kind, tag, data)
    }

    /// A line that opens a `<div>`, `<details>` or `<section>` without closing it on the same line.
    static func plainBlockTag(_ line: String) -> String? {
        let lower = line.lowercased()
        for tag in ["div", "details", "section"] where lower.hasPrefix("<\(tag)") {
            let next = lower.dropFirst(tag.count + 1).first
            guard next == ">" || next == " " || next == "\t", !lower.hasSuffix("/>"), !lower.contains("</\(tag)>") else { return nil }
            return tag
        }
        return nil
    }

    /// Includes from the element kit, and buttons.
    static func singleLine(_ line: String) -> (kind: PageElement, attributes: [String: String])? {
        if let m = line.firstMatch(of: /^\{%-?\s*include\s+inkwell\/([a-z-]+)\.html(.*?)-?%\}$/),
           let kind = PageElement.allCases.first(where: { $0.includeName == String(m.1) }) {
            return (kind, includeParameters(String(m.2)))
        }
        if line.hasPrefix("<a "), line.hasSuffix("</a>"), line.contains("ik-button") {
            var attributes = htmlAttributes(line)
            if let text = line.firstMatch(of: /^<a [^>]*>(.*)<\/a>$/) { attributes["text"] = decodeEntities(String(text.1)) }
            let classes = (attributes["class"] ?? "").split(separator: " ")
            attributes["style"] = classes.contains("ik-button--outline") ? "outline" : "solid"
            attributes.removeValue(forKey: "class")
            return (.button, attributes)
        }
        return nil
    }

    /// Attribute values as plain text: entities are decoded here, so the writer escapes them exactly once.
    public static func htmlAttributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in orderedAttributes(tag) { result[key] = value }
        return result
    }

    static func orderedAttributes(_ tag: String) -> [(key: String, value: String)] {
        tag.matches(of: /([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/).map { m in
            (String(m.1).lowercased(), decodeEntities(String(m.2 ?? m.3 ?? m.4 ?? "")))
        }
    }

    /// `&amp;`, `&quot;`, `&lt;`, `&gt;`, `&apos;` and numeric references, in one pass so `&amp;lt;` stays `&lt;`.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [Substring: String] = ["amp": "&", "quot": "\"", "lt": "<", "gt": ">", "apos": "'", "nbsp": "\u{A0}"]
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(10).firstIndex(of: ";") {
                let name = after[..<semi]
                var decoded = named[name]
                if decoded == nil, name.hasPrefix("#") {
                    let number = name.dropFirst()
                    let value = number.first == "x" || number.first == "X" ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                    decoded = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                }
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    public static func includeParameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for m in text.matches(of: /([a-zA-Z_][-a-zA-Z0-9_]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|(\S+))/) {
            result[String(m.1)] = String(m.2 ?? m.3 ?? m.4 ?? "")
        }
        return result
    }

    // MARK: Writing

    static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    /// The opening line of a wrapped element with these settings, keeping attribute order stable. Attributes of
    /// `existing` (the line being replaced) that the settings do not cover, such as an `id` or extra classes, are kept.
    public static func openingLine(_ kind: PageElement, attributes: [String: String], existing: String? = nil) -> String {
        if kind == .toggle { return "<details markdown=\"1\">" }
        var classes = [kind.className]
        var kept: [String] = []
        var style: String?
        for (key, value) in existing.map(orderedAttributes) ?? [] {
            switch key {
            case "class":
                classes += value.split(whereSeparator: \.isWhitespace).map(String.init).filter { !classes.contains($0) }
            case "markdown":
                break
            case "style":
                // A background picture's style is written from the settings; any other style stays.
                if !value.contains("url(") { style = value }
            default:
                if !key.hasPrefix("data-") { kept.append("\(key)=\"\(escapeAttribute(value))\"") }
            }
        }
        var parts = ["class=\"\(classes.joined(separator: " "))\""]
        for key in attributes.keys.sorted() where key != "image" {
            guard let value = attributes[key], !value.isEmpty else { continue }
            parts.append("data-\(key)=\"\(escapeAttribute(value))\"")
        }
        if let image = attributes["image"], !image.isEmpty {
            parts.append("style=\"background-image: url('{{ '\(image.replacingOccurrences(of: "'", with: "%27"))' | relative_url }}')\"")
        } else if let style {
            parts.append("style=\"\(escapeAttribute(style))\"")
        }
        return "<div " + (parts + kept).joined(separator: " ") + " markdown=\"1\">"
    }

    public static func includeLine(_ kind: PageElement, attributes: [String: String]) -> String {
        var line = "{% include inkwell/\(kind.includeName ?? kind.rawValue).html"
        for key in attributes.keys.sorted() {
            guard let value = attributes[key], !value.isEmpty else { continue }
            line += Int(value) != nil ? " \(key)=\(value)" : " \(key)=\"\(value.replacingOccurrences(of: "\"", with: "'"))\""
        }
        return line + " %}"
    }

    public static func buttonLine(text: String, link: String, outline: Bool) -> String {
        let href = link.hasPrefix("/") ? "{{ '\(link)' | relative_url }}" : escapeAttribute(link)
        return "<a class=\"ik-button\(outline ? " ik-button--outline" : "")\" href=\"\(href)\">\(escapeAttribute(text))</a>"
    }

    /// Replaces an element's settings line (and, when given, its inner Markdown) as one edit.
    public static func update(_ span: ElementSpan, in text: String, attributes: [String: String], inner: String? = nil) -> FormattingResult {
        let ns = text as NSString
        let line: String
        switch span.kind {
        case .button:
            line = buttonLine(text: attributes["text"] ?? "", link: attributes["href"] ?? "", outline: attributes["style"] == "outline")
        case .recent, .archive:
            line = includeLine(span.kind, attributes: attributes)
        case .contents:
            return FormattingResult(edits: [], selection: NSRange(location: span.range.location, length: 0))
        case .toggle:
            let summary = attributes["summary"] ?? ""
            var edits = [TextEdit]()
            if let innerRange = span.innerRange {
                let body = inner ?? ns.substring(with: innerRange)
                var lines = body.components(separatedBy: "\n")
                if let i = lines.firstIndex(where: { $0.hasPrefix("<summary>") }) {
                    lines[i] = "<summary>\(summary)</summary>"
                } else {
                    lines.insert("<summary>\(summary)</summary>", at: 0)
                }
                edits.append(TextEdit(innerRange, lines.joined(separator: "\n")))
            }
            return FormattingResult(edits: edits, selection: NSRange(location: span.range.location, length: 0))
        default:
            line = openingLine(span.kind, attributes: attributes, existing: ns.substring(with: span.openRange))
        }
        // Later text first, so each range still points at the text it means.
        var edits: [TextEdit] = []
        if let inner, let innerRange = span.innerRange {
            let crlf = NSMaxRange(span.openRange) < ns.length && ns.character(at: NSMaxRange(span.openRange)) == 13
            let empty = innerRange.length == 0
                && (innerRange.location >= ns.length || ![10, 13].contains(ns.character(at: innerRange.location)))
            let replacement = empty && !inner.isEmpty ? inner + "\n" : inner
            edits.append(TextEdit(innerRange, crlf ? replacement.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\r\n") : replacement))
        }
        edits.append(TextEdit(span.openRange, line))
        return FormattingResult(edits: edits, selection: NSRange(location: span.openRange.location, length: 0))
    }

    /// The text to insert for a new element at `location`, on lines of its own.
    public static func insertion(_ markdown: String, in text: String, at location: Int) -> FormattingResult {
        let ns = text as NSString
        let at = min(max(0, location), ns.length)
        let lineStart = ns.lineRange(for: NSRange(location: at, length: 0))
        let lineText = ns.substring(with: lineStart).trimmingCharacters(in: .whitespacesAndNewlines)
        let insertAt = lineText.isEmpty ? lineStart.location : NSMaxRange(lineStart)
        let head = ns.substring(to: insertAt)
        let before = insertAt == 0 || head.hasSuffix("\n\n") ? "" : head.hasSuffix("\n") ? "\n" : "\n\n"
        let replaceLength = lineText.isEmpty ? lineStart.length : 0
        let after = "\n\n"
        let insert = before + markdown + after
        return FormattingResult(edits: [TextEdit(NSRange(location: insertAt, length: replaceLength), insert)],
                                selection: NSRange(location: insertAt + (before as NSString).length, length: 0))
    }

    // MARK: Items

    /// A timeline entry: `- **date** text`.
    public struct TimelineItem: Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var date: String
        public var text: String
        public init(date: String, text: String) { self.date = date; self.text = text }
        public static func == (a: Self, b: Self) -> Bool { a.date == b.date && a.text == b.text }
    }

    public static func timeline(_ inner: String) -> [TimelineItem]? {
        let lines = inner.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var items: [TimelineItem] = []
        for line in lines {
            guard let m = line.firstMatch(of: /^[-*+]\s+\*\*(.+?)\*\*\s*(.*)$/) else { return nil }
            items.append(TimelineItem(date: String(m.1), text: String(m.2)))
        }
        return items
    }

    public static func timelineMarkdown(_ items: [TimelineItem]) -> String {
        items.map { "- **\($0.date)** \($0.text)" }.joined(separator: "\n")
    }

    /// A place on a map: `- [name](geo:lat,lon)`.
    public struct Place: Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var name: String
        public var latitude: Double
        public var longitude: Double
        public init(name: String, latitude: Double, longitude: Double) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
        }
        public static func == (a: Self, b: Self) -> Bool { a.name == b.name && a.latitude == b.latitude && a.longitude == b.longitude }
    }

    public static func places(_ inner: String) -> [Place]? {
        var items: [Place] = []
        for line in inner.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let m = String(line).firstMatch(of: /^[-*+]\s+\[(.*)\]\(geo:\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\)\s*$/),
                  let lat = Double(m.2), let lon = Double(m.3) else { return nil }
            items.append(Place(name: String(m.1), latitude: lat, longitude: lon))
        }
        return items
    }

    public static func placesMarkdown(_ items: [Place]) -> String {
        items.map { "- [\($0.name.replacingOccurrences(of: "]", with: ")"))](geo:\(coordinate($0.latitude)),\(coordinate($0.longitude)))" }
            .joined(separator: "\n")
    }

    static func coordinate(_ value: Double) -> String {
        var s = String(format: "%.5f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// A picture in a gallery or slideshow: `![alt](path "caption")`.
    public struct Picture: Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var path: String
        public var alt: String
        public var caption: String
        public init(path: String, alt: String, caption: String = "") {
            self.path = path
            self.alt = alt
            self.caption = caption
        }
        public static func == (a: Self, b: Self) -> Bool { a.path == b.path && a.alt == b.alt && a.caption == b.caption }
    }

    public static func pictures(_ inner: String) -> [Picture]? {
        var items: [Picture] = []
        for line in inner.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let m = String(line).trimmingCharacters(in: .whitespaces)
                .firstMatch(of: /^!\[([^\]]*)\]\(\s*(\{\{.*?\}\}|\S+?)(?:\s+"([^"]*)")?\s*\)$/) else { return nil }
            items.append(Picture(path: plainPath(String(m.2)), alt: String(m.1), caption: m.3.map(String.init) ?? ""))
        }
        return items
    }

    public static func picturesMarkdown(_ items: [Picture]) -> String {
        items.map { picture in
            let caption = picture.caption.isEmpty ? "" : " \"\(picture.caption.replacingOccurrences(of: "\"", with: "'"))\""
            return "![\(picture.alt.replacingOccurrences(of: "]", with: ")"))](\(linkPath(picture.path))\(caption))"
        }
        .joined(separator: "\n")
    }

    /// A card: picture, linked title and a line of text.
    public struct Card: Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var title: String
        public var link: String
        public var text: String
        public var image: String
        public init(title: String, link: String, text: String, image: String = "") {
            self.title = title
            self.link = link
            self.text = text
            self.image = image
        }
        public static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.link == b.link && a.text == b.text && a.image == b.image }
    }

    public static func cards(_ inner: String) -> [Card]? {
        var cards: [Card] = []
        var current: Card?
        for raw in inner.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let starts = raw.hasPrefix("- ") || raw.hasPrefix("* ")
            let line = (starts ? String(raw.dropFirst(2)) : raw).trimmingCharacters(in: .whitespaces)
            if starts {
                if let current { cards.append(current) }
                current = Card(title: "", link: "", text: "")
            } else if current == nil || !raw.hasPrefix(" ") {
                return nil
            }
            if let m = line.firstMatch(of: /^!\[[^\]]*\]\(\s*(\{\{.*?\}\}|\S+?)\s*\)$/) {
                current?.image = plainPath(String(m.1))
            } else if let m = line.firstMatch(of: /^\*\*\[(.*)\]\((\{\{.*?\}\}|\S*)\)\*\*$/) {
                current?.title = String(m.1)
                current?.link = plainPath(String(m.2))
            } else if let m = line.firstMatch(of: /^\*\*(.*)\*\*$/) {
                current?.title = String(m.1)
            } else {
                let previous = current?.text ?? ""
                current?.text = previous.isEmpty ? line : previous + " " + line
            }
        }
        if let current { cards.append(current) }
        return cards
    }

    public static func cardsMarkdown(_ cards: [Card]) -> String {
        cards.map { card in
            var lines: [String] = []
            if !card.image.isEmpty { lines.append("![](\(linkPath(card.image)))") }
            lines.append(card.link.isEmpty ? "**\(card.title)**" : "**[\(card.title)](\(linkPath(card.link)))**")
            if !card.text.isEmpty { lines.append(card.text) }
            return "- " + lines.joined(separator: "\n  ")
        }
        .joined(separator: "\n")
    }

    /// `{{ '/x' | relative_url }}` → `/x`, for showing and editing paths.
    public static func plainPath(_ path: String) -> String {
        if let m = path.firstMatch(of: /^\{\{\s*['"]([^'"]+)['"]\s*\|\s*relative_url\s*\}\}$/) { return String(m.1) }
        return path
    }

    /// Site paths go through `relative_url`, so project sites (with a base URL) work too.
    public static func linkPath(_ path: String) -> String {
        path.hasPrefix("/") && !path.hasPrefix("//") ? "{{ '\(path)' | relative_url }}" : path
    }

    /// A link in a list: `- [title](url)`, as social links use.
    public struct LinkItem: Sendable, Equatable, Identifiable {
        public var id = UUID()
        public var title: String
        public var url: String
        public init(title: String, url: String) { self.title = title; self.url = url }
        public static func == (a: Self, b: Self) -> Bool { a.title == b.title && a.url == b.url }
    }

    public static func links(_ inner: String) -> [LinkItem]? {
        var items: [LinkItem] = []
        for line in inner.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let m = String(line).firstMatch(of: /^[-*+]\s+\[(.*)\]\((\{\{.*?\}\}|\S*)\)\s*$/) else { return nil }
            items.append(LinkItem(title: String(m.1), url: plainPath(String(m.2))))
        }
        return items
    }

    public static func linksMarkdown(_ items: [LinkItem]) -> String {
        items.map { "- [\($0.title.replacingOccurrences(of: "]", with: ")"))](\(linkPath($0.url)))" }.joined(separator: "\n")
    }

    /// Tab titles: the `###` headings inside a tabs element.
    public static func tabTitles(_ inner: String) -> [String] {
        inner.split(separator: "\n").compactMap { line in
            line.hasPrefix("### ") ? String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces) : nil
        }
    }

    /// The summary line of a toggle.
    public static func summary(_ inner: String) -> String {
        inner.firstMatch(of: /<summary>(.*)<\/summary>/).map { String($0.1) } ?? ""
    }

    /// How many `<div markdown="1">` columns a columns element has.
    public static func columnCount(_ inner: String) -> Int {
        inner.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("<div") }.count
    }

    /// Adds or removes empty columns so there are `count`; columns with text are never removed.
    public static func columns(_ inner: String, count: Int) -> String {
        var blocks: [String] = []
        var current: [String] = []
        var depth = 0
        for line in inner.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<div") { depth += 1 }
            if depth > 0 { current.append(line) }
            if t == "</div>" {
                depth -= 1
                if depth == 0 {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                }
            }
        }
        while blocks.count < count { blocks.append("<div markdown=\"1\">\n\(localized("New column"))\n</div>") }
        while blocks.count > count, let last = blocks.last, last.components(separatedBy: "\n").count <= 3,
              columnText(last) == localized("New column") || columnText(last).isEmpty {
            blocks.removeLast()
        }
        return blocks.joined(separator: "\n")
    }

    static func columnText(_ block: String) -> String {
        block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("<") && !$0.hasPrefix("</") }
            .joined().trimmingCharacters(in: .whitespaces)
    }
}

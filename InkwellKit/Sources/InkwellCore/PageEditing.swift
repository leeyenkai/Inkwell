import Foundation

/// Editing a hand-built page on its rendered preview (SPEC §4.12, W3). Elements whose content is plain text, pictures
/// and link addresses are marked in a preview-only copy of the page with their place in the source; an edit made in the preview
/// comes back as the element's number and new text, and only those characters change in the file.
public enum PageEditing {
    public struct Regions: Sendable, Equatable {
        /// The text inside each editable element, in the source's UTF-16 offsets.
        public var texts: [NSRange]
        /// The `src` value of each picture.
        public var images: [NSRange]
        /// The `href` value of each link.
        public var links: [NSRange] = []
        /// The page with `data-ik-text` and `data-ik-img` marks, for the preview only.
        public var annotated: String
    }

    /// Elements a reader thinks of as text. Their content must be text alone (entities allowed) to be editable here.
    static let textTags = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "a", "span", "figcaption", "blockquote", "td", "th",
                           "button", "label", "small", "strong", "em", "b", "i", "dt", "dd", "caption", "summary", "cite", "q", "time"]

    /// With `liquid`, for a page Jekyll builds, text and addresses holding template tags are left to the source.
    public static func regions(in html: String, liquid: Bool = false) -> Regions {
        let ns = html as NSString
        let whole = NSRange(location: 0, length: ns.length)
        // Scripts, styles, comments, the head, inline SVG and template tags are never edited here.
        var skipped: [NSRange] = []
        for pattern in [#"(?is)<script\b.*?</script>"#, #"(?is)<style\b.*?</style>"#, #"(?s)<!--.*?-->"#, #"(?is)<head\b.*?</head>"#,
                        #"(?is)<svg\b.*?</svg>"#, #"(?is)<template\b.*?</template>"#, #"(?is)<textarea\b.*?</textarea>"#] {
            for m in (try? NSRegularExpression(pattern: pattern))?.matches(in: html, range: whole) ?? [] { skipped.append(m.range) }
        }
        func isSkipped(_ r: NSRange) -> Bool { skipped.contains { NSIntersectionRange($0, r).length > 0 || NSLocationInRange(r.location, $0) } }
        func hasTags(_ r: NSRange) -> Bool {
            guard liquid else { return false }
            let text = ns.substring(with: r)
            return text.contains("{{") || text.contains("{%")
        }

        var texts: [NSRange] = [], images: [NSRange] = []
        var marks: [(Int, String)] = []
        let tags = textTags.joined(separator: "|")
        let element = try? NSRegularExpression(pattern: "<(\(tags))(\\s[^<>]*)?>([^<]*)</\\1\\s*>", options: .caseInsensitive)
        for m in element?.matches(in: html, range: whole) ?? [] where !isSkipped(m.range) {
            let inner = m.range(at: 3)
            guard !ns.substring(with: inner).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !hasTags(inner) else { continue }
            let nameEnd = NSMaxRange(m.range(at: 1))
            marks.append((nameEnd, " data-ik-text=\"\(texts.count)\""))
            texts.append(inner)
        }
        let picture = try? NSRegularExpression(pattern: #"<img\b[^>]*?\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>"#, options: .caseInsensitive)
        for m in picture?.matches(in: html, range: whole) ?? [] where !isSkipped(m.range) {
            let value = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            guard !hasTags(value) else { continue }
            marks.append((m.range.location + 4, " data-ik-img=\"\(images.count)\""))
            images.append(value)
        }
        var links: [NSRange] = []
        let link = try? NSRegularExpression(pattern: #"<a\b[^>]*?\shref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>"#, options: .caseInsensitive)
        for m in link?.matches(in: html, range: whole) ?? [] where !isSkipped(m.range) {
            let value = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            guard !hasTags(value) else { continue }
            marks.append((m.range.location + 2, " data-ik-link=\"\(links.count)\""))
            links.append(value)
        }
        let annotated = NSMutableString(string: html)
        for (location, mark) in marks.sorted(by: { $0.0 > $1.0 }) { annotated.insert(mark, at: location) }
        return Regions(texts: texts, images: images, links: links, annotated: annotated as String)
    }

    /// The page with element `index`'s text replaced, or nil when the page no longer has that element with the text
    /// the person started from (it changed in the source meanwhile). Equal text gives the page unchanged.
    public static func replacingText(_ index: Int, with text: String, expecting original: String, in html: String,
                                     liquid: Bool = false) -> String? {
        let found = regions(in: html, liquid: liquid).texts
        guard found.indices.contains(index) else { return nil }
        let range = found[index]
        let ns = html as NSString
        let current = ns.substring(with: range)
        guard normalized(HTMLHead.decode(current)) == normalized(original) else { return nil }
        guard normalized(text) != normalized(original) else { return html }
        // Spaces and line breaks around the text stay as they were in the file.
        let leading = String(current.prefix { $0.isWhitespace }), trailing = String(current.reversed().prefix { $0.isWhitespace }.reversed())
        let replacement = leading + HTMLHead.escapeText(text.trimmingCharacters(in: .whitespacesAndNewlines)) + trailing
        return ns.replacingCharacters(in: range, with: replacement)
    }

    /// The page with picture `index` pointing at `source`.
    public static func replacingImage(_ index: Int, with source: String, in html: String, liquid: Bool = false) -> String? {
        let found = regions(in: html, liquid: liquid).images
        guard found.indices.contains(index) else { return nil }
        return (html as NSString).replacingCharacters(in: found[index], with: HTMLHead.escape(source))
    }

    /// The page with link `index` pointing at `address`, or nil when that link no longer points where it did.
    public static func replacingLink(_ index: Int, with address: String, expecting original: String, in html: String,
                                     liquid: Bool = false) -> String? {
        let found = regions(in: html, liquid: liquid).links
        guard found.indices.contains(index) else { return nil }
        let ns = html as NSString
        guard HTMLHead.decode(ns.substring(with: found[index])) == original else { return nil }
        guard address != original else { return html }
        return ns.replacingCharacters(in: found[index], with: HTMLHead.escape(address))
    }

    /// Browsers show runs of spaces and line breaks as one space, so text is compared the way it reads.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

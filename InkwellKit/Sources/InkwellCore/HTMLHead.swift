import Foundation

/// The parts of a hand-written HTML page Inkwell shows: its title, description and share image, with where each sits in
/// the file so one can be changed without touching anything else.
public struct HTMLHead: Sendable {
    public var title: String?
    public var description: String?
    public var image: String?
    /// The characters of the `<title>` text, and of the description and image `content` values, in the page's UTF-16 text.
    public var titleRange: NSRange?
    public var descriptionRange: NSRange?
    public var imageRange: NSRange?

    public init(_ html: String) {
        let ns = html as NSString
        // Only the head, so a `<title>` inside an inline SVG further down is not taken for the page's.
        let headEnd = ns.range(of: "</head>", options: .caseInsensitive)
        let scope = NSRange(location: 0, length: headEnd.location == NSNotFound ? ns.length : headEnd.location)
        if let m = Self.first(#"<title[^>]*>([\s\S]*?)</title>"#, in: html, range: scope) {
            titleRange = m.range(at: 1)
            title = Self.decode(ns.substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func meta(_ attribute: String, _ names: [String]) -> (String, NSRange)? {
            for name in names {
                let escaped = NSRegularExpression.escapedPattern(for: name)
                let patterns = [
                    #"<meta\s[^>]*\#(attribute)\s*=\s*["']\#(escaped)["'][^>]*\scontent\s*=\s*"([^"]*)""#,
                    #"<meta\s[^>]*\#(attribute)\s*=\s*["']\#(escaped)["'][^>]*\scontent\s*=\s*'([^']*)'"#,
                    #"<meta\s[^>]*content\s*=\s*"([^"]*)"[^>]*\s\#(attribute)\s*=\s*["']\#(escaped)["']"#,
                ]
                for pattern in patterns {
                    if let m = Self.first(pattern, in: html, range: scope) {
                        return (Self.decode(ns.substring(with: m.range(at: 1))), m.range(at: 1))
                    }
                }
            }
            return nil
        }
        if let found = meta("name", ["description"]) ?? meta("property", ["og:description"]) {
            (description, descriptionRange) = (found.0, found.1)
        }
        if let found = meta("property", ["og:image"]) ?? meta("name", ["twitter:image"]) {
            (image, imageRange) = (found.0, found.1)
        }
    }

    /// "Game statistics — FX Steam Launcher" reads as "Game statistics" in a list of the site's own pages.
    public static func shortTitle(_ title: String) -> String {
        for separator in [" — ", " – ", " | ", " · ", " - "] {
            if let range = title.range(of: separator) {
                let first = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if !first.isEmpty { return first }
            }
        }
        return title
    }

    /// The text a reader sees in the body: no head, scripts, styles, comments or tags.
    public static func visibleText(_ html: String) -> String {
        decode(mainContent(html).replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
    }

    /// The body's own content as HTML: without the head, scripts, styles and pictures drawn in SVG, and without the
    /// header, menu and footer every page repeats.
    public static func mainContent(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<head[\s>].*?</head>"#, #"(?is)<script[\s>].*?</script>"#, #"(?is)<style[\s>].*?</style>"#,
                        #"(?is)<svg[\s>].*?</svg>"#, #"(?s)<!--.*?-->"#, #"(?is)<header[\s>].*?</header>"#, #"(?is)<nav[\s>].*?</nav>"#,
                        #"(?is)<footer[\s>].*?</footer>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
    }

    /// The text for an attribute value or element body, with the characters HTML needs escaped.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“",
                     "&middot;": "·", "&copy;": "©"]
        for (entity, character) in named where entity != "&amp;" {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let ns = result as NSString
            var output = ""
            var last = 0
            for m in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = m.range(at: 1).length > 0
                let digits = ns.substring(with: m.range(at: 2))
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    output += String(Character(scalar))
                } else {
                    output += ns.substring(with: m.range)
                }
                last = NSMaxRange(m.range)
            }
            output += ns.substring(from: last)
            result = output
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func first(_ pattern: String, in text: String, range: NSRange) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?.firstMatch(in: text, range: range)
    }
}

public extension HTMLHead {
    enum Field: Sendable, CaseIterable {
        case title, description, image
    }

    /// The page with one head field set, changing only that value's characters. A field the page lacks is added as a
    /// line before `</head>`, indented like the line above it. An empty value removes nothing: it empties the value.
    static func setting(_ field: Field, to value: String, in html: String) -> String {
        let head = HTMLHead(html)
        let ns = html as NSString
        let escaped = field == .title ? escapeText(value) : escape(value)
        let range: NSRange? = switch field {
        case .title: head.titleRange
        case .description: head.descriptionRange
        case .image: head.imageRange
        }
        if let range {
            guard decode(ns.substring(with: range)).trimmingCharacters(in: .whitespacesAndNewlines) != value else { return html }
            return ns.replacingCharacters(in: range, with: escaped)
        }
        guard !value.isEmpty else { return html }
        let close = ns.range(of: "</head>", options: .caseInsensitive)
        guard close.location != NSNotFound else { return html }
        let line = switch field {
        case .title: "<title>\(escaped)</title>"
        case .description: "<meta name=\"description\" content=\"\(escaped)\">"
        case .image: "<meta property=\"og:image\" content=\"\(escaped)\">"
        }
        // The indentation of the last line inside the head, so the new line sits with its neighbours.
        let before = ns.substring(to: close.location)
        let lines = before.components(separatedBy: "\n")
        let previous = lines.count > 1 ? lines[lines.count - 2] : ""
        let indent = String(previous.prefix { $0 == " " || $0 == "\t" })
        let lineStart = (before as NSString).range(of: "\n", options: .backwards)
        let onOwnLine = lineStart.location != NSNotFound
            && before[before.index(before.startIndex, offsetBy: lineStart.location + 1)...].allSatisfy { $0 == " " || $0 == "\t" }
        if onOwnLine {
            // `</head>` starts its own line: the new line goes above it.
            return ns.replacingCharacters(in: NSRange(location: lineStart.location + 1, length: 0), with: indent + line + "\n")
        }
        return ns.replacingCharacters(in: NSRange(location: close.location, length: 0), with: line)
    }

    /// Text inside an element only needs `&` and `<` escaped; quotes stay as typed.
    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}

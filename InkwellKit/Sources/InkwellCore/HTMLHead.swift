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

    /// The text for an attribute value or element body, with the characters HTML needs escaped. Both quotes are
    /// escaped, so the value is safe whichever quote the attribute uses.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The text a reader sees for HTML source text: named entities (HTML 4 and the common typographic ones) and
    /// numeric ones decoded in one pass, so `&amp;lt;` reads as `&lt;`. Unknown entities stay as written.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var output = ""
        var last = 0
        for m in entityPattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            output += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var decoded: String?
            if m.range(at: 1).location != NSNotFound {
                decoded = HTMLEntities.named[ns.substring(with: m.range(at: 1))].map { String(Character($0)) }
            } else {
                let hex = m.range(at: 2).length > 0
                if let value = UInt32(ns.substring(with: m.range(at: 3)), radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    decoded = String(Character(scalar))
                }
            }
            output += decoded ?? ns.substring(with: m.range)
            last = NSMaxRange(m.range)
        }
        return output + ns.substring(from: last)
    }

    private static let entityPattern = try? NSRegularExpression(pattern: #"&(?:([A-Za-z][A-Za-z0-9]{1,31})|#([xX]?)([0-9A-Fa-f]{1,8}));"#)

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
        // The indentation of the last line inside the head, so the new line sits with its neighbours. Offsets stay in
        // UTF-16 throughout: a CRLF or an emoji before `</head>` counts differently as Characters.
        let before = ns.substring(to: close.location) as NSString
        let lineStart = before.range(of: "\n", options: .backwards)
        let tail = lineStart.location == NSNotFound ? "" : before.substring(from: lineStart.location + 1)
        let onOwnLine = lineStart.location != NSNotFound && tail.allSatisfy { $0 == " " || $0 == "\t" }
        if onOwnLine {
            // `</head>` starts its own line: the new line goes above it, ending the way the file's lines end.
            let previousStart = lineStart.location == 0 ? NSNotFound
                : before.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: lineStart.location)).location
            let previous = before.substring(with: NSRange(location: previousStart == NSNotFound ? 0 : previousStart + 1,
                                                          length: lineStart.location - (previousStart == NSNotFound ? 0 : previousStart + 1)))
            let indent = String(previous.prefix { $0 == " " || $0 == "\t" })
            let crlf = lineStart.location > 0 && before.character(at: lineStart.location - 1) == 13
            return ns.replacingCharacters(in: NSRange(location: lineStart.location + 1, length: 0), with: indent + line + (crlf ? "\r\n" : "\n"))
        }
        return ns.replacingCharacters(in: NSRange(location: close.location, length: 0), with: line)
    }

    /// Text inside an element only needs `&` and `<` escaped; quotes stay as typed.
    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
}

/// The named character references of HTML 4 (Latin-1, symbols and Greek, and the special set), plus `&apos;`.
enum HTMLEntities {
    static let named: [String: Unicode.Scalar] = raw.compactMapValues(Unicode.Scalar.init)

    private static let raw: [String: UInt32] = [
        "AElig": 0xC6, "Aacute": 0xC1, "Acirc": 0xC2, "Agrave": 0xC0, "Alpha": 0x391, "Aring": 0xC5, "Atilde": 0xC3, "Auml": 0xC4,
        "Beta": 0x392, "Ccedil": 0xC7, "Chi": 0x3A7, "Dagger": 0x2021, "Delta": 0x394, "ETH": 0xD0, "Eacute": 0xC9, "Ecirc": 0xCA,
        "Egrave": 0xC8, "Epsilon": 0x395, "Eta": 0x397, "Euml": 0xCB, "Gamma": 0x393, "Iacute": 0xCD, "Icirc": 0xCE, "Igrave": 0xCC,
        "Iota": 0x399, "Iuml": 0xCF, "Kappa": 0x39A, "Lambda": 0x39B, "Mu": 0x39C, "Ntilde": 0xD1, "Nu": 0x39D, "OElig": 0x152,
        "Oacute": 0xD3, "Ocirc": 0xD4, "Ograve": 0xD2, "Omega": 0x3A9, "Omicron": 0x39F, "Oslash": 0xD8, "Otilde": 0xD5, "Ouml": 0xD6,
        "Phi": 0x3A6, "Pi": 0x3A0, "Prime": 0x2033, "Psi": 0x3A8, "Rho": 0x3A1, "Scaron": 0x160, "Sigma": 0x3A3, "THORN": 0xDE,
        "Tau": 0x3A4, "Theta": 0x398, "Uacute": 0xDA, "Ucirc": 0xDB, "Ugrave": 0xD9, "Upsilon": 0x3A5, "Uuml": 0xDC, "Xi": 0x39E,
        "Yacute": 0xDD, "Yuml": 0x178, "Zeta": 0x396, "aacute": 0xE1, "acirc": 0xE2, "acute": 0xB4, "aelig": 0xE6, "agrave": 0xE0,
        "alefsym": 0x2135, "alpha": 0x3B1, "amp": 0x26, "and": 0x2227, "ang": 0x2220, "apos": 0x27, "aring": 0xE5, "asymp": 0x2248,
        "atilde": 0xE3, "auml": 0xE4, "bdquo": 0x201E, "beta": 0x3B2, "brvbar": 0xA6, "bull": 0x2022, "cap": 0x2229, "ccedil": 0xE7,
        "cedil": 0xB8, "cent": 0xA2, "chi": 0x3C7, "circ": 0x2C6, "clubs": 0x2663, "cong": 0x2245, "copy": 0xA9, "crarr": 0x21B5,
        "cup": 0x222A, "curren": 0xA4, "dArr": 0x21D3, "dagger": 0x2020, "darr": 0x2193, "deg": 0xB0, "delta": 0x3B4, "diams": 0x2666,
        "divide": 0xF7, "eacute": 0xE9, "ecirc": 0xEA, "egrave": 0xE8, "empty": 0x2205, "emsp": 0x2003, "ensp": 0x2002, "epsilon": 0x3B5,
        "equiv": 0x2261, "eta": 0x3B7, "eth": 0xF0, "euml": 0xEB, "euro": 0x20AC, "exist": 0x2203, "fnof": 0x192, "forall": 0x2200,
        "frac12": 0xBD, "frac14": 0xBC, "frac34": 0xBE, "frasl": 0x2044, "gamma": 0x3B3, "ge": 0x2265, "gt": 0x3E, "hArr": 0x21D4,
        "harr": 0x2194, "hearts": 0x2665, "hellip": 0x2026, "iacute": 0xED, "icirc": 0xEE, "iexcl": 0xA1, "igrave": 0xEC,
        "image": 0x2111, "infin": 0x221E, "int": 0x222B, "iota": 0x3B9, "iquest": 0xBF, "isin": 0x2208, "iuml": 0xEF, "kappa": 0x3BA,
        "lArr": 0x21D0, "lambda": 0x3BB, "lang": 0x2329, "laquo": 0xAB, "larr": 0x2190, "lceil": 0x2308, "ldquo": 0x201C, "le": 0x2264,
        "lfloor": 0x230A, "lowast": 0x2217, "loz": 0x25CA, "lrm": 0x200E, "lsaquo": 0x2039, "lsquo": 0x2018, "lt": 0x3C, "macr": 0xAF,
        "mdash": 0x2014, "micro": 0xB5, "middot": 0xB7, "minus": 0x2212, "mu": 0x3BC, "nabla": 0x2207, "nbsp": 0xA0, "ndash": 0x2013,
        "ne": 0x2260, "ni": 0x220B, "not": 0xAC, "notin": 0x2209, "nsub": 0x2284, "ntilde": 0xF1, "nu": 0x3BD, "oacute": 0xF3,
        "ocirc": 0xF4, "oelig": 0x153, "ograve": 0xF2, "oline": 0x203E, "omega": 0x3C9, "omicron": 0x3BF, "oplus": 0x2295, "or": 0x2228,
        "ordf": 0xAA, "ordm": 0xBA, "oslash": 0xF8, "otilde": 0xF5, "otimes": 0x2297, "ouml": 0xF6, "para": 0xB6, "part": 0x2202,
        "permil": 0x2030, "perp": 0x22A5, "phi": 0x3C6, "pi": 0x3C0, "piv": 0x3D6, "plusmn": 0xB1, "pound": 0xA3, "prime": 0x2032,
        "prod": 0x220F, "prop": 0x221D, "psi": 0x3C8, "quot": 0x22, "rArr": 0x21D2, "radic": 0x221A, "rang": 0x232A, "raquo": 0xBB,
        "rarr": 0x2192, "rceil": 0x2309, "rdquo": 0x201D, "real": 0x211C, "reg": 0xAE, "rfloor": 0x230B, "rho": 0x3C1, "rlm": 0x200F,
        "rsaquo": 0x203A, "rsquo": 0x2019, "sbquo": 0x201A, "scaron": 0x161, "sdot": 0x22C5, "sect": 0xA7, "shy": 0xAD, "sigma": 0x3C3,
        "sigmaf": 0x3C2, "sim": 0x223C, "spades": 0x2660, "sub": 0x2282, "sube": 0x2286, "sum": 0x2211, "sup": 0x2283, "sup1": 0xB9,
        "sup2": 0xB2, "sup3": 0xB3, "supe": 0x2287, "szlig": 0xDF, "tau": 0x3C4, "there4": 0x2234, "theta": 0x3B8, "thetasym": 0x3D1,
        "thinsp": 0x2009, "thorn": 0xFE, "tilde": 0x2DC, "times": 0xD7, "trade": 0x2122, "uArr": 0x21D1, "uacute": 0xFA, "uarr": 0x2191,
        "ucirc": 0xFB, "ugrave": 0xF9, "uml": 0xA8, "upsih": 0x3D2, "upsilon": 0x3C5, "uuml": 0xFC, "weierp": 0x2118, "xi": 0x3BE,
        "yacute": 0xFD, "yen": 0xA5, "yuml": 0xFF, "zeta": 0x3B6, "zwj": 0x200D, "zwnj": 0x200C,
    ]
}

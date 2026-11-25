import Foundation

/// A new page for a hand-built site, made from one of its pages so it looks like the rest of the site: the same head
/// (stylesheets, fonts, icons) with a new title, the same header and footer, and an empty main part (SPEC §4.12, W2).
public enum HTMLPageTemplate {
    /// `sourceIsHome` says where the site's name sits in the source's title: first on the home page ("Launcher — Games
    /// on your Mac"), last on other pages ("Game statistics — Launcher"). The new title follows the other pages' pattern.
    public static func make(from source: String, title: String, sourceIsHome: Bool) -> String {
        let ns = source as NSString
        let bodyOpen = ns.range(of: #"<body\b[^>]*>"#, options: [.regularExpression, .caseInsensitive])
        guard bodyOpen.location != NSNotFound else { return plain(title: title) }

        // The head, without what describes the source page alone.
        var head = ns.substring(to: NSMaxRange(bodyOpen))
        for pattern in [#"\n?[ \t]*<meta\s[^>]*(name|property)\s*=\s*["'](description|og:[a-z:_]+|twitter:[a-z:_]+)["'][^>]*>"#,
                        #"\n?[ \t]*<link\s[^>]*rel\s*=\s*["']canonical["'][^>]*>"#] {
            head = head.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        head = HTMLHead.setting(.title, to: title + siteSuffix(HTMLHead(source).title ?? "", sourceIsHome: sourceIsHome), in: head)

        let body = ns.substring(from: NSMaxRange(bodyOpen))
        let header = firstBlock("header", in: body) ?? firstBlock("nav", in: body)
        let footer = lastBlock("footer", in: body)
        let indent = "  "
        var parts = [head]
        if let header { parts.append(header) }
        parts.append("""
        <main>
        \(indent)<h1>\(HTMLHead.escapeText(title))</h1>
        \(indent)<p></p>
        </main>
        """)
        if let footer { parts.append(footer) }
        parts.append("</body>\n</html>\n")
        return parts.joined(separator: "\n")
    }

    /// " — Launcher" from "Launcher — Games on your Mac" (home) or "Game statistics — Launcher" (another page).
    static func siteSuffix(_ sourceTitle: String, sourceIsHome: Bool) -> String {
        for separator in [" — ", " – ", " | ", " · ", " - "] {
            guard let range = sourceTitle.range(of: separator) else { continue }
            let name = sourceIsHome ? String(sourceTitle[..<range.lowerBound])
                : String(sourceTitle[sourceTitle.range(of: separator, options: .backwards)!.upperBound...])
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "" : separator + trimmed
        }
        return sourceIsHome && !sourceTitle.isEmpty ? " — " + sourceTitle : ""
    }

    /// A page with nothing to copy from.
    public static func plain(title: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(HTMLHead.escapeText(title))</title>
        </head>
        <body>
        <main>
          <h1>\(HTMLHead.escapeText(title))</h1>
          <p></p>
        </main>
        </body>
        </html>

        """
    }

    static func firstBlock(_ tag: String, in html: String) -> String? {
        guard let range = html.range(of: "(?is)<\(tag)\\b.*?</\(tag)>", options: .regularExpression) else { return nil }
        return String(html[range])
    }

    static func lastBlock(_ tag: String, in html: String) -> String? {
        guard let start = html.range(of: "<\(tag)", options: [.caseInsensitive, .backwards]),
              let end = html.range(of: "</\(tag)>", options: .caseInsensitive, range: start.lowerBound ..< html.endIndex) else { return nil }
        return String(html[start.lowerBound ..< end.upperBound])
    }

    /// A free file name for the title beside `folder` pages: `pricing.html`, then `pricing-2.html`.
    public static func fileName(for title: String, existing: Set<String>) -> String {
        let base = Slug.make(title).isEmpty ? "page" : Slug.make(title)
        var name = "\(base).html"
        var n = 2
        while existing.contains(name) {
            name = "\(base)-\(n).html"
            n += 1
        }
        return name
    }
}

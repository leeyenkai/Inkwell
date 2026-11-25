import Foundation

/// The parts a hand-built site copies into every page: its header, menu and footer (SPEC §4.12, W4). A part changed on one
/// page can be changed the same way on every page that has an identical copy, and nowhere else.
public enum SharedParts {
    public enum Part: String, Sendable, CaseIterable, Identifiable {
        case header, nav, footer
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .header: localized("header")
            case .nav: localized("menu")
            case .footer: localized("footer")
            }
        }
    }

    /// The page's header (the first `<header>`), its menu (the first `<nav>` outside that header) and its footer (the
    /// last `<footer>`), each exactly as written.
    public static func blocks(in html: String) -> [Part: String] {
        var result: [Part: String] = [:]
        let header = html.range(of: #"(?is)<header\b.*?</header>"#, options: .regularExpression)
        if let header { result[.header] = String(html[header]) }
        var searchFrom = html.startIndex
        while let nav = html.range(of: #"(?is)<nav\b.*?</nav>"#, options: .regularExpression, range: searchFrom ..< html.endIndex) {
            if let header, header.contains(nav.lowerBound) {
                searchFrom = nav.upperBound
                continue
            }
            result[.nav] = String(html[nav])
            break
        }
        if let start = html.range(of: "<footer", options: [.caseInsensitive, .backwards]),
           let end = html.range(of: "</footer>", options: .caseInsensitive, range: start.lowerBound ..< html.endIndex) {
            result[.footer] = String(html[start.lowerBound ..< end.upperBound])
        }
        return result
    }

    /// The parts that differ between `before` and `after` of one page.
    public static func changes(from before: String, to after: String) -> [(part: Part, old: String, new: String)] {
        let old = blocks(in: before), new = blocks(in: after)
        return Part.allCases.compactMap { part in
            guard let was = old[part], let now = new[part], was != now else { return nil }
            return (part, was, now)
        }
    }

    /// `text` with its one copy of `old` replaced by `new`, or nil when it has no copy (or more than one, which would be
    /// a guess).
    public static func applying(_ old: String, _ new: String, to text: String) -> String? {
        guard let first = text.range(of: old), text.range(of: old, range: first.upperBound ..< text.endIndex) == nil else { return nil }
        return text.replacingCharacters(in: first, with: new)
    }
}

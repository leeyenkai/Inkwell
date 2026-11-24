import Foundation

/// An inline link as written in the source: `[text](url)`, `[text](url "title")` or `<https://…>`.
public struct MarkdownLink: Sendable, Equatable {
    /// The whole link, brackets included.
    public var range: NSRange
    /// The visible text; for an autolink, the address itself.
    public var textRange: NSRange
    /// The address as written, without angle brackets or a title.
    public var urlRange: NSRange
    public var text: String
    public var url: String

    static let inlinePattern = #"(?<!\!)\[([^\]^][^\]]*)\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
    static let autoPattern = #"<((?:https?|mailto):[^>\s]+)>"#

    /// Every link on the lines touched by `range` (the whole text when nil), in order.
    public static func all(in text: String, range: NSRange? = nil) -> [MarkdownLink] {
        let ns = text as NSString
        let lines = range.map { ns.lineRange(for: NSIntersectionRange($0, NSRange(location: 0, length: ns.length))) }
            ?? NSRange(location: 0, length: ns.length)
        var links: [MarkdownLink] = []
        for m in MarkdownScanner.regex(inlinePattern)?.matches(in: text, range: lines) ?? [] {
            var urlRange = m.range(at: 2)
            if ns.character(at: urlRange.location) == 60 {
                urlRange = NSRange(location: urlRange.location + 1, length: urlRange.length - 2)
            }
            links.append(MarkdownLink(range: m.range, textRange: m.range(at: 1), urlRange: urlRange,
                                      text: ns.substring(with: m.range(at: 1)), url: ns.substring(with: urlRange)))
        }
        for m in MarkdownScanner.regex(autoPattern)?.matches(in: text, range: lines) ?? []
            where !links.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
            let url = ns.substring(with: m.range(at: 1))
            links.append(MarkdownLink(range: m.range, textRange: m.range(at: 1), urlRange: m.range(at: 1), text: url, url: url))
        }
        return links.sorted { $0.range.location < $1.range.location }
    }

    /// The link holding the selection, or the cursor inside it. A cursor just after the closing bracket is outside.
    public static func find(in text: String, at selection: NSRange) -> MarkdownLink? {
        all(in: text, range: selection).first { link in
            let r = link.range
            if selection.length == 0 { return selection.location >= r.location && selection.location < NSMaxRange(r) }
            return NSIntersectionRange(r, selection).length > 0
        }
    }

    public var isAutolink: Bool { textRange == urlRange }
}

/// What a link points to, so the editor can open it in the right place.
public enum LinkDestination: Equatable, Sendable {
    /// A heading in the same post.
    case anchor(String)
    /// A path on the site, such as `/notes/estonia/`, with any `#fragment` dropped.
    case site(String)
    case web(URL)

    public init?(_ raw: String) {
        var target = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = ["{{ site.url }}{{ site.baseurl }}", "{{ site.baseurl }}", "{{site.baseurl}}", "{{ site.url }}"]
        for prefix in prefixes where target.hasPrefix(prefix) {
            target.removeFirst(prefix.count)
        }
        if target.hasPrefix("#") {
            self = .anchor(String(target.dropFirst()))
        } else if target.hasPrefix("/"), !target.hasPrefix("//") {
            let path = target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? target
            self = .site(path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path)
        } else if let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            self = .web(url)
        } else if target.hasPrefix("//"), let url = URL(string: "https:" + target) {
            self = .web(url)
        } else {
            return nil
        }
    }
}

public enum LinkInput {
    /// The address to write for something typed or pasted into the link field: a web address, an email address
    /// (as `mailto:`), a site path or a `#heading`. Nil when it does not look like any of them.
    public static func address(from input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("mailto:") { return s.count > 7 ? s : nil }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: s)?.host.map { _ in s }
        }
        if s.hasPrefix("/") || s.hasPrefix("#") { return s.count > 1 || s == "/" ? s : nil }
        if MarkdownScanner.regex(#"^[^@\s/]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$"#)?
            .firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil {
            return "mailto:" + s
        }
        if isBareDomain(s) { return "https://" + s }
        return nil
    }

    /// True when the text is clearly meant as an address (a scheme, `www.`, an email, a path), rather than a word that
    /// happens to look like a domain.
    public static func isExplicit(_ input: String) -> Bool {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address(from: s) != nil else { return false }
        return s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("mailto:") || s.hasPrefix("www.")
            || s.hasPrefix("/") || s.hasPrefix("#") || s.contains("@") || s.contains("/")
    }

    static func isBareDomain(_ s: String) -> Bool {
        MarkdownScanner.regex(#"^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(:\d+)?([/?#]\S*)?$"#)?
            .firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}

public extension Formatting {
    /// Links the selection to `url`. Inside an existing link only the address changes; with nothing selected, `title`
    /// is inserted as the link text. The cursor ends after the link.
    static func setLink(_ text: String, selection: NSRange, url: String, title: String) -> FormattingResult {
        if let link = MarkdownLink.find(in: text, at: selection) {
            if link.isAutolink {
                let replacement = "[\(link.text)](\(url))"
                return FormattingResult(edits: [TextEdit(link.range, replacement)],
                                        selection: NSRange(location: link.range.location + (replacement as NSString).length, length: 0))
            }
            let written = url.contains(" ") ? "<\(url)>" : url
            var urlRange = link.urlRange
            if urlRange.location > 0, (text as NSString).character(at: urlRange.location - 1) == 60 {
                urlRange = NSRange(location: urlRange.location - 1, length: urlRange.length + 2)
            }
            let delta = (written as NSString).length - urlRange.length
            return FormattingResult(edits: [TextEdit(urlRange, written)],
                                    selection: NSRange(location: NSMaxRange(link.range) + delta, length: 0))
        }
        let ns = text as NSString
        var core = selection
        // Spaces at the edges stay outside the brackets, as when a word is double-clicked.
        while core.length > 0, Formatting.isSpace(ns.character(at: NSMaxRange(core) - 1)) { core.length -= 1 }
        while core.length > 0, Formatting.isSpace(ns.character(at: core.location)) {
            core.location += 1
            core.length -= 1
        }
        let label = core.length > 0 ? ns.substring(with: core) : escapeLabel(title)
        let written = url.contains(" ") ? "<\(url)>" : url
        let replacement = "[\(label)](\(written))"
        let at = core.length > 0 ? core : NSRange(location: selection.location, length: selection.length)
        return FormattingResult(edits: [TextEdit(at, replacement)],
                                selection: NSRange(location: at.location + (replacement as NSString).length, length: 0))
    }

    /// Takes the link away and keeps its text, selected.
    static func removeLink(_: String, link: MarkdownLink) -> FormattingResult {
        FormattingResult(edits: [TextEdit(link.range, link.text)],
                         selection: NSRange(location: link.range.location, length: (link.text as NSString).length))
    }

    internal static func escapeLabel(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}

/// A heading of the post with the id kramdown gives it, for `#anchor` links.
public struct HeadingAnchor: Sendable, Equatable {
    public var level: Int
    public var title: String
    public var anchor: String

    public init(level: Int, title: String, anchor: String) {
        self.level = level
        self.title = title
        self.anchor = anchor
    }

    /// Read from the rendered post, so the ids are exactly the ones the site's pages will have.
    public static func list(in markdown: String) -> [HeadingAnchor] {
        guard markdown.contains("#") || markdown.contains("\n=") || markdown.contains("\n-") else { return [] }
        let html = MarkdownRenderer().html(markdown)
        let ns = html as NSString
        let pattern = MarkdownScanner.regex(#"<h([1-6]) id="([^"]+)">(.*?)</h\1>"#)
        return (pattern?.matches(in: html, range: NSRange(location: 0, length: ns.length)) ?? [])
            .map { m in
                let title = MarkdownRenderer.decodeEntities(MarkdownRenderer.stripTags(ns.substring(with: m.range(at: 3))))
                let level = Int(ns.substring(with: m.range(at: 1))) ?? 1
                return HeadingAnchor(level: level, title: title, anchor: ns.substring(with: m.range(at: 2)))
            }
    }
}

/// One choice in the link search: an address, a post or page of the site, or a heading in this post.
public struct LinkSuggestion: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case web
        case email
        case post
        case heading
    }

    public var kind: Kind
    public var title: String
    public var detail: String
    public var url: String
    public var id: String { "\(kind)|\(url)" }

    public init(kind: Kind, title: String, detail: String, url: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.url = url
    }
}

public enum LinkSearch {
    /// A post or page that can be linked to.
    public struct Entry: Sendable, Hashable {
        public var title: String
        public var url: String
        public var detail: String
        public var date: Date?

        public init(title: String, url: String, detail: String, date: Date?) {
            self.title = title
            self.url = url
            self.detail = detail
            self.date = date
        }
    }

    /// The choices for what was typed, best first. With nothing typed, the selected text (`context`) suggests posts,
    /// and an address on the clipboard comes first.
    public static func results(query: String, context: String = "", clipboard: String? = nil, entries: [Entry],
                               headings: [HeadingAnchor], limit: Int = 12) -> [LinkSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var out: [LinkSuggestion] = []
        var address: LinkSuggestion?
        if let url = LinkInput.address(from: q) {
            address = suggestion(for: url, typed: q)
        } else if q.isEmpty, let clip = clipboard.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }), LinkInput.isExplicit(clip),
                  let url = LinkInput.address(from: clip), !url.hasPrefix("#"), !url.hasPrefix("/") {
            address = suggestion(for: url, typed: clip, fromClipboard: true)
        }
        // A typed address goes first, except a `#heading`, where the headings themselves are better matches.
        if let address, q.isEmpty || LinkInput.isExplicit(q), !q.hasPrefix("#") { out.append(address) }

        let term = q.isEmpty ? context.trimmingCharacters(in: .whitespacesAndNewlines) : q
        var posts: [(score: Int, entry: Entry)] = []
        if term.isEmpty {
            posts = entries.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.map { (0, $0) }
        } else {
            posts = entries.compactMap { e in score(e.title, term).map { ($0, e) } ?? (fold(e.url).contains(fold(term)) ? (5, e) : nil) }
            if q.isEmpty, posts.isEmpty {
                // Nothing matches the selected words: show the latest instead.
                posts = entries.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.map { (0, $0) }
            }
            posts.sort { a, b in a.score != b.score ? a.score < b.score : (a.entry.date ?? .distantPast) > (b.entry.date ?? .distantPast) }
        }
        let headingTerm = q.hasPrefix("#") ? String(q.dropFirst()) : q
        let matchingHeadings = headings.filter {
            headingTerm.isEmpty || score($0.title, headingTerm) != nil || $0.anchor.hasPrefix(fold(headingTerm))
        }
        let headingSuggestions = matchingHeadings.map {
            LinkSuggestion(kind: .heading, title: $0.title, detail: localized("In this post"), url: "#" + $0.anchor)
        }
        let postSuggestions = posts.map { LinkSuggestion(kind: .post, title: $0.entry.title, detail: $0.entry.detail, url: $0.entry.url) }
        if q.hasPrefix("#") {
            out += headingSuggestions + postSuggestions
        } else {
            let shownHeadings = headingSuggestions.prefix(4)
            out += postSuggestions.prefix(max(0, limit - out.count - shownHeadings.count)) + shownHeadings
        }
        if let address, !out.contains(address) { out.append(address) }
        var seen = Set<String>()
        return Array(out.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    static func suggestion(for url: String, typed _: String, fromClipboard: Bool = false) -> LinkSuggestion {
        if url.hasPrefix("mailto:") {
            return LinkSuggestion(kind: .email, title: String(url.dropFirst(7)), detail: localized("Email address"), url: url)
        }
        let detail = fromClipboard ? localized("Copied address") : localized("Web address")
        return LinkSuggestion(kind: .web, title: url, detail: detail, url: url)
    }

    /// Lower is better: the whole title, its start, the start of a word, then anywhere. Nil when it does not match.
    static func score(_ title: String, _ term: String) -> Int? {
        let t = fold(title), q = fold(term)
        guard !q.isEmpty else { return 0 }
        if t == q { return 0 }
        if t.hasPrefix(q) { return 1 }
        if t.range(of: " " + q) != nil || t.range(of: "-" + q) != nil { return 2 }
        if t.contains(q) { return 3 }
        // Every word typed appears somewhere in the title.
        let words = q.split(separator: " ")
        if words.count > 1, words.allSatisfy({ t.contains($0) }) { return 4 }
        return nil
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

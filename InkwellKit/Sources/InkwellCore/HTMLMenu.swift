import Foundation

/// The menu of a hand-built site: the links in a page's first `<nav>` (SPEC §4.12, W4). It is read from one page and
/// changed there, and the same change is made on every page whose menu leads to the same places. Only the items that
/// change are rewritten; the markup around and between them stays as it was.
public struct HTMLMenu: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        /// The words a reader sees.
        public var title: String
        public var address: String
        /// False when the link holds other tags (an icon, several languages); its words are then changed in the source.
        public var titleEditable: Bool
        /// The item in the page: its `<li>` when the menu is a list, otherwise the link itself.
        var unit: NSRange
        var addressRange: NSRange
        /// What is inside the `<a>`.
        var content: NSRange
    }

    /// One line of the menu as it is being edited.
    public struct Entry: Sendable, Equatable, Hashable {
        public var title: String
        public var address: String
        /// The item this entry was read from, or nil for a new one.
        public var source: Int?

        public init(title: String, address: String, source: Int? = nil) {
            self.title = title
            self.address = address
            self.source = source
        }
    }

    public var items: [Item]

    public var entries: [Entry] { items.enumerated().map { Entry(title: $1.title, address: $1.address, source: $0) } }

    /// The page's menu, or nil when it has none, or one with submenus or links without an address (edited in the source).
    public static func find(in html: String) -> HTMLMenu? {
        let ns = html as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let skipped = [#"(?is)<script\b.*?</script>"#, #"(?s)<!--.*?-->"#, #"(?is)<template\b.*?</template>"#].flatMap { pattern in
            ((try? NSRegularExpression(pattern: pattern))?.matches(in: html, range: whole) ?? []).map(\.range)
        }
        guard let navPattern = try? NSRegularExpression(pattern: #"<nav\b[^>]*>(.*?)</nav\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let nav = navPattern.matches(in: html, range: whole).first(where: { m in !skipped.contains { NSLocationInRange(m.range.location, $0) } })
        else { return nil }
        let inside = nav.range(at: 1)
        let body = ns.substring(with: inside)
        if body.components(separatedBy: "<ul").count + body.components(separatedBy: "<ol").count > 3 { return nil }

        let anchor = try? NSRegularExpression(pattern: #"<a\b[^>]*>(.*?)</a\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let href = try? NSRegularExpression(pattern: #"\shref\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: .caseInsensitive)
        let listItem = try? NSRegularExpression(pattern: #"<li\b[^>]*>.*?</li\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let anchors = anchor?.matches(in: html, range: inside) ?? []
        let lis = (listItem?.matches(in: html, range: inside) ?? []).map(\.range)
        guard !anchors.isEmpty else { return nil }

        var items: [Item] = []
        for a in anchors {
            let content = a.range(at: 1)
            let openTag = NSRange(location: a.range.location, length: content.location - a.range.location)
            guard let h = href?.firstMatch(in: html, range: openTag) else { return nil }
            let addressRange = h.range(at: 1).location != NSNotFound ? h.range(at: 1) : h.range(at: 2)
            let inner = ns.substring(with: content)
            let editable = !inner.contains("<")
            let title = normalized(HTMLHead.decode(editable ? inner : inner.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)))
            let li = lis.first { NSLocationInRange(a.range.location, $0) }
            let unit = li.flatMap { li in anchors.count(where: { NSLocationInRange($0.range.location, li) }) == 1 ? li : nil } ?? a.range
            items.append(Item(title: title, address: HTMLHead.decode(ns.substring(with: addressRange)), titleEditable: editable,
                              unit: unit, addressRange: addressRange, content: content))
        }
        return HTMLMenu(items: items)
    }

    /// Where each item leads, the same way from every page: a site path with its `#part`, or the address of another site.
    public func targets(onPage page: String) -> [String] {
        items.map { Self.target($0.address, from: page) }
    }

    public static func target(_ address: String, from page: String) -> String {
        let fragment = address.firstIndex(of: "#").map { String(address[$0...]) } ?? ""
        if address.hasPrefix("#") { return canonical(page) + fragment }
        guard let path = SiteHealth.resolve(address, from: page, baseurl: "") else { return address }
        return canonical(path) + fragment
    }

    static func canonical(_ path: String) -> String {
        var path = path
        if path == "index.html" { return "" }
        if path.hasSuffix("/index.html") { path = String(path.dropLast(10)) }
        return path
    }

    /// `html` with its menu changed from `reference` (read from `referencePage`) to `entries`, or nil when this page's
    /// menu does not lead to the same places as the reference.
    public static func applying(_ entries: [Entry], from reference: HTMLMenu, referencePage: String, to html: String, page: String) -> String? {
        guard let mine = find(in: html), mine.targets(onPage: page) == reference.targets(onPage: referencePage) else { return nil }
        guard entries != reference.entries else { return html }
        let ns = html as NSString

        func address(_ entry: Entry) -> String {
            translate(entry.address, from: referencePage, to: page)
        }

        var pieces: [String] = []
        for entry in entries {
            if let source = entry.source, mine.items.indices.contains(source) {
                let item = mine.items[source], was = reference.items[source]
                var edits: [(NSRange, String)] = []
                if entry.title != was.title, item.titleEditable {
                    edits.append((item.content, HTMLHead.escapeText(entry.title)))
                }
                if entry.address != was.address {
                    edits.append((item.addressRange, HTMLHead.escape(address(entry))))
                }
                pieces.append(replacing(edits, inUnit: item.unit, of: ns))
            } else if let template = mine.items.last {
                let edits = [(template.content, HTMLHead.escapeText(entry.title)), (template.addressRange, HTMLHead.escape(address(entry)))]
                pieces.append(withoutCurrentMarks(replacing(edits, inUnit: template.unit, of: ns)))
            }
        }

        let units = mine.items.map(\.unit)
        let gaps = zip(units, units.dropFirst()).map { ns.substring(with: NSRange(location: NSMaxRange($0), length: $1.location - NSMaxRange($0))) }
        let lineStart = ns.lineRange(for: NSRange(location: units[0].location, length: 0)).location
        let indent = ns.substring(with: NSRange(location: lineStart, length: units[0].location - lineStart))
        let fallback = indent.allSatisfy(\.isWhitespace) && !indent.isEmpty ? "\n" + indent : ""
        var joined = ""
        for (index, piece) in pieces.enumerated() {
            if index > 0 { joined += gaps.isEmpty ? fallback : gaps[min(index - 1, gaps.count - 1)] }
            joined += piece
        }
        let region = NSRange(location: units[0].location, length: NSMaxRange(units[units.count - 1]) - units[0].location)
        return ns.replacingCharacters(in: region, with: joined)
    }

    /// The unit's text with edits (ranges in the page) applied, last first so earlier ranges stay right.
    static func replacing(_ edits: [(NSRange, String)], inUnit unit: NSRange, of page: NSString) -> String {
        let text = NSMutableString(string: page.substring(with: unit))
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            text.replaceCharacters(in: NSRange(location: range.location - unit.location, length: range.length), with: replacement)
        }
        return text as String
    }

    /// A copied item must not say it is the page being read.
    static func withoutCurrentMarks(_ unit: String) -> String {
        var text = unit.replacingOccurrences(of: #"\s+aria-current\s*=\s*(?:"[^"]*"|'[^']*')"#, with: "", options: .regularExpression)
        let marks: Set = ["active", "current", "selected", "is-active", "is-current"]
        guard let classPattern = try? NSRegularExpression(pattern: #"\sclass\s*=\s*"([^"]*)""#, options: .caseInsensitive) else { return text }
        for m in classPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
            let ns = text as NSString
            let names = ns.substring(with: m.range(at: 1)).split(separator: " ").filter { !marks.contains($0.lowercased()) }
            text = ns.replacingCharacters(in: m.range, with: names.isEmpty ? "" : " class=\"\(names.joined(separator: " "))\"")
        }
        return text
    }

    /// An address typed on `from`, written so it leads to the same place from `to`.
    static func translate(_ address: String, from: String, to: String) -> String {
        guard from != to else { return address }
        if address.hasPrefix("#") { return SitePath.relative(to: from, from: to) + address }
        guard !address.hasPrefix("/"), let path = SiteHealth.resolve(address, from: from, baseurl: "") else { return address }
        let tail = address.firstIndex { $0 == "#" || $0 == "?" }.map { String(address[$0...]) } ?? ""
        return SitePath.relative(to: path, from: to) + tail
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum SitePath {
    /// The relative address of the site path `target` from the page at `page`: `about.html`, `../media/a.png`, or `./`
    /// for the site's root folder from a page beside it.
    public static func relative(to target: String, from page: String) -> String {
        let folder = page.split(separator: "/").dropLast()
        let parts = target.split(separator: "/", omittingEmptySubsequences: true)
        var shared = 0
        while shared < folder.count, shared < parts.count, folder[folder.startIndex + shared] == parts[shared],
              shared < parts.count - 1 || target.hasSuffix("/") { shared += 1 }
        let up = Array(repeating: "..", count: folder.count - shared)
        let path = (up + parts[shared...].map(String.init)).joined(separator: "/")
        if path.isEmpty { return "./" }
        let isFolder = target.hasSuffix("/") || parts[shared...].isEmpty
        return isFolder ? path + "/" : path
    }
}

import Foundation

/// One file a content change writes or removes, relative to the site root.
public struct ContentEdit: Sendable, Equatable {
    public var path: String
    /// nil removes the file.
    public var newText: String?

    public init(path: String, newText: String?) {
        self.path = path
        self.newText = newText
    }

    public func apply(to root: URL) throws {
        let url = root.appending(path: path)
        if let newText {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(newText.utf8).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Renaming a post's address or moving it to another section: the file moves, the old address can keep working through
/// `redirect_from` (the jekyll-redirect-from plugin, which GitHub Pages supports), and links in other posts follow.
public enum MovePlanner {
    public struct Plan: Sendable, Equatable {
        public var edits: [ContentEdit]
        public var newPath: String
        public var newURL: String
        public var updatedLinks: [String]
        /// Local drafts (outside the site) whose links were rewritten, with their new text.
        public var draftEdits: [DraftEdit] = []
        /// The old address could not be kept: the site's Gemfile has no jekyll-redirect-from.
        public var redirectUnavailable = false
    }

    public struct DraftEdit: Sendable, Equatable {
        public var fileURL: URL
        public var newText: String
    }

    /// `drafts` are local drafts, whose links to the post are rewritten too (in `draftEdits`, since they live outside
    /// the site).
    public static func plan(document: SiteDocument, text: String, newPath: String, keepOldAddress: Bool, site: Site, configText: String?,
                            drafts: [SiteDocument] = []) -> Plan {
        var doc = FrontMatterDocument(text: text)
        // The same rule the site loader uses, so a fixed `permalink:` keeps its address and categories stay in it.
        let values = doc.values
        let filename = (newPath as NSString).lastPathComponent
        let date = SiteLoader.date(values: values, filename: filename, config: site.config) ?? document.date
        let newURL = SiteLoader.url(relativePath: newPath, values: values, date: date, config: site.config)
        var edits: [ContentEdit] = []
        let redirects = Plugins.usable("jekyll-redirect-from", siteRoot: site.root)
        if keepOldAddress, document.url != newURL, redirects {
            var redirects = doc.value("redirect_from")?.list?.compactMap(\.string) ?? doc.value("redirect_from")?.string.map { [$0] } ?? []
            let old = localURL(document.url, site: site)
            if !redirects.contains(old) { redirects.append(old) }
            doc.set("redirect_from", raw: YAMLFormat.list(redirects))
            if let configText {
                var config = ConfigEditing(text: configText)
                if config.appendToList("plugins", item: "jekyll-redirect-from") { edits.append(ContentEdit(path: "_config.yml", newText: config.text)) }
            }
        }
        edits.append(ContentEdit(path: document.relativePath, newText: nil))
        edits.append(ContentEdit(path: newPath, newText: doc.text))

        var updated: [String] = []
        var draftEdits: [DraftEdit] = []
        func rewritten(_ body: String) -> String {
            var text = body
            if document.url != newURL { text = rewriteLinks(in: text, from: document.url, to: newURL, baseurl: site.config.baseurl) }
            return rewriteFileTags(in: text, from: document.relativePath, to: newPath)
        }
        for other in site.documents where other.relativePath != document.relativePath {
            guard let body = try? String(contentsOf: other.fileURL, encoding: .utf8) else { continue }
            let text = rewritten(body)
            if text != body {
                edits.append(ContentEdit(path: other.relativePath, newText: text))
                updated.append(other.relativePath)
            }
        }
        for draft in drafts where draft.fileURL != document.fileURL {
            guard let body = try? String(contentsOf: draft.fileURL, encoding: .utf8) else { continue }
            let text = rewritten(body)
            if text != body { draftEdits.append(DraftEdit(fileURL: draft.fileURL, newText: text)) }
        }
        var plan = Plan(edits: edits, newPath: newPath, newURL: newURL, updatedLinks: updated, draftEdits: draftEdits)
        plan.redirectUnavailable = keepOldAddress && document.url != newURL && !redirects
        return plan
    }

    /// `{% link old/path.md %}` and `{% post_url old-name %}`, which name the file and stop the build when it moves.
    public static func rewriteFileTags(in text: String, from oldPath: String, to newPath: String) -> String {
        guard oldPath != newPath else { return text }
        var result = text
        let link = #"(\{%-?\s*link\s+)"# + NSRegularExpression.escapedPattern(for: oldPath) + #"(\s*-?%\})"#
        result = result.replacingOccurrences(of: link, with: "$1" + NSRegularExpression.escapedTemplate(for: newPath) + "$2",
                                             options: .regularExpression)
        // post_url names a file in _posts without its extension (and with its subfolder inside _posts).
        func postName(_ path: String) -> String? {
            guard path.hasPrefix("_posts/") else { return nil }
            return (String(path.dropFirst(7)) as NSString).deletingPathExtension
        }
        if let old = postName(oldPath) {
            let pattern = #"\{%(-?)\s*post_url\s+"# + NSRegularExpression.escapedPattern(for: old) + #"\s*(-?)%\}"#
            let replacement = postName(newPath).map { "{%$1 post_url \(NSRegularExpression.escapedTemplate(for: $0)) $2%}" }
                ?? "{%$1 link \(NSRegularExpression.escapedTemplate(for: newPath)) $2%}"
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    /// The address without the site's baseurl, as `redirect_from` expects it.
    static func localURL(_ url: String, site: Site) -> String {
        let base = site.config.baseurl
        return !base.isEmpty && url.hasPrefix(base) ? String(url.dropFirst(base.count)) : url
    }

    /// Replaces Markdown and HTML links to `old` (with or without baseurl, trailing slash or `.html`) by `new`.
    public static func rewriteLinks(in text: String, from old: String, to new: String, baseurl: String) -> String {
        let local = !baseurl.isEmpty && old.hasPrefix(baseurl) ? String(old.dropFirst(baseurl.count)) : old
        let newLocal = !baseurl.isEmpty && new.hasPrefix(baseurl) ? String(new.dropFirst(baseurl.count)) : new
        var variants = Set([old, local])
        for v in Array(variants) {
            if v.hasSuffix("/") {
                variants.insert(String(v.dropLast()))
                variants.insert(String(v.dropLast()) + ".html")
            } else {
                variants.insert(v + "/")
            }
        }
        var result = text
        for variant in variants.sorted(by: { $0.count > $1.count }) where variant.count > 1 {
            let escaped = NSRegularExpression.escapedPattern(for: variant)
            let withBase = variant.hasPrefix(baseurl) && !baseurl.isEmpty
            let replacement = NSRegularExpression.escapedTemplate(for: withBase ? new : newLocal)
            let local = NSRegularExpression.escapedTemplate(for: newLocal)
            // Markdown ](url) and ](url#x), href="url" or href='url', and Liquid '{{ "url" | relative_url }}' and
            // {{ site.baseurl }}/url.
            var rules = [
                (##"\]\(\##(escaped)(?=[)#\s])"##, "](\(replacement)"),
                (##"href=(["'])\##(escaped)(?=\1|#)"##, "href=$1\(replacement)"),
                (##"(['"])\##(escaped)\1(\s*\|\s*(?:relative|absolute)_url)"##, "$1\(replacement)$1$2"),
            ]
            if !withBase {
                rules.append((##"(\{\{\s*site\.baseurl\s*\}\})\##(escaped)(?=[)"'#\s]|$)"##, "$1\(local)"))
            }
            for (pattern, template) in rules {
                result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
            }
        }
        return result
    }
}

/// `_config.yml` list editing that keeps the file's own style (block lists stay block lists).
public struct ConfigEditing {
    public internal(set) var lines: [String]
    let trailingNewline: Bool

    public init(text: String) {
        trailingNewline = text.hasSuffix("\n")
        var all = text.components(separatedBy: "\n")
        if trailingNewline { all.removeLast() }
        lines = all
    }

    public var text: String { lines.joined(separator: "\n") + (trailingNewline ? "\n" : "") }

    /// Adds `item` to a top-level list (`plugins:` with `- a` lines, or `plugins: [a]`, on one line or several). A single
    /// value (`plugins: jekyll-feed`) becomes a list holding it and the item. Returns false when it was there.
    @discardableResult
    public mutating func appendToList(_ key: String, item: String) -> Bool {
        let value = YAML.parse(lines.joined(separator: "\n"))[key]
        var current = value?.list?.compactMap(\.string) ?? value?.string.map { [$0] } ?? []
        let start = lines.lastIndex { $0.hasPrefix("\(key):") }
        // A flow list over several lines, which the YAML reader does not take: its items are read here.
        if let start, lines[start].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            var close = start
            while close < lines.count - 1, !lines[close].contains("]") { close += 1 }
            let joined = lines[start ... close].joined(separator: " ")
            if let open = joined.firstIndex(of: "["), let end = joined.lastIndex(of: "]"), open < end {
                current = joined[joined.index(after: open) ..< end].split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }.filter { !$0.isEmpty }
            }
        }
        if current.contains(item) { return false }
        guard let start else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("\(key):")
            lines.append("  - \(item)")
            return true
        }
        let rest = lines[start].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("[") {
            // A flow list may run over several lines; all of them are replaced by one.
            var close = start
            while close < lines.count - 1, !lines[close].contains("]") { close += 1 }
            lines.replaceSubrange(start ... close, with: ["\(key): " + YAMLFormat.list(current + [item])])
            return true
        }
        if !rest.isEmpty, !rest.hasPrefix("#") {
            lines.replaceSubrange(start ... start, with: ["\(key):"] + (current + [item]).map { "  - \(YAMLFormat.plainOrQuoted($0))" })
            return true
        }
        var end = start + 1
        var indent = "  "
        while end < lines.count {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                indent = String(line.prefix { $0 == " " })
                end += 1
            } else if trimmed.isEmpty || trimmed.hasPrefix("#") && line.hasPrefix(" ") {
                end += 1
            } else {
                break
            }
        }
        var insertAt = end
        while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        lines.insert("\(indent)- \(item)", at: insertAt)
        return true
    }
}

/// Jekyll plugins a site can use. GitHub's own Pages build has the common ones; a site with its own Gemfile (built by
/// a workflow) has only the gems listed there, and naming another in `plugins:` stops its build.
public enum Plugins {
    /// GitHub's own Pages build runs every supported plugin whatever the Gemfile says; only a site built by its own
    /// Jekyll workflow (`bundle exec jekyll`) is limited to the gems its Gemfile names.
    public static func usable(_ name: String, siteRoot: URL) -> Bool {
        guard PagesWorkflow.build(siteRoot: siteRoot) == .jekyll else { return true }
        let candidates = [siteRoot.appending(path: "Gemfile"), siteRoot.deletingLastPathComponent().appending(path: "Gemfile")]
        guard let gemfile = candidates.lazy.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first else { return true }
        let active = gemfile.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        return active.contains("github-pages") || active.contains("\"\(name)\"") || active.contains("'\(name)'")
    }
}

/// Tags across the site: where each is used, and renaming or merging one everywhere.
public enum TagIndex {
    /// The tags in a file's front matter (`tags:` list, flow list or space-separated string; `categories` too when asked).
    public static func tags(in text: String, key: String = "tags") -> [String] {
        let value = FrontMatterDocument(text: text).value(key)
        if let list = value?.list { return list.compactMap(\.string) }
        if let string = value?.string { return string.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) }
        return []
    }

    /// Tag → paths using it, from (path, text) pairs.
    public static func build(_ files: [(path: String, text: String)], key: String = "tags") -> [String: [String]] {
        var index: [String: [String]] = [:]
        for file in files {
            for tag in tags(in: file.text, key: key) { index[tag, default: []].append(file.path) }
        }
        return index
    }

    /// The file with `tag` renamed to `newTag` (merging when the file already has it), or nil when the file lacks the tag.
    /// `newTag` nil removes the tag.
    public static func rename(_ tag: String, to newTag: String?, in text: String, key: String = "tags") -> String? {
        let current = tags(in: text, key: key)
        guard current.contains(tag) else { return nil }
        var updated: [String] = []
        for t in current {
            let replacement = t == tag ? newTag : t
            if let replacement, !updated.contains(replacement) { updated.append(replacement) }
        }
        var doc = FrontMatterDocument(text: text)
        doc.set(key, raw: updated.isEmpty ? nil : YAMLFormat.list(updated))
        return doc.text
    }
}

/// A line diff for showing what changed between two versions of a post.
public enum TextDiff {
    public enum Line: Sendable, Equatable {
        case same(String)
        case added(String)
        case removed(String)
    }

    public static func lines(from old: String, to new: String) -> [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        // Longest common subsequence table; posts are short enough for the quadratic version.
        guard n * m <= 4_000_000 else { return a.map(Line.removed) + b.map(Line.added) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                result.append(.same(a[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(.removed(a[i]))
                i += 1
            } else {
                result.append(.added(b[j]))
                j += 1
            }
        }
        result += a[i...].map(Line.removed) + b[j...].map(Line.added)
        return result
    }
}

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
    }

    public static func plan(document: SiteDocument, text: String, newPath: String, keepOldAddress: Bool, site: Site, configText: String?) -> Plan {
        var doc = FrontMatterDocument(text: text)
        // The same rule the site loader uses, so a fixed `permalink:` keeps its address and categories stay in it.
        let values = doc.values
        let filename = (newPath as NSString).lastPathComponent
        let date = SiteLoader.date(values: values, filename: filename, config: site.config) ?? document.date
        let newURL = SiteLoader.url(relativePath: newPath, values: values, date: date, config: site.config)
        var edits: [ContentEdit] = []
        if keepOldAddress, document.url != newURL {
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
        if document.url != newURL {
            for other in site.documents where other.relativePath != document.relativePath {
                guard let body = try? String(contentsOf: other.fileURL, encoding: .utf8) else { continue }
                let rewritten = rewriteLinks(in: body, from: document.url, to: newURL, baseurl: site.config.baseurl)
                if rewritten != body {
                    edits.append(ContentEdit(path: other.relativePath, newText: rewritten))
                    updated.append(other.relativePath)
                }
            }
        }
        return Plan(edits: edits, newPath: newPath, newURL: newURL, updatedLinks: updated)
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
            if v.hasSuffix("/") { variants.insert(String(v.dropLast())) } else { variants.insert(v + "/") }
        }
        var result = text
        for variant in variants.sorted(by: { $0.count > $1.count }) where variant.count > 1 {
            let escaped = NSRegularExpression.escapedPattern(for: variant)
            let replacement = variant.hasPrefix(baseurl) && !baseurl.isEmpty ? new : newLocal
            // Markdown ](url) and ](url#x), href="url", and Liquid '{{ "url" | relative_url }}'.
            for (pattern, template) in [
                (##"\]\(\##(escaped)(?=[)#\s])"##, "](\(replacement)"),
                (##"href="\##(escaped)(?=["#])"##, "href=\"\(replacement)"),
                (##"(['"])\##(escaped)\1(\s*\|\s*relative_url)"##, "$1\(replacement)$1$2"),
            ] {
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

    /// Adds `item` to a top-level list (`plugins:` with `- a` lines, or `plugins: [a]`). Returns false when it was there.
    @discardableResult
    public mutating func appendToList(_ key: String, item: String) -> Bool {
        let current = YAML.parse(lines.joined(separator: "\n"))[key]?.list?.compactMap(\.string) ?? []
        if current.contains(item) { return false }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("\(key):")
            lines.append("  - \(item)")
            return true
        }
        let rest = lines[start].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("[") {
            lines[start] = "\(key): " + YAMLFormat.list(current + [item])
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

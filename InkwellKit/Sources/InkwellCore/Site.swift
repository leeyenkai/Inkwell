import Foundation

public struct SiteConfig: Sendable, Hashable {
    public var title: String
    public var description: String
    public var url: String
    public var baseurl: String
    public var markdown: String
    public var permalink: String?
    public var collections: [CollectionConfig]
    /// The site's `timezone`, which Jekyll uses for dates in URLs.
    public var timeZone: TimeZone
    public var raw: YAMLValue

    public init(yaml: YAMLValue) {
        raw = yaml
        title = yaml["title"]?.string ?? "Site"
        description = yaml["description"]?.string ?? ""
        url = yaml["url"]?.string ?? ""
        baseurl = yaml["baseurl"]?.string ?? ""
        markdown = yaml["markdown"]?.string ?? "kramdown"
        permalink = yaml["permalink"]?.string
        timeZone = yaml["timezone"]?.string.flatMap(TimeZone.init(identifier:)) ?? .current
        var collections: [CollectionConfig] = []
        if let entries = yaml["collections"]?.entries {
            for entry in entries {
                collections.append(CollectionConfig(
                    name: entry.key,
                    output: entry.value["output"]?.bool ?? false,
                    permalink: entry.value["permalink"]?.string
                ))
            }
        } else if let names = yaml["collections"]?.list {
            collections = names.compactMap(\.string).map { CollectionConfig(name: $0, output: false, permalink: nil) }
        }
        self.collections = collections
    }

    /// The `layout` a `defaults:` entry gives documents of this collection.
    public func defaultValues(forCollection name: String) -> [YAMLEntry] {
        var result: [YAMLEntry] = []
        for item in raw["defaults"]?.list ?? [] {
            let scope = item["scope"]
            let type = scope?["type"]?.string
            let path = scope?["path"]?.string ?? ""
            guard type == name || (type == nil && path.isEmpty) || (type == nil && path == "_\(name)") else { continue }
            result.append(contentsOf: item["values"]?.entries ?? [])
        }
        return result
    }

    public var exclude: [String] { raw["exclude"]?.list?.compactMap(\.string) ?? [] }
    public var plugins: [String] { raw["plugins"]?.list?.compactMap(\.string) ?? [] }
}

public struct CollectionConfig: Sendable, Hashable {
    public var name: String
    public var output: Bool
    public var permalink: String?
}

public struct NavItem: Sendable, Hashable {
    public var title: String
    public var url: String
}

public struct SiteSection: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case collection(String)
        case page(String)
        /// Standalone pages that are not in the navigation.
        case pages
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var symbol: String

    public var collectionName: String? {
        if case let .collection(name) = kind { return name }
        return nil
    }

    public var listsDocuments: Bool {
        switch kind {
        case .collection, .pages: true
        case .page: false
        }
    }

    public var folder: String? { collectionName.map { "_\($0)" } }
}

public struct SiteDocument: Identifiable, Sendable, Hashable {
    public enum Origin: Sendable, Hashable {
        case repository
        case localDraft
    }

    public var id: String
    public var sectionID: String
    public var origin: Origin
    public var fileURL: URL
    /// Where the file lives (or will live, for a local draft) relative to the site root.
    public var relativePath: String
    public var title: String
    public var date: Date?
    public var publishedFlag: Bool
    public var url: String
    public var modified: Date
    public var excerpt: String

    public var filename: String { (relativePath as NSString).lastPathComponent }
    public var isPage: Bool { !relativePath.hasPrefix("_") }
}

public struct Site: Sendable {
    public var root: URL
    public var config: SiteConfig
    public var navigation: [NavItem]
    public var sections: [SiteSection]
    public var documents: [SiteDocument]
    public var generator: String

    public var name: String {
        if let host = URL(string: config.url)?.host { return host }
        return root.lastPathComponent
    }

    public func section(_ id: String) -> SiteSection? { sections.first { $0.id == id } }

    public func documents(in sectionID: String) -> [SiteDocument] {
        documents.filter { $0.sectionID == sectionID }.sorted { ($0.date ?? .distantPast, $0.relativePath) > ($1.date ?? .distantPast, $1.relativePath) }
    }
}

public enum SiteError: Error, LocalizedError {
    case notASite(URL)

    public var errorDescription: String? {
        switch self {
        case let .notASite(url): localized("\(url.lastPathComponent) does not look like a GitHub Pages site. It has no _config.yml or home page.")
        }
    }
}

public enum SiteLoader {
    public static func load(_ root: URL) throws -> Site {
        let fm = FileManager.default
        let configURL = root.appending(path: "_config.yml")
        // GitHub Pages builds a site without _config.yml, from its Markdown and a home page.
        guard let configText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? (looksLikeSite(root) ? "" : nil) else {
            throw SiteError.notASite(root)
        }
        let config = SiteConfig(yaml: YAML.parse(configText))
        var navigation: [NavItem] = []
        if let text = try? String(contentsOf: root.appending(path: "_data/navigation.yml"), encoding: .utf8) {
            for item in YAML.parse(text).list ?? [] {
                if let title = item["title"]?.string, let url = item["url"]?.string { navigation.append(NavItem(title: title, url: url)) }
            }
        }

        var sections: [SiteSection] = []
        var documents: [SiteDocument] = []
        let collectionNames = Set(config.collections.map(\.name))
        var seenCollections = Set<String>()

        func addCollection(_ name: String, label: String) {
            guard !seenCollections.contains(name) else { return }
            seenCollections.insert(name)
            sections.append(SiteSection(id: name, label: label, kind: .collection(name), symbol: symbol(for: name)))
            let folder = root.appending(path: "_\(name)")
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where ["md", "markdown", "html"].contains(file.pathExtension.lowercased()) {
                if let doc = document(at: file, relativePath: "_\(name)/\(file.lastPathComponent)", sectionID: name, config: config) {
                    documents.append(doc)
                }
            }
        }

        for item in navigation {
            let trimmed = item.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if collectionNames.contains(trimmed) {
                addCollection(trimmed, label: item.title.capitalized)
            } else if let page = pagePath(for: item.url, root: root) {
                let id = "page:\(page)"
                sections.append(SiteSection(id: id, label: item.title.capitalized, kind: .page(page), symbol: symbol(for: trimmed.isEmpty ? "about" : trimmed)))
                if let doc = document(at: root.appending(path: page), relativePath: page, sectionID: id, config: config, url: item.url) {
                    documents.append(doc)
                }
            }
        }
        if fm.fileExists(atPath: root.appending(path: "_posts").path) {
            addCollection("posts", label: localized("Posts"))
        }
        for collection in config.collections {
            addCollection(collection.name, label: collection.name.capitalized)
        }
        // Every Jekyll site has posts; without a folder or another collection, offer a Posts section to start one.
        if !sections.contains(where: { $0.collectionName != nil }) {
            addCollection("posts", label: localized("Posts"))
        }
        let claimed = Set(documents.map(\.relativePath))
        let excluded = Set(config.exclude)
        var pages: [SiteDocument] = []
        // Pages at the root and in ordinary folders (such as albums/), not in _folders, assets or tooling.
        var pageFiles: [(URL, String)] = []
        let skipFolders: Set = ["assets", "node_modules", "vendor", "images", "img", "css", "js", "fonts"]
        func scan(_ folder: URL, prefix: String, depth: Int) {
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                let name = item.lastPathComponent
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    guard depth < 3, !name.hasPrefix("_"), !name.hasPrefix("."), !skipFolders.contains(name.lowercased()),
                          !excluded.contains(name), !excluded.contains(name + "/") else { continue }
                    scan(item, prefix: prefix + name + "/", depth: depth + 1)
                } else {
                    pageFiles.append((item, prefix + name))
                }
            }
        }
        scan(root, prefix: "", depth: 0)
        for (file, relativePath) in pageFiles.sorted(by: { $0.1 < $1.1 }) where ["md", "markdown", "html"].contains(file.pathExtension.lowercased()) {
            let name = relativePath
            guard !claimed.contains(name), !excluded.contains(name), !name.hasPrefix("_"), !name.hasPrefix("."),
                  let text = try? String(contentsOf: file, encoding: .utf8), FrontMatterDocument(text: text).hasFrontMatter,
                  let doc = document(at: file, relativePath: name, sectionID: "pages", config: config) else { continue }
            pages.append(doc)
        }
        if !pages.isEmpty {
            sections.append(SiteSection(id: "pages", label: localized("Pages"), kind: .pages, symbol: "doc.richtext"))
            documents += pages
        }
        return Site(root: root, config: config, navigation: navigation, sections: sections, documents: documents, generator: "Jekyll")
    }

    /// A `_config.yml`, or a home page GitHub Pages can build on its own.
    public static func looksLikeSite(_ root: URL) -> Bool {
        ["_config.yml", "index.md", "index.markdown", "index.html", "README.md"].contains {
            FileManager.default.fileExists(atPath: root.appending(path: $0).path)
        }
    }

    static func pagePath(for url: String, root: URL) -> String? {
        let trimmed = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidates = trimmed.isEmpty
            ? ["index.md", "index.markdown", "index.html"]
            : ["\(trimmed).md", "\(trimmed).markdown", "\(trimmed).html", "\(trimmed)/index.md", "\(trimmed)/index.html"]
        return candidates.first { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }
    }

    public static func document(at file: URL, relativePath: String, sectionID: String, config: SiteConfig, url: String? = nil,
                                origin: SiteDocument.Origin = .repository) -> SiteDocument? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return document(text: text, fileURL: file, relativePath: relativePath, sectionID: sectionID, config: config, url: url,
                        origin: origin, modified: modified)
    }

    public static func document(text: String, fileURL: URL, relativePath: String, sectionID: String, config: SiteConfig,
                                url: String? = nil, origin: SiteDocument.Origin, modified: Date) -> SiteDocument {
        let doc = FrontMatterDocument(text: text)
        let values = doc.values
        let filename = (relativePath as NSString).lastPathComponent
        let parsedName = Filename.parse(filename)
        let title = values["title"]?.string ?? parsedName.slug.replacingOccurrences(of: "-", with: " ").capitalized
        let date = values["date"]?.string.flatMap { SiteDate.parse($0, timeZone: config.timeZone) } ?? parsedName.date
        let published = values["published"]?.bool ?? true
        let collection = relativePath.hasPrefix("_") ? String(relativePath.dropFirst().prefix { $0 != "/" }) : nil
        let categories = Permalink.categories(values)
        let resolvedURL = url ?? values["permalink"]?.string.map { config.baseurl + $0 }
            ?? collection.map { Permalink.url(collection: $0, filename: filename, date: date, config: config, categories: categories) }
            ?? Permalink.pageURL(relativePath: relativePath, config: config)
        return SiteDocument(
            id: origin == .repository ? "repo:\(relativePath)" : "draft:\(fileURL.path)",
            sectionID: sectionID, origin: origin, fileURL: fileURL, relativePath: relativePath, title: title, date: date,
            publishedFlag: published, url: resolvedURL, modified: modified, excerpt: Excerpt.make(doc.body)
        )
    }

    static func symbol(for name: String) -> String {
        switch name.lowercased() {
        case "about", "", "index": "house"
        case "notes", "essays", "posts", "blog": "note.text"
        case "sidenotes", "links", "quotes": "text.bubble"
        case "travel": "airplane"
        case "photos", "gallery": "photo.on.rectangle"
        default: "doc.text"
        }
    }
}

public enum Excerpt {
    public static func make(_ body: String, limit: Int = 140) -> String {
        var text = body
        let patterns = [
            #"\{%.*?%\}"#, #"\{\{.*?\}\}"#, #"!\[[^\]]*\]\([^)]*\)"#, #"<[^>]+>"#, #"\[\^[^\]]+\]:?"#,
        ]
        for pattern in patterns { text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}((#{1,6}|>|[-*+]|\d+\.)\s*)+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_~`\\]"#, with: "", options: .regularExpression)
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > limit ? String(words.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : words
    }
}

public enum Filename {
    public struct Parts: Sendable, Equatable {
        public var date: Date?
        public var dateText: String?
        public var slug: String
        public var ext: String
        public var isZeroPadded: Bool
    }

    public static func parse(_ filename: String) -> Parts {
        let ext = (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        let pattern = #"^(\d{4})-(\d{1,2})-(\d{1,2})-(.+)$"#
        if let match = base.range(of: pattern, options: .regularExpression), match == base.startIndex ..< base.endIndex {
            let pieces = base.split(separator: "-", maxSplits: 3).map(String.init)
            let dateText = "\(pieces[0])-\(pieces[1])-\(pieces[2])"
            let padded = pieces[1].count == 2 && pieces[2].count == 2
            return Parts(date: SiteDate.parse(dateText), dateText: dateText, slug: pieces[3], ext: ext, isZeroPadded: padded)
        }
        return Parts(date: nil, dateText: nil, slug: base, ext: ext, isZeroPadded: true)
    }

    /// The date is the site's calendar day (its `timezone:`), so it matches the `date:` written in the front matter.
    public static func make(date: Date, slug: String, ext: String = "md", timeZone: TimeZone = .current) -> String {
        "\(YAMLFormat.date(date, timeZone: timeZone))-\(slug).\(ext)"
    }
}

public enum Slug {
    public static func make(_ title: String, maxWords: Int = 8) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let slug = words.prefix(maxWords).joined(separator: "-")
        return slug.isEmpty ? "untitled" : slug
    }
}

public enum Permalink {
    /// Jekyll's built-in permalink styles.
    public static func expand(_ style: String) -> String {
        switch style {
        case "date": "/:categories/:year/:month/:day/:title:output_ext"
        case "pretty": "/:categories/:year/:month/:day/:title/"
        case "ordinal": "/:categories/:year/:y_day/:title:output_ext"
        case "none": "/:categories/:title:output_ext"
        default: style
        }
    }

    /// The pattern for a collection: its own `permalink`, posts follow the site's style, and other collections
    /// get `/:collection/:path` with the site style's ending, as Jekyll does.
    public static func pattern(collection: String, config: SiteConfig) -> String {
        if let own = config.collections.first(where: { $0.name == collection })?.permalink { return expand(own) }
        let site = expand(config.permalink ?? "date")
        if collection == "posts" { return site }
        return site.hasSuffix("/") ? "/:collection/:path/" : "/:collection/:path:output_ext"
    }

    public static func url(collection: String, filename: String, date: Date?, config: SiteConfig, categories: [String] = []) -> String {
        let pattern = pattern(collection: collection, config: config)
        let parts = Filename.parse(filename)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = config.timeZone
        let c = date.map { calendar.dateComponents([.year, .month, .day, .dayOfYear], from: $0) }
        let name = (filename as NSString).deletingPathExtension
        let replacements: [(String, String)] = [
            (":collection", collection),
            (":categories", categories.map { $0.lowercased().replacingOccurrences(of: " ", with: "-") }.joined(separator: "/")),
            (":title", parts.slug),
            (":slug", parts.slug),
            (":name", name),
            (":path", name),
            (":year", c?.year.map { String(format: "%04d", $0) } ?? ""),
            (":short_year", c?.year.map { String(format: "%02d", $0 % 100) } ?? ""),
            (":month", c?.month.map { String(format: "%02d", $0) } ?? ""),
            (":i_month", c?.month.map(String.init) ?? ""),
            (":day", c?.day.map { String(format: "%02d", $0) } ?? ""),
            (":i_day", c?.day.map(String.init) ?? ""),
            (":y_day", c?.dayOfYear.map { String(format: "%03d", $0) } ?? ""),
            (":output_ext", ".html"),
        ]
        var url = pattern
        for (key, value) in replacements { url = url.replacingOccurrences(of: key, with: value) }
        while url.contains("//") { url = url.replacingOccurrences(of: "//", with: "/") }
        return config.baseurl + url
    }

    /// A standalone page's address: `/` for the home page, `/about/` with pretty permalinks, `/about.html` otherwise.
    public static func pageURL(relativePath: String, config: SiteConfig) -> String {
        let base = (relativePath as NSString).deletingPathExtension
        if base == "index" { return config.baseurl + "/" }
        if base.hasSuffix("/index") { return config.baseurl + "/" + base.dropLast(5) }
        return config.baseurl + "/" + base + (config.permalink == "pretty" ? "/" : ".html")
    }

    static func categories(_ values: YAMLValue) -> [String] {
        if let list = values["categories"]?.list { return list.compactMap(\.string) }
        if let text = values["categories"]?.string ?? values["category"]?.string {
            return text.split(separator: " ").map(String.init)
        }
        return []
    }

    /// The address a reader sees, such as `leeyenkai.github.io/notes/morality/`.
    public static func display(_ url: String, config: SiteConfig) -> String {
        let host = URL(string: config.url)?.host ?? ""
        return host + url
    }
}

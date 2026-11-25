import Foundation

/// Checks the whole site for problems a visitor or search engine would notice, each with a fix where one is safe.
/// Fixes are file edits that become unpublished changes, so nothing goes live without review.
public enum SiteHealth {
    public enum Category: String, Sendable, CaseIterable, Identifiable {
        case content, links, media, sharing, repository
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .content: localized("Posts and pages")
            case .links: localized("Links")
            case .media: localized("Images and size")
            case .sharing: localized("Search and sharing")
            case .repository: localized("Repository")
            }
        }
    }

    public enum Severity: Int, Sendable, Comparable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Fix: Sendable, Equatable {
        /// File changes, described in a few words ("Adds jekyll-feed to _config.yml").
        case edits([ContentEdit], summary: String)
        /// Settings has the field for it (site description, share image, favicon).
        case openSettings
    }

    public struct Issue: Sendable, Equatable, Identifiable {
        public var id: String
        public var category: Category
        public var severity: Severity
        public var title: String
        public var detail: String
        /// Files the issue is about, to open from the panel.
        public var paths: [String]
        public var fix: Fix?

        public init(id: String, category: Category, severity: Severity, title: String, detail: String, paths: [String], fix: Fix?) {
            self.id = id
            self.category = category
            self.severity = severity
            self.title = title
            self.detail = detail
            self.paths = paths
            self.fix = fix
        }
    }

    public struct Report: Sendable, Equatable {
        public var issues: [Issue]
        public var problems: Int { issues.filter { $0.severity > .info }.count }
    }

    public static func check(_ site: Site) -> Report {
        var issues: [Issue] = []
        let files = FileIndex(root: site.root)
        var texts: [String: String] = [:]
        for doc in site.documents {
            texts[doc.relativePath] = try? String(contentsOf: doc.fileURL, encoding: .utf8)
        }
        issues += content(site, texts: texts)
        issues += links(site, texts: texts, files: files)
        issues += media(site, texts: texts, files: files)
        issues += staticPages(site, texts: texts, files: files)
        // Its fixes add Jekyll plugins and tags, which a site served as it is would show as text.
        if !site.kind.servesFilesAsIs { issues += sharing(site, files: files) }
        issues += repository(site, files: files)
        let order = Dictionary(uniqueKeysWithValues: Category.allCases.enumerated().map { ($1, $0) })
        issues.sort { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if a.category != b.category { return order[a.category, default: 0] < order[b.category, default: 0] }
            return a.id < b.id
        }
        return Report(issues: issues)
    }

    // MARK: Posts and pages

    static let placeholders = ["lorem ipsum", "coming soon", "your content here", "todo:", "tk tk"]

    static func content(_ site: Site, texts: [String: String]) -> [Issue] {
        var issues: [Issue] = []
        for doc in site.documents {
            guard let text = texts[doc.relativePath] else { continue }
            let front = FrontMatterDocument(text: text)
            let found = doc.isStatic ? [] : Validation.frontMatter(front, filename: doc.filename, inCollection: !doc.isPage)
            if !found.isEmpty {
                issues.append(Issue(id: "fm:\(doc.relativePath)", category: .content,
                                    severity: found.contains { $0.severity == .error } ? .error : .warning,
                                    title: localized("Properties need attention in “\(doc.title)”"), detail: found.map(\.message).joined(separator: "\n"),
                                    paths: [doc.relativePath], fix: nil))
            }
            guard doc.publishedFlag else { continue }
            let body = front.body.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = body.lowercased()
            if !doc.isPage, body.isEmpty {
                issues.append(Issue(id: "empty:\(doc.relativePath)", category: .content, severity: .warning, title: localized("“\(doc.title)” is empty"),
                                    detail: localized("It is live on the site with no text."), paths: [doc.relativePath], fix: nil))
            } else if let phrase = placeholders.first(where: { lower.contains($0) }) {
                issues.append(Issue(id: "placeholder:\(doc.relativePath)", category: .content, severity: .warning,
                                    title: localized("“\(doc.title)” has placeholder text"),
                                    detail: localized("It is live and contains “\(phrase)”."),
                                    paths: [doc.relativePath], fix: nil))
            }
        }
        var byURL: [String: [SiteDocument]] = [:]
        for doc in site.documents where doc.publishedFlag && !doc.url.isEmpty {
            byURL[normalized(doc.url), default: []].append(doc)
        }
        for (url, docs) in byURL where docs.count > 1 {
            issues.append(Issue(id: "dup:\(url)", category: .content, severity: .error, title: localized("\(docs.count) files share the address \(url)"),
                                detail: localized("Only one of them appears on the site. Rename or move the others."),
                                paths: docs.map(\.relativePath).sorted(), fix: nil))
        }
        return issues
    }

    public static func normalized(_ url: String) -> String {
        var u = url.lowercased()
        if u.hasSuffix("/index.html") { u = String(u.dropLast("index.html".count)) }
        if u.hasSuffix(".html") { u = String(u.dropLast(5)) }
        return u.hasSuffix("/") ? u : u + "/"
    }

    // MARK: Links

    /// Internal links and images that point at nothing in the site.
    static func links(_ site: Site, texts: [String: String], files: FileIndex) -> [Issue] {
        let known = Set(site.documents.map { normalized(localPath($0.url, site: site)) })
        var issues: [Issue] = []
        for doc in site.documents where !doc.isStatic {
            guard let text = texts[doc.relativePath] else { continue }
            let body = FrontMatterDocument(text: text).body
            var broken: [String] = []
            for target in internalLinks(in: body) {
                let path = localPath(target, site: site)
                if known.contains(normalized(path)) || files.exists(path) || files.exists(path + ".md") || files.exists(path + ".html")
                    || files.exists(path + "/index.html") || files.exists(path + "/index.md") { continue }
                if !broken.contains(target) { broken.append(target) }
            }
            if !broken.isEmpty {
                issues.append(Issue(id: "links:\(doc.relativePath)", category: .links, severity: .warning,
                                    title: localized("\(broken.count) links in “\(doc.title)” go nowhere"),
                                    detail: broken.joined(separator: "\n"), paths: [doc.relativePath], fix: nil))
            }
            let missing = ContentChecks.images(in: body).map(\.path).filter { path in
                guard path.hasPrefix("/"), !path.hasPrefix("//") else { return false }
                return !files.exists(localPath(path, site: site))
            }
            if !missing.isEmpty {
                issues.append(Issue(id: "images:\(doc.relativePath)", category: .links, severity: .error,
                                    title: localized("\(missing.count) images in “\(doc.title)” are missing"),
                                    detail: missing.joined(separator: "\n"), paths: [doc.relativePath], fix: nil))
            }
        }
        return issues
    }

    /// `[text](/path)` and `href="/path"`, site-relative only, without anchors or queries.
    public static func internalLinks(in original: String) -> [String] {
        let body = ContentChecks.masked(original)
        let patterns = [#"(?<!\!)\[[^\]]*\]\(\s*(\{\{.*?\}\}|/[^)\s]*)"#, #"<a\b[^>]*href\s*=\s*["'](/[^"'#?]*)"#]
        let ns = body as NSString
        var result: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                var target = ContentChecks.plainPath(ns.substring(with: m.range(at: 1)))
                if let cut = target.firstIndex(where: { $0 == "#" || $0 == "?" }) { target = String(target[..<cut]) }
                guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("{{"), !target.contains("{%") else { continue }
                result.append(target)
            }
        }
        return result
    }

    /// Links to other sites, each with the files that use it, for the on-request check.
    public static func externalLinks(_ site: Site) -> [String: [String]] {
        let pattern = #"(?:\]\(\s*|href\s*=\s*["'])(https?://[^)\s"'<>]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [:] }
        var result: [String: [String]] = [:]
        for doc in site.documents {
            guard let text = try? String(contentsOf: doc.fileURL, encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let url = ns.substring(with: m.range(at: 1))
                if result[url]?.contains(doc.relativePath) != true { result[url, default: []].append(doc.relativePath) }
            }
        }
        return result
    }

    static func localPath(_ url: String, site: Site) -> String {
        let base = site.config.baseurl
        let local = !base.isEmpty && url.hasPrefix(base + "/") ? String(url.dropFirst(base.count)) : url
        return local.removingPercentEncoding ?? local
    }

    // MARK: Images and size

    static let largeImage = 1_000_000
    static let githubWarnFile = 50_000_000
    static let pagesLimit = 1_000_000_000

    static func media(_ site: Site, texts: [String: String], files: FileIndex) -> [Issue] {
        var issues: [Issue] = []
        for doc in site.documents where doc.publishedFlag && !doc.isStatic {
            guard let text = texts[doc.relativePath] else { continue }
            let missing = ContentChecks.images(in: FrontMatterDocument(text: text).body).filter { $0.alt.trimmingCharacters(in: .whitespaces).isEmpty }
            if !missing.isEmpty {
                issues.append(Issue(id: "alt:\(doc.relativePath)", category: .media, severity: .warning,
                                    title: localized("\(missing.count) images in “\(doc.title)” have no alt text"),
                                    detail: (missing.count == 1 ? localized("People using screen readers hear nothing for it.")
                                        : localized("People using screen readers hear nothing for them.")) + " "
                                        + missing.map(\.path).joined(separator: ", "),
                                    paths: [doc.relativePath], fix: nil))
            }
        }
        let images = files.sizes.filter { MediaLibrary.imageExtensions.contains(($0.key as NSString).pathExtension.lowercased()) && $0.value > largeImage }
        if !images.isEmpty {
            let list = images.sorted { $0.value > $1.value }.map { "\($0.key) (\(megabytes($0.value)))" }
            issues.append(Issue(id: "large-images", category: .media, severity: .warning,
                                title: localized("\(images.count) images are over 1 MB"),
                                detail: localized("Large pictures load slowly on phones. Replace them from Media; Inkwell resizes new ones.") + "\n"
                                    + list.joined(separator: "\n"),
                                paths: images.keys.sorted(), fix: nil))
        }
        let huge = files.sizes.filter { $0.value > githubWarnFile }
        if !huge.isEmpty {
            issues.append(Issue(id: "huge-files", category: .media, severity: .error, title: localized("Files too large for GitHub"),
                                detail: localized("GitHub warns above 50 MB and refuses files over 100 MB.") + "\n"
                                    + huge.keys.sorted().map { "\($0) (\(megabytes(huge[$0] ?? 0)))" }.joined(separator: "\n"),
                                paths: huge.keys.sorted(), fix: nil))
        }
        let total = files.sizes.values.reduce(0, +)
        if total > pagesLimit * 3 / 4 {
            issues.append(Issue(id: "site-size", category: .media, severity: total > pagesLimit ? .error : .warning,
                                title: localized("The site is \(megabytes(total))"),
                                detail: localized("GitHub Pages sites should stay under 1 GB. Delete unused images from Media."), paths: [], fix: nil))
        }
        return issues
    }

    static func megabytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Search and sharing

    static func sharing(_ site: Site, files: FileIndex) -> [Issue] {
        var issues: [Issue] = []
        let config = site.config
        let plugins = Set(config.plugins + (config.raw["gems"]?.list?.compactMap(\.string) ?? []))
        let head = HeadFiles(root: site.root)
        let usesThemeHead = head.file == nil && (config.raw["theme"] != nil || config.raw["remote_theme"] != nil)
        let configText = (try? String(contentsOf: site.root.appending(path: "_config.yml"), encoding: .utf8)) ?? ""

        func pluginFix(_ plugin: String, tag: String?, summary: String) -> Fix? {
            var edits: [ContentEdit] = []
            var config = ConfigEditing(text: configText)
            if config.appendToList("plugins", item: plugin) { edits.append(ContentEdit(path: "_config.yml", newText: config.text)) }
            if let tag, let insert = head.inserting(tag) { edits.append(insert) }
            return edits.isEmpty ? nil : .edits(edits, summary: summary)
        }

        let handWrittenSEO = head.text.contains("name=\"description\"") && head.text.contains("og:")
        let seoTag = head.text.contains("{% seo") || usesThemeHead
        if !handWrittenSEO, !(plugins.contains("jekyll-seo-tag") && seoTag) {
            issues.append(Issue(id: "seo-tag", category: .sharing, severity: .warning, title: localized("Pages have no description or share preview tags"),
                                detail: localized("""
                                    Search engines and link previews read these. The jekyll-seo-tag plugin writes them from each post’s \
                                    title, description and image.
                                    """),
                                paths: [], fix: pluginFix("jekyll-seo-tag", tag: seoTag ? nil : "{% seo %}",
                                                          summary: seoTag ? localized("Adds jekyll-seo-tag to _config.yml")
                                                              : localized("Adds jekyll-seo-tag to _config.yml and {% seo %} to the page head"))))
        }
        if config.description.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(Issue(id: "description", category: .sharing, severity: .warning, title: localized("The site has no description"),
                                detail: localized("It is shown in search results and when the home page is shared."), paths: [], fix: .openSettings))
        }
        let shareImage = config.raw["image"] != nil || config.raw["logo"] != nil || config.raw["inkwell"]?["social_image"]?.string?.isEmpty == false
            || (head.text.contains("og:image") && !head.text.contains("site.inkwell.social_image"))
        if !shareImage {
            issues.append(Issue(id: "share-image", category: .sharing, severity: .info, title: localized("No share image"),
                                detail: localized("Links to your site show this picture when no post has its own."), paths: [], fix: .openSettings))
        }
        let feedFiles = ["feed.xml", "atom.xml", "rss.xml", "feed/index.xml", "index.xml"]
        if !plugins.contains("jekyll-feed"), !feedFiles.contains(where: files.exists) {
            issues.append(Issue(id: "feed", category: .sharing, severity: .warning, title: localized("No RSS feed"),
                                detail: localized("Readers who follow sites in a feed reader cannot subscribe."),
                                paths: [], fix: pluginFix("jekyll-feed", tag: usesThemeHead ? nil : "{% feed_meta %}",
                                                          summary: usesThemeHead ? localized("Adds jekyll-feed to _config.yml")
                                                              : localized("Adds jekyll-feed to _config.yml and a feed link to the page head"))))
        }
        if !plugins.contains("jekyll-sitemap"), !files.exists("sitemap.xml") {
            issues.append(Issue(id: "sitemap", category: .sharing, severity: .info, title: localized("No sitemap"),
                                detail: localized("A sitemap helps search engines find every page."),
                                paths: [], fix: pluginFix("jekyll-sitemap", tag: nil, summary: localized("Adds jekyll-sitemap to _config.yml"))))
        }
        let iconFiles = ["favicon.ico", "favicon.png", "favicon.svg", "assets/favicon.png", "assets/favicon.ico", "assets/favicon.svg"]
        let iconInHead = head.text.range(of: #"rel=["'](shortcut )?icon["']"#, options: .regularExpression) != nil
            && !head.text.contains("site.inkwell.favicon")
        if !iconFiles.contains(where: files.exists), !iconInHead, config.raw["inkwell"]?["favicon"]?.string?.isEmpty != false {
            issues.append(Issue(id: "favicon", category: .sharing, severity: .info, title: localized("No favicon"),
                                detail: localized("Browsers show a blank icon in tabs and bookmarks."), paths: [], fix: .openSettings))
        }
        if !["404.html", "404.md", "404.markdown"].contains(where: files.exists) {
            issues.append(Issue(id: "404", category: .sharing, severity: .info, title: localized("No page for missing addresses"),
                                detail: localized("Mistyped links show GitHub’s plain 404 page instead of one in your site’s style."),
                                paths: [], fix: .edits([ContentEdit(path: "404.md", newText: notFoundPage)], summary: localized("Adds 404.md"))))
        }
        return issues
    }

    static let notFoundPage = """
    ---
    layout: default
    title: Page not found
    permalink: /404.html
    ---

    # Page not found

    The page you were looking for is not here. [Go to the home page]({{ '/' | relative_url }}).

    """

    /// `tag` added before `</head>` in the site's own head file. A site on a gem theme has none; its theme's head hook
    /// (`head-custom.html` in GitHub's themes, `custom-head.html` in minima) gets the tag instead.
    public static func headInsertion(root: URL, tag: String) -> [ContentEdit] {
        let head = HeadFiles(root: root)
        if head.text.contains(tag) { return [] }
        if let edit = head.inserting(tag) { return [edit] }
        return ["_includes/head-custom.html", "_includes/custom-head.html"].map { path in
            let old = (try? String(contentsOf: root.appending(path: path), encoding: .utf8)) ?? ""
            return ContentEdit(path: path, newText: old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + tag + "\n")
        }
    }

    /// The local file that holds `</head>`, if the site has its own layouts.
    struct HeadFiles {
        var file: String?
        var original = ""
        var text = ""

        init(root: URL) {
            let fm = FileManager.default
            var candidates = ["_includes/head.html", "_includes/head-custom.html", "_layouts/default.html"]
            candidates += ((try? fm.contentsOfDirectory(atPath: root.appending(path: "_layouts").path)) ?? []).sorted().map { "_layouts/\($0)" }
            candidates += ((try? fm.contentsOfDirectory(atPath: root.appending(path: "_includes").path)) ?? []).sorted().map { "_includes/\($0)" }
            var seen = Set<String>()
            for path in candidates where seen.insert(path).inserted {
                guard let content = try? String(contentsOf: root.appending(path: path), encoding: .utf8) else { continue }
                text += content + "\n"
                if file == nil, content.range(of: "</head>", options: .caseInsensitive) != nil {
                    file = path
                    original = content
                }
            }
        }

        /// The head file with `tag` on its own line just before `</head>`, matching the indentation of the line above.
        func inserting(_ tag: String) -> ContentEdit? {
            guard let file, let close = original.range(of: "</head>", options: [.caseInsensitive, .backwards]) else { return nil }
            let lineStart = original[..<close.lowerBound].lastIndex(of: "\n").map { original.index(after: $0) } ?? original.startIndex
            let indent = String(original[lineStart ..< close.lowerBound].prefix { $0 == " " || $0 == "\t" })
            // The line above sets the indentation, when it is inside the head.
            let above = original[..<lineStart].split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            let aboveIndent = String(above.prefix { $0 == " " || $0 == "\t" })
            let inner = aboveIndent.count > indent.count && !above.lowercased().contains("<head") ? aboveIndent : indent + "  "
            let updated = String(original[..<lineStart]) + inner + tag + "\n" + String(original[lineStart...])
            return ContentEdit(path: file, newText: updated)
        }
    }

    // MARK: Repository

    static let gitignoreLines = ["_site/", ".sass-cache/", ".jekyll-cache/", ".jekyll-metadata", ".DS_Store", "vendor/", ".bundle/"]

    static func repository(_ site: Site, files: FileIndex) -> [Issue] {
        var issues: [Issue] = []
        let gitignore = (try? String(contentsOf: site.root.appending(path: ".gitignore"), encoding: .utf8))
        let ignored = Set((gitignore ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        func withIgnores(_ entries: [String]) -> ContentEdit? {
            let missing = entries.filter {
                !ignored.contains($0) && !ignored.contains("/" + $0) && !ignored.contains($0.replacingOccurrences(of: "/", with: ""))
            }
            guard !missing.isEmpty else { return nil }
            var text = gitignore ?? ""
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            return ContentEdit(path: ".gitignore", newText: text + missing.joined(separator: "\n") + "\n")
        }
        let built = files.sizes.keys.filter { $0.hasPrefix("_site/") }.sorted()
        if !built.isEmpty, !ignored.contains("_site/"), !ignored.contains("_site") {
            issues.append(Issue(id: "site-folder", category: .repository, severity: .warning, title: localized("Built pages are in the repository"),
                                detail: localized("""
                                    The _site folder (\(built.count) files) is Jekyll’s output. GitHub Pages builds its own, so this copy \
                                    only adds size.
                                    """),
                                paths: [], fix: .edits(built.map { ContentEdit(path: $0, newText: nil) } + [withIgnores(["_site/"])].compactMap { $0 },
                                                       summary: localized("Removes _site (\(built.count) files) and ignores it from now on"))))
        }
        let finder = files.sizes.keys.filter { ($0 as NSString).lastPathComponent == ".DS_Store" }.sorted()
        if !finder.isEmpty, !ignored.contains(".DS_Store") {
            issues.append(Issue(id: "ds-store", category: .repository, severity: .info, title: localized("Finder files are in the repository"),
                                detail: finder.joined(separator: "\n"),
                                paths: [], fix: .edits(finder.map { ContentEdit(path: $0, newText: nil) } + [withIgnores([".DS_Store"])].compactMap { $0 },
                                                       summary: localized("Removes \(finder.count) .DS_Store files and ignores them"))))
        }
        // The suggested lines are for Jekyll's build files, which a site served as it is does not make.
        if gitignore == nil, !site.kind.servesFilesAsIs {
            issues.append(Issue(id: "gitignore", category: .repository, severity: .info, title: localized("No .gitignore"),
                                detail: localized("Without one, build output and system files can end up in the repository."),
                                paths: [], fix: withIgnores(gitignoreLines).map { .edits([$0], summary: localized("Adds a .gitignore for Jekyll sites")) }))
        }
        return issues
    }

    /// Every file under the site root with its size, hidden ones included, the `.git` folder excluded.
    struct FileIndex {
        var sizes: [String: Int] = [:]

        init(root: URL) {
            let fm = FileManager.default
            let rootPath = root.standardizedFileURL.path
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return }
            for case let url as URL in enumerator {
                let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                if relative == ".git" || relative.hasPrefix("node_modules") || relative.hasPrefix("vendor/") || relative == ".jekyll-cache" {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { sizes[relative] = values?.fileSize ?? 0 }
            }
        }

        func exists(_ path: String) -> Bool {
            let trimmed = String(path.drop { $0 == "/" })
            return sizes[trimmed] != nil
        }
    }
}

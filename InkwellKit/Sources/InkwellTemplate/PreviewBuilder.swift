import Foundation
import InkwellCore
import InkwellMarkdown

public struct PreviewPage: Sendable {
    public init(html: String, unsupportedTags: [String]) {
        self.html = html
        self.unsupportedTags = unsupportedTags
    }

    public var html: String
    /// Liquid tags the instant preview does not run; the exact build may show more than the preview.
    public var unsupportedTags: [String]
}

/// Renders a page the way Jekyll would: Liquid in the body, then Markdown, then the layout chain from `_layouts/`.
/// The site object (config, data files and every collection with its rendered content) is built once per site load.
public final class PreviewBuilder: @unchecked Sendable {
    public let site: Site
    let renderer = MarkdownRenderer()
    let timeZone: TimeZone
    /// A theme's own files (gem or remote theme), used when the site does not have a layout or include itself.
    public let themeRoot: URL?
    private(set) var siteValue: LiquidValue = .null
    private var layouts: [String: (FrontMatterDocument, LiquidTemplate)?] = [:]
    private let lock = NSRecursiveLock()

    public init(site: Site, timeZone: TimeZone = .current, themeRoot: URL? = nil) {
        self.site = site
        self.timeZone = timeZone
        self.themeRoot = themeRoot
        siteValue = buildSite()
    }

    /// The page a URL leads to on the built site, rendered, or nil when no page has that address.
    public func page(at url: String) -> PreviewPage? {
        let base = site.config.baseurl
        func local(_ u: String) -> String { !base.isEmpty && u.hasPrefix(base) ? String(u.dropFirst(base.count)) : u }
        let wanted = Self.normalize(local(url))
        // Files without front matter, and every file on a site Jekyll does not build, are served as they are.
        guard !site.kind.servesFilesAsIs,
              let doc = site.documents.first(where: { !$0.isStatic && Self.normalize(local($0.url)) == wanted }),
              let text = try? String(contentsOf: doc.fileURL, encoding: .utf8) else { return nil }
        return render(text: text, relativePath: doc.relativePath, url: doc.url)
    }

    /// `/notes/`, `/notes`, `/notes.html` and `/notes/index.html` are one address.
    static func normalize(_ url: String) -> String {
        var u = url.components(separatedBy: "#")[0].components(separatedBy: "?")[0]
        if u.hasSuffix("/index.html") { u = String(u.dropLast(10)) }
        if u.hasSuffix(".html") { u = String(u.dropLast(5)) }
        while u.count > 1, u.hasSuffix("/") { u.removeLast() }
        return u.isEmpty ? "/" : u
    }

    public func render(text: String, relativePath: String, url: String) -> PreviewPage {
        let doc = FrontMatterDocument(text: text)
        let collection = relativePath.hasPrefix("_") ? String(relativePath.dropFirst().prefix { $0 != "/" }) : nil
        var page = pageVariables(doc: doc, relativePath: relativePath, url: url, collection: collection)
        let template = LiquidTemplate(doc.body)
        var unsupported = template.unsupportedTags
        let context = makeContext(page: page)
        var html = template.render(context)
        if isMarkdown(relativePath) { html = renderer.html(html) }
        page["content"] = .string(html)

        var layoutName = page["layout"]?.text ?? defaultLayout(relativePath: relativePath, collection: collection)
        var depth = 0
        while let name = layoutName, !name.isEmpty, name != "none", name != "null", depth < 8, let (layoutDoc, layoutTemplate) = layout(name) {
            unsupported.append(contentsOf: layoutTemplate.unsupportedTags.filter { !unsupported.contains($0) })
            let ctx = makeContext(page: page)
            ctx["content"] = .string(html)
            ctx["layout"] = LiquidValue(layoutDoc.values)
            html = layoutTemplate.render(ctx)
            layoutName = layoutDoc.value("layout")?.string
            depth += 1
        }
        return PreviewPage(html: html, unsupportedTags: unsupported)
    }

    /// The post's own HTML without layouts, for checks such as links and word counts.
    public func bodyHTML(text: String, relativePath: String, url: String) -> String {
        let doc = FrontMatterDocument(text: text)
        let collection = relativePath.hasPrefix("_") ? String(relativePath.dropFirst().prefix { $0 != "/" }) : nil
        let page = pageVariables(doc: doc, relativePath: relativePath, url: url, collection: collection)
        let html = LiquidTemplate(doc.body).render(makeContext(page: page))
        return isMarkdown(relativePath) ? renderer.html(html) : html
    }

    func isMarkdown(_ path: String) -> Bool {
        ["md", "markdown", "mkd"].contains((path as NSString).pathExtension.lowercased())
    }

    func makeContext(page: [String: LiquidValue]) -> LiquidContext {
        let context = LiquidContext(["page": .object(page), "paginator": .null])
        context.site = siteValue
        context.timeZone = timeZone
        let roots = [site.root, themeRoot].compactMap { $0 }
        context.includeLoader = { name in
            for root in roots {
                if let text = try? String(contentsOf: root.appending(path: "_includes").appending(path: name), encoding: .utf8) { return text }
            }
            return nil
        }
        return context
    }

    /// GitHub Pages' default layouts (jekyll-default-layout) for files that name none.
    func defaultLayout(relativePath: String, collection: String?) -> String? {
        guard isMarkdown(relativePath) else { return nil }
        let base = (relativePath as NSString).deletingPathExtension
        let candidates = collection == "posts" ? ["post", "default"] : base == "index" ? ["home", "page", "default"] : ["page", "default"]
        return candidates.first { layout($0) != nil }
    }

    func pageVariables(doc: FrontMatterDocument, relativePath: String, url: String, collection: String?) -> [String: LiquidValue] {
        var page: [String: LiquidValue] = [:]
        let defaults = collection.map { site.config.defaultValues(forCollection: $0) } ?? pageDefaults()
        for entry in defaults { page[entry.key] = LiquidValue(entry.value) }
        if case let .object(values) = LiquidValue(doc.values) { page.merge(values) { $1 } }
        let filename = (relativePath as NSString).lastPathComponent
        let parts = Filename.parse(filename, timeZone: timeZone)
        if let raw = doc.value("date")?.string, let date = SiteDate.parse(raw, timeZone: timeZone) {
            page["date"] = .date(date)
        } else if let date = parts.date {
            page["date"] = .date(date)
        }
        if page["title"] == nil, collection != nil { page["title"] = .string(parts.slug.replacingOccurrences(of: "-", with: " ").capitalized) }
        page["url"] = .string(url)
        page["path"] = .string(relativePath)
        page["relative_path"] = .string(relativePath)
        page["slug"] = .string(parts.slug)
        page["name"] = .string(filename)
        page["id"] = .string(url.hasSuffix("/") ? String(url.dropLast()) : url)
        if let collection { page["collection"] = .string(collection) }
        return page
    }

    func pageDefaults() -> [YAMLEntry] {
        var result: [YAMLEntry] = []
        for item in site.config.raw["defaults"]?.list ?? [] {
            let type = item["scope"]?["type"]?.string
            let path = item["scope"]?["path"]?.string ?? ""
            guard (type == nil || type == "pages") && path.isEmpty else { continue }
            result.append(contentsOf: item["values"]?.entries ?? [])
        }
        return result
    }

    func layout(_ name: String) -> (FrontMatterDocument, LiquidTemplate)? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = layouts[name] { return cached }
        let file = name.hasSuffix(".html") ? name : "\(name).html"
        var found: (FrontMatterDocument, LiquidTemplate)?
        for root in [site.root, themeRoot].compactMap({ $0 }) {
            if let text = try? String(contentsOf: root.appending(path: "_layouts").appending(path: file), encoding: .utf8) {
                let doc = FrontMatterDocument(text: text)
                found = (doc, LiquidTemplate(doc.body))
                break
            }
        }
        layouts[name] = found
        return found
    }

    func buildSite() -> LiquidValue {
        var dict: [String: LiquidValue] = [:]
        if case let .object(config) = LiquidValue(site.config.raw) { dict = config }
        dict["time"] = .date(Date())
        dict["url"] = .string(site.config.url)
        dict["baseurl"] = .string(site.config.baseurl)
        dict["data"] = .object(dataFiles())
        // Collection content is rendered against a site object without collections, so a post that lists posts cannot recurse.
        siteValue = .object(dict)
        var collections: [LiquidValue] = []
        var names = site.config.collections.map { ($0.name, $0.output) }
        if site.sections.contains(where: { $0.collectionName == "posts" }), !names.contains(where: { $0.0 == "posts" }) { names.append(("posts", true)) }
        for (name, output) in names {
            var docs = site.documents
                .filter { $0.origin == .repository && $0.relativePath.hasPrefix("_\(name)/") && $0.publishedFlag }
                .sorted { ($0.date ?? .distantPast, $0.relativePath) < ($1.date ?? .distantPast, $1.relativePath) }
                .map(documentValue)
            // Jekyll lists site.posts newest first; other collections keep date order.
            if name == "posts" { docs.reverse() }
            dict[name] = .array(docs)
            collections.append(.object(["label": .string(name), "docs": .array(docs), "output": .bool(output)]))
        }
        if dict["posts"] == nil { dict["posts"] = .array([]) }
        dict["collections"] = .array(collections)
        // Only titles the pages really have: themes such as minima leave untitled pages out of their menus.
        dict["pages"] = .array(site.documents.filter(\.isPage).map { doc in
            let title = (try? String(contentsOf: doc.fileURL, encoding: .utf8)).flatMap { FrontMatterDocument(text: $0).value("title")?.string }
            return .object(["title": title.map(LiquidValue.string) ?? .null, "url": .string(doc.url), "path": .string(doc.relativePath)])
        })
        return .object(dict)
    }

    func documentValue(_ document: SiteDocument) -> LiquidValue {
        guard let text = try? String(contentsOf: document.fileURL, encoding: .utf8) else { return .null }
        let doc = FrontMatterDocument(text: text)
        let collection = String(document.relativePath.dropFirst().prefix { $0 != "/" })
        var page = pageVariables(doc: doc, relativePath: document.relativePath, url: document.url, collection: collection)
        var html = LiquidTemplate(doc.body).render(makeContext(page: page))
        if isMarkdown(document.relativePath) { html = renderer.html(html) }
        page["content"] = .string(html)
        let firstParagraph = html.components(separatedBy: "\n\n").first ?? html
        page["excerpt"] = .string(firstParagraph)
        return .object(page)
    }

    func dataFiles() -> [String: LiquidValue] {
        let folder = site.root.appending(path: "_data")
        var data: [String: LiquidValue] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["yml", "yaml"].contains(file.pathExtension.lowercased()) {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                data[file.deletingPathExtension().lastPathComponent] = LiquidValue(YAML.parse(text))
            }
        }
        return data
    }
}

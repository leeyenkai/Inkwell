import Foundation
import InkwellCore
import InkwellMarkdown

public struct PreviewPage: Sendable {
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
    private(set) var siteValue: LiquidValue = .null
    private var layouts: [String: (FrontMatterDocument, LiquidTemplate)] = [:]

    public init(site: Site, timeZone: TimeZone = .current) {
        self.site = site
        self.timeZone = timeZone
        siteValue = buildSite()
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

        var layoutName = page["layout"]?.text
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
        let root = site.root
        context.includeLoader = { name in
            try? String(contentsOf: root.appending(path: "_includes").appending(path: name), encoding: .utf8)
        }
        return context
    }

    func pageVariables(doc: FrontMatterDocument, relativePath: String, url: String, collection: String?) -> [String: LiquidValue] {
        var page: [String: LiquidValue] = [:]
        let defaults = collection.map { site.config.defaultValues(forCollection: $0) } ?? pageDefaults()
        for entry in defaults { page[entry.key] = LiquidValue(entry.value) }
        if case let .object(values) = LiquidValue(doc.values) { page.merge(values) { $1 } }
        let filename = (relativePath as NSString).lastPathComponent
        let parts = Filename.parse(filename)
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
        if let cached = layouts[name] { return cached }
        let url = site.root.appending(path: "_layouts").appending(path: name.hasSuffix(".html") ? name : "\(name).html")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let doc = FrontMatterDocument(text: text)
        let pair = (doc, LiquidTemplate(doc.body))
        layouts[name] = pair
        return pair
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
        for collection in site.config.collections {
            let docs = site.documents
                .filter { $0.origin == .repository && $0.relativePath.hasPrefix("_\(collection.name)/") && $0.publishedFlag }
                .sorted { ($0.date ?? .distantPast, $0.relativePath) < ($1.date ?? .distantPast, $1.relativePath) }
                .map(documentValue)
            dict[collection.name] = .array(docs)
            collections.append(.object(["label": .string(collection.name), "docs": .array(docs), "output": .bool(collection.output)]))
        }
        if dict["posts"] == nil { dict["posts"] = .array([]) }
        dict["collections"] = .array(collections)
        dict["pages"] = .array(site.documents.filter(\.isPage).map {
            .object(["title": .string($0.title), "url": .string($0.url), "path": .string($0.relativePath)])
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

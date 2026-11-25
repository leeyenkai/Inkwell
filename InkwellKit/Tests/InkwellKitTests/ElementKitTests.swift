import Foundation
@testable import InkwellCore
@testable import InkwellDesign
@testable import InkwellMarkdown
@testable import InkwellTemplate
import XCTest

/// The element kit installs into a site and every element renders through the preview without unknown tags.
final class ElementKitTests: XCTestCase {
    func testElementsRenderWithTheKit() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "kit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let changes = ElementKit.changes(siteRoot: temp)
        XCTAssertTrue(changes.contains { $0.path == "assets/css/inkwell-blocks.css" })
        XCTAssertTrue(changes.contains { $0.path == "_includes/inkwell/recent.html" })
        try AdoptionPlan(title: "", changes: changes).apply(to: temp)
        XCTAssertEqual(ElementKit.changes(siteRoot: temp), [], "installing twice changes nothing")

        let body = PageElement.allCases.map { $0.template(collection: "notes") }.joined(separator: "\n\n")
        let text = "---\ntitle: Elements\nlayout: page\n---\n\n## Intro\n\n" + body + "\n"
        let site = try SiteLoader.load(temp)
        let page = PreviewBuilder(site: site).render(text: text, relativePath: "elements.md", url: "/elements/")
        XCTAssertEqual(page.unsupportedTags, [])
        let html = page.html
        for needle in ["class=\"ik-timeline\"", "class=\"ik-callout\" data-tone=\"note\"", "<details>", "<summary>", "class=\"ik-tabs\"",
                       "class=\"ik-button\"", "class=\"ik-cards\"", "class=\"ik-hero\"", "class=\"ik-recent\"", "class=\"ik-archive\"",
                       "id=\"markdown-toc\"", "class=\"ik-social\""] {
            XCTAssertTrue(html.contains(needle), needle)
        }
        XCTAssertFalse(html.contains("markdown=\"1\""))
        XCTAssertFalse(html.contains("{%"))
        XCTAssertFalse(html.contains("relative_url"))
    }

    func testPagesInFoldersLoad() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "sub-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp.appending(path: "albums"), withIntermediateDirectories: true)
        try Data("---\ntitle: Trip\npermalink: /albums/trip/\n---\n\nPhotos.\n".utf8).write(to: temp.appending(path: "albums/trip.md"))
        try FileManager.default.createDirectory(at: temp.appending(path: "assets/x"), withIntermediateDirectories: true)
        try Data("---\ntitle: No\n---\n".utf8).write(to: temp.appending(path: "assets/x/no.md"))
        let site = try SiteLoader.load(temp)
        XCTAssertNotNil(site.documents.first { $0.relativePath == "albums/trip.md" })
        XCTAssertNil(site.documents.first { $0.relativePath.hasPrefix("assets/") })
        XCTAssertNotNil(PreviewBuilder(site: site).page(at: "/albums/trip/"))
    }

    func testPageTemplatesRender() throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "tpl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try AdoptionPlan(title: "", changes: ElementKit.changes(siteRoot: temp)).apply(to: temp)
        let site = try SiteLoader.load(temp)
        let builder = PreviewBuilder(site: site)
        for template in PageTemplate.allCases where template != .albums {
            let fields = [("layout", template.layout ?? "page"), ("title", "\"T\"")] + template.fields
            let text = FrontMatterDocument(fields: fields, body: template.body(collection: "notes")).text
            let page = builder.render(text: text, relativePath: "t.md", url: "/t/")
            XCTAssertEqual(page.unsupportedTags, [], template.rawValue)
            XCTAssertFalse(page.html.contains("markdown=\"1\""), template.rawValue)
            XCTAssertFalse(page.html.contains("{%"), template.rawValue)
        }
        let deck = FrontMatterDocument(fields: [("layout", "inkwell-slides"), ("title", "T")], body: PageTemplate.slides.body()).text
        let slides = builder.render(text: deck, relativePath: "s.md", url: "/s/")
        XCTAssertTrue(slides.html.contains("class=\"ik-slides\""))
        XCTAssertEqual(slides.html.components(separatedBy: "<hr").count - 1, 2)
    }

    /// With INKWELL_RENDER_OUT set, writes a page of every element (with an Inkwell theme) as a standalone HTML file
    /// for looking at in a browser.
    func testRenderElementsPage() throws {
        guard let out = ProcessInfo.processInfo.environment["INKWELL_RENDER_OUT"] else { throw XCTSkip("set INKWELL_RENDER_OUT to render") }
        let temp = URL(filePath: out, directoryHint: .isDirectory).appending(path: "site", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: temp)
        try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
        let theme = ThemeManifest.named(ProcessInfo.processInfo.environment["INKWELL_RENDER_THEME"] ?? "essayist")!
        try ThemeApplier.plan(theme: theme, siteRoot: temp).apply(to: temp)
        let template = PageTemplate(rawValue: ProcessInfo.processInfo.environment["INKWELL_RENDER_TEMPLATE"] ?? "")
        var body = PageElement.allCases.filter { $0 != .map }.map { "### \($0.title)\n\n" + $0.template(collection: "notes") }.joined(separator: "\n\n")
        body = body.replacingOccurrences(of: "<div class=\"ik-gallery\" data-columns=\"3\" markdown=\"1\">\n</div>",
                                         with: "<div class=\"ik-gallery\" data-columns=\"3\" markdown=\"1\">\n"
                                             + "![A](/assets/a.png)\n![B](/assets/a.png)\n![C](/assets/a.png)\n</div>")
        if let template { body = template.body(collection: "notes") }
        let text = FrontMatterDocument(fields: [("layout", template?.layout ?? "page"), ("title", "Elements")] + (template?.fields ?? []), body: body).text
        let html = PreviewBuilder(site: try SiteLoader.load(temp)).render(text: text, relativePath: "e.md", url: "/e/").html
            .replacingOccurrences(of: "=\"/", with: "=\"file://\(temp.path)/")
        try Data(html.utf8).write(to: temp.appending(path: "page.html"))
    }
}

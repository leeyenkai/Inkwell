import Foundation
@testable import InkwellCore
@testable import InkwellDesign
@testable import InkwellTemplate
import XCTest

/// Sites that are not blogs (SPEC §4.12): hand-built HTML, Jekyll pages without posts, and another generator's output.
final class WebsiteTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "inkwell-website-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, _ text: String, in folder: URL? = nil) throws {
        let url = (folder ?? root).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static let home = """
    <!doctype html>
    <html><head>
    <title>Launcher &mdash; Games on your Mac</title>
    <meta name="description" content="Play &amp; enjoy.">
    <link rel="stylesheet" href="assets/style.css">
    </head><body>
    <nav><a href="games.html">Games</a> <a href="missing.html">Gone</a> <a href="#top">Top</a> <a href="https://example.com">Out</a></nav>
    <img src="media/shot.png" alt="A game"><img src="media/gone.png" alt="">
    <img src="media/shot.png">
    <script>const t = `{{ not liquid }}`; el.innerHTML = '<a href="nowhere.html">x</a>';</script>
    </body></html>
    """

    func makeHandBuilt(in folder: URL? = nil) throws {
        try write(".nojekyll", "", in: folder)
        try write("index.html", Self.home, in: folder)
        try write("games.html", "<html><head><title>Game statistics | Launcher</title></head><body><a href=\"./\">Home</a></body></html>", in: folder)
        try write("assets/style.css", ":root {\n  --bg: #06090e;\n  --text: #e7eef6;\n}\nbody { color: var(--text); }\n", in: folder)
        try write("media/shot.png", "png", in: folder)
    }

    func testHandBuiltSiteListsItsHTMLPages() throws {
        try makeHandBuilt()
        let site = try SiteLoader.load(root)
        XCTAssertEqual(site.kind, .handBuilt)
        XCTAssertEqual(site.sections.map(\.id), ["pages"], "no Posts section on a site Jekyll does not build")
        let pages = site.documents.sorted { $0.relativePath < $1.relativePath }
        XCTAssertEqual(pages.map(\.relativePath), ["games.html", "index.html"])
        XCTAssertEqual(pages.map(\.title), ["Game statistics", "Launcher"])
        XCTAssertEqual(pages.map(\.url), ["/games.html", "/"])
        XCTAssertTrue(pages.allSatisfy(\.isStatic))
        XCTAssertEqual(pages[1].excerpt, "Play & enjoy.")
        try write("pricing.html", "<html><head><title>Pricing — Launcher</title></head><body><header><a href=\"./\">Launcher</a></header>"
            + "<main><h1>Pricing</h1><p>Free &amp; open.</p></main><footer>Made by us</footer></body></html>")
        let pricing = try XCTUnwrap(SiteLoader.load(root).documents.first { $0.relativePath == "pricing.html" })
        XCTAssertEqual(pricing.excerpt, "Free & open.", "no header, menu, footer or the heading that repeats the title")
    }

    func testFrontMatterOnANoJekyllSiteIsStillServedAsItIs() throws {
        try makeHandBuilt()
        try write("about.html", "---\ntitle: About\n---\n<p>Hi</p>\n")
        let about = try XCTUnwrap(SiteLoader.load(root).documents.first { $0.relativePath == "about.html" })
        XCTAssertTrue(about.isStatic)
    }

    func testJekyllSiteOfPagesIsAWebsiteWithoutAPostsSection() throws {
        try write("_config.yml", "title: Product\n")
        try write("index.md", "---\ntitle: Home\n---\nHello\n")
        try write("download.html", "<html><head><title>Download</title></head><body>Get it</body></html>")
        let site = try SiteLoader.load(root)
        XCTAssertEqual(site.kind, .website)
        XCTAssertFalse(site.sections.contains { $0.collectionName != nil })
        let download = try XCTUnwrap(site.documents.first { $0.relativePath == "download.html" })
        XCTAssertTrue(download.isStatic, "Jekyll copies files without front matter as they are")
        XCTAssertFalse(try XCTUnwrap(site.documents.first { $0.relativePath == "index.md" }).isStatic)
    }

    func testBlogsAndNewSitesKeepTheirPostsSection() throws {
        try write("_config.yml", "title: Blog\n")
        XCTAssertEqual(try SiteLoader.load(root).kind, .blog, "an empty Jekyll site starts as a blog")
        XCTAssertTrue(try SiteLoader.load(root).sections.contains { $0.collectionName == "posts" })
        try write("_posts/2026-01-01-hello.md", "---\ntitle: Hello\n---\nHi\n")
        try write("about.md", "---\ntitle: About\n---\nMe\n")
        XCTAssertEqual(try SiteLoader.load(root).kind, .blog)
    }

    func testGeneratedOutputIsRecognised() throws {
        try write(".nojekyll", "")
        try write("index.html", "<html><head><meta name=\"generator\" content=\"Docusaurus v3\"><title>Docs</title></head><body></body></html>")
        XCTAssertEqual(try SiteLoader.load(root).kind, .generated)
        try write("index.html", "<html><head><script src=\"/assets/index-B4x9kQ2a.js\"></script></head><body></body></html>")
        XCTAssertEqual(try SiteLoader.load(root).kind, .generated)
        try write("index.html", "<html><head><script src=\"assets/supported-games.js\"></script></head><body></body></html>")
        XCTAssertEqual(try SiteLoader.load(root).kind, .handBuilt, "a long plain name is not a hash")
    }

    func testDocsFolderIsUsedWhenTheRootIsACodeRepository() throws {
        try write("README.md", "# A program\n")
        try write("Package.swift", "// code\n")
        try makeHandBuilt(in: root.appending(path: "docs"))
        XCTAssertEqual(SiteLoader.pagesFolder(in: root).lastPathComponent, "docs")
        let site = try SiteLoader.load(SiteLoader.pagesFolder(in: root))
        XCTAssertEqual(site.name, root.lastPathComponent, "named after the repository, not docs")
        XCTAssertFalse(SiteHealth.check(site).issues.contains { $0.id == "gitignore" }, "no Jekyll .gitignore for plain HTML")
        try write("index.html", "<html></html>")
        XCTAssertEqual(SiteLoader.pagesFolder(in: root).standardizedFileURL, root.standardizedFileURL)
    }

    func testPreviewServesFilesAsTheyAreWithFolderIndexes() throws {
        try makeHandBuilt()
        let site = try SiteLoader.load(root)
        let resources = SiteResources(builder: PreviewBuilder(site: site), themeRoot: nil, sass: nil)
        let home = resources.response(for: "/")
        XCTAssertEqual(home.status, 200)
        XCTAssertEqual(String(decoding: home.data, as: UTF8.self), Self.home, "no Liquid, no layout")
        XCTAssertEqual(resources.response(for: "/games").status, 200)
        XCTAssertEqual(resources.response(for: "/assets/style.css").status, 200)
        XCTAssertEqual(resources.response(for: "/nothing.html").status, 404)
    }

    func testHealthChecksRelativeLinksPicturesAndTitles() throws {
        try makeHandBuilt()
        try write("untitled.html", "<html><body><p>No head</p></body></html>")
        let report = SiteHealth.check(try SiteLoader.load(root))
        let byID = Dictionary(uniqueKeysWithValues: report.issues.map { ($0.id, $0) })
        XCTAssertEqual(byID["links:index.html"]?.detail, "missing.html", "anchors, other sites and links inside scripts are skipped")
        XCTAssertEqual(byID["images:index.html"]?.detail, "media/gone.png")
        XCTAssertEqual(byID["alt:index.html"]?.detail.components(separatedBy: " ").last, "media/shot.png",
                       "only the picture with no alt at all: an empty alt is a decorative picture")
        XCTAssertNil(byID["links:games.html"], "./ is the home page")
        XCTAssertEqual(byID["html-title"]?.paths, ["untitled.html"])
        XCTAssertFalse(report.issues.contains { issue in
            if case let .edits(edits, _)? = issue.fix { return edits.contains { $0.path == "_config.yml" || $0.path == "404.md" } }
            return false
        }, "no Jekyll plugin fixes on a site Jekyll does not build")
    }

    func testResolvingReferences() {
        XCTAssertEqual(SiteHealth.resolve("../img/a.png", from: "docs/guide/index.html", baseurl: ""), "docs/img/a.png")
        XCTAssertEqual(SiteHealth.resolve("/steamac/media/a.png", from: "index.html", baseurl: "/steamac"), "media/a.png")
        XCTAssertEqual(SiteHealth.resolve("guide/", from: "index.html", baseurl: ""), "guide/")
        XCTAssertNil(SiteHealth.resolve("mailto:a@b.c", from: "index.html", baseurl: ""))
        XCTAssertNil(SiteHealth.resolve("../../x.png", from: "index.html", baseurl: ""))
    }

    func testHeadParsing() {
        let head = HTMLHead("""
        <head><title>
          Tom &amp; Jerry &#8212; Home
        </title><meta content="A &quot;show&quot;" name="description"><meta property="og:image" content='/og.jpg'></head>
        <body><svg><title>Icon</title></svg></body>
        """)
        XCTAssertEqual(head.title, "Tom & Jerry — Home")
        XCTAssertEqual(head.description, "A \"show\"")
        XCTAssertEqual(head.image, "/og.jpg")
        XCTAssertEqual(HTMLHead.shortTitle(head.title ?? ""), "Tom & Jerry")
        XCTAssertNil(HTMLHead("<body><svg><title>Icon</title></svg></body>").title.flatMap { $0 == "Icon" ? nil : $0 })
    }

    func testDesignFindsTheStylesheetTheHomePageLinks() throws {
        try makeHandBuilt()
        let tokens = try XCTUnwrap(DesignTokens.load(siteRoot: root))
        XCTAssertEqual(tokens.lightFile, "assets/style.css")
        XCTAssertEqual(tokens.entries.map(\.name), ["--bg", "--text"])
    }

    func testFixtureBlogIsStillABlog() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/site", withExtension: nil))
        XCTAssertEqual(try SiteLoader.load(fixture).kind, .blog)
    }

    // MARK: W2: editing pages

    func testHeadFieldsChangeOnlyTheirOwnCharacters() {
        let page = "<html>\n<head>\n    <title>Old &amp; tired</title>\n    <link rel=\"stylesheet\" href=\"a.css\">\n</head>\n<body>x</body></html>"
        let retitled = HTMLHead.setting(.title, to: "New & <improved>", in: page)
        XCTAssertEqual(retitled, page.replacingOccurrences(of: "Old &amp; tired", with: "New &amp; &lt;improved>"))
        XCTAssertEqual(HTMLHead.setting(.title, to: "Old & tired", in: page), page, "an equal value writes nothing")
        let described = HTMLHead.setting(.description, to: "Say \"hi\"", in: page)
        XCTAssertEqual(described, page.replacingOccurrences(of: "</head>",
                                                            with: "    <meta name=\"description\" content=\"Say &quot;hi&quot;\">\n</head>"))
        XCTAssertEqual(HTMLHead(described).description, "Say \"hi\"")
        XCTAssertEqual(HTMLHead.setting(.description, to: "Other", in: described),
                       described.replacingOccurrences(of: "Say &quot;hi&quot;", with: "Other"))
        XCTAssertEqual(HTMLHead.setting(.image, to: "", in: page), page, "an empty missing field adds nothing")
    }

    func testNewPageCopiesTheSitesLook() {
        let source = """
        <!doctype html>
        <html lang="en"><head>
        <title>Launcher — Games on your Mac</title>
        <meta name="description" content="Home only.">
        <meta property="og:title" content="Launcher">
        <link rel="stylesheet" href="assets/style.css">
        </head>
        <body class="home">
        <header class="nav"><a href="./">Launcher</a> <a href="games.html">Games</a></header>
        <section class="hero">Big hero</section>
        <footer><p>Made by us</p></footer>
        <script src="assets/app.js"></script>
        </body></html>
        """
        let page = HTMLPageTemplate.make(from: source, title: "Pricing", sourceIsHome: true)
        XCTAssertEqual(HTMLHead(page).title, "Pricing — Launcher")
        XCTAssertNil(HTMLHead(page).description, "the home page's description is not the new page's")
        XCTAssertFalse(page.contains("og:title"))
        XCTAssertTrue(page.contains("<link rel=\"stylesheet\" href=\"assets/style.css\">"))
        XCTAssertTrue(page.contains("<header class=\"nav\">") && page.contains("<footer><p>Made by us</p></footer>"))
        XCTAssertTrue(page.contains("<h1>Pricing</h1>"))
        XCTAssertFalse(page.contains("Big hero") || page.contains("app.js"), "the source's own content and scripts stay behind")
        XCTAssertFalse(page.hasPrefix("---"))
        let other = HTMLPageTemplate.make(from: source.replacingOccurrences(of: "Launcher — Games on your Mac", with: "Games — Launcher"),
                                          title: "Pricing", sourceIsHome: false)
        XCTAssertEqual(HTMLHead(other).title, "Pricing — Launcher")
        XCTAssertEqual(HTMLPageTemplate.fileName(for: "Pricing & Plans", existing: ["pricing-plans.html"]), "pricing-plans-2.html")
    }
}

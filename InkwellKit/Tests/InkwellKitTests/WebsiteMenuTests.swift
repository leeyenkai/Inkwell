import Foundation
@testable import InkwellCore
import XCTest

/// The rest of SPEC §4.12: link addresses on the page, the menu of a hand-built site, moving it to Jekyll, the kind
/// chosen in Settings and sites built by a GitHub Actions workflow.
final class WebsiteMenuTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "inkwell-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    // MARK: Link addresses on the page

    func testLinkAddressesAreMarkedAndOnlyTheAddressChanges() throws {
        let html = #"<p><a class="x" href="about.html">About</a> and <a href='https://a.example/?q=1&amp;r=2'><b>out</b></a></p>"#
        let regions = PageEditing.regions(in: html)
        XCTAssertEqual(regions.links.count, 2)
        XCTAssertTrue(regions.annotated.contains(#"<a data-ik-link="0""#), regions.annotated)
        let updated = try XCTUnwrap(PageEditing.replacingLink(0, with: "team.html", expecting: "about.html", in: html))
        XCTAssertEqual(updated, html.replacingOccurrences(of: "about.html", with: "team.html"))
        // Entities are compared decoded, and the old address must still be there.
        XCTAssertNotNil(PageEditing.replacingLink(1, with: "https://b.example/", expecting: "https://a.example/?q=1&r=2", in: html))
        XCTAssertNil(PageEditing.replacingLink(0, with: "x.html", expecting: "elsewhere.html", in: html))
        XCTAssertEqual(PageEditing.replacingLink(0, with: "about.html", expecting: "about.html", in: html), html)
    }

    func testLiquidPagesKeepTemplateTagsOutOfReach() {
        let html = "---\nlayout: null\n---\n<p>{{ site.title }}</p><p>Plain</p><a href=\"{{ '/x' | relative_url }}\">X</a><img src=\"a.png\">"
        let plain = PageEditing.regions(in: html)
        let liquid = PageEditing.regions(in: html, liquid: true)
        XCTAssertEqual(plain.texts.count, 3)
        XCTAssertEqual(liquid.texts.count, 2, "the paragraph made by a tag is left to the source")
        XCTAssertEqual(liquid.links.count, 0)
        XCTAssertEqual(liquid.images.count, 1)
    }

    // MARK: The menu

    static let page = """
    <!doctype html><html><head><title>Home — Plain</title></head>
    <body>
    <header><h1>Plain</h1>
      <nav class="menu">
        <a href="index.html" class="active" aria-current="page">Home</a>
        <a href="about.html">About</a>
        <a href="https://github.com/x"><svg></svg> Code</a>
      </nav>
    </header>
    <main><p>Hi</p></main>
    </body></html>
    """

    func testReadsTheMenuOfAPage() throws {
        let menu = try XCTUnwrap(HTMLMenu.find(in: Self.page))
        XCTAssertEqual(menu.items.map(\.title), ["Home", "About", "Code"])
        XCTAssertEqual(menu.items.map(\.address), ["index.html", "about.html", "https://github.com/x"])
        XCTAssertEqual(menu.items.map(\.titleEditable), [true, true, false])
        XCTAssertEqual(menu.targets(onPage: "index.html"), ["", "about.html", "https://github.com/x"])
        XCTAssertEqual(menu.targets(onPage: "docs/a.html"), ["docs/", "docs/about.html", "https://github.com/x"])
    }

    func testUnchangedMenuGivesTheSameBytes() throws {
        let menu = try XCTUnwrap(HTMLMenu.find(in: Self.page))
        XCTAssertEqual(HTMLMenu.applying(menu.entries, from: menu, referencePage: "index.html", to: Self.page, page: "index.html"), Self.page)
    }

    func testRenameReorderRemoveAndAdd() throws {
        let menu = try XCTUnwrap(HTMLMenu.find(in: Self.page))
        var entries = menu.entries
        entries[1].title = "About us"
        entries.swapAt(0, 1)
        entries.remove(at: 2)
        entries.append(HTMLMenu.Entry(title: "Pricing & plans", address: "pricing.html"))
        let updated = try XCTUnwrap(HTMLMenu.applying(entries, from: menu, referencePage: "index.html", to: Self.page, page: "index.html"))
        XCTAssertEqual(updated, """
        <!doctype html><html><head><title>Home — Plain</title></head>
        <body>
        <header><h1>Plain</h1>
          <nav class="menu">
            <a href="about.html">About us</a>
            <a href="index.html" class="active" aria-current="page">Home</a>
            <a href="pricing.html">Pricing &amp; plans</a>
          </nav>
        </header>
        <main><p>Hi</p></main>
        </body></html>
        """)
    }

    func testAListMenuMovesWholeItems() throws {
        let html = "<nav><ul>\n  <li class=\"current\"><a href=\"./\">Home</a></li>\n  <li><a href=\"blog/\">Blog</a></li>\n</ul></nav>"
        let menu = try XCTUnwrap(HTMLMenu.find(in: html))
        var entries = menu.entries
        entries.reverse()
        entries.append(HTMLMenu.Entry(title: "Contact", address: "contact.html"))
        let updated = try XCTUnwrap(HTMLMenu.applying(entries, from: menu, referencePage: "index.html", to: html, page: "index.html"))
        XCTAssertEqual(updated, """
        <nav><ul>
          <li><a href="blog/">Blog</a></li>
          <li class="current"><a href="./">Home</a></li>
          <li><a href="contact.html">Contact</a></li>
        </ul></nav>
        """)
    }

    func testTheSameChangeReachesPagesInOtherFoldersAndSkipsDifferentMenus() throws {
        let menu = try XCTUnwrap(HTMLMenu.find(in: Self.page))
        let nested = Self.page.replacingOccurrences(of: "\"index.html\"", with: "\"../index.html\"")
            .replacingOccurrences(of: "\"about.html\"", with: "\"../about.html\"")
        var entries = menu.entries
        entries[1].address = "team.html"
        entries.append(HTMLMenu.Entry(title: "Blog", address: "blog/"))
        let updated = try XCTUnwrap(HTMLMenu.applying(entries, from: menu, referencePage: "index.html", to: nested, page: "guide/start.html"))
        XCTAssertTrue(updated.contains(#"<a href="../team.html">About</a>"#), updated)
        XCTAssertTrue(updated.contains(#"<a href="../blog/">Blog</a>"#), updated)
        XCTAssertTrue(updated.contains(#"<a href="../index.html" class="active" aria-current="page">Home</a>"#))
        XCTAssertFalse(updated.contains(#"<a href="../blog/" class="active""#), "a copied item does not say it is the current page")

        let other = Self.page.replacingOccurrences(of: "about.html", with: "faq.html")
        XCTAssertNil(HTMLMenu.applying(entries, from: menu, referencePage: "index.html", to: other, page: "faq.html"))
    }

    func testMenusWithSubmenusAreLeftToTheSource() {
        let html = "<nav><ul><li><a href=\"a.html\">A</a><ul><li><a href=\"b.html\">B</a></li></ul></li></ul></nav>"
        XCTAssertNil(HTMLMenu.find(in: html))
        XCTAssertNil(HTMLMenu.find(in: "<nav><a>No address</a></nav>"))
        XCTAssertNil(HTMLMenu.find(in: "<p>No menu</p>"))
    }

    func testRelativeAddresses() {
        XCTAssertEqual(SitePath.relative(to: "about.html", from: "index.html"), "about.html")
        XCTAssertEqual(SitePath.relative(to: "media/a.png", from: "blog/x.html"), "../media/a.png")
        XCTAssertEqual(SitePath.relative(to: "blog/", from: "blog/x.html"), "./")
        XCTAssertEqual(SitePath.relative(to: "", from: "blog/x.html"), "../")
        XCTAssertEqual(SitePath.relative(to: "", from: "index.html"), "./")
        XCTAssertEqual(SitePath.relative(to: "docs/", from: "index.html"), "docs/")
        XCTAssertEqual(SitePath.relative(to: "blog/post.html", from: "blog/x.html"), "post.html")
    }

    // MARK: Moving to Jekyll

    func makeSite() throws -> [String: String] {
        let footer = "<footer><p>© Plain</p></footer>"
        let home = Self.page.replacingOccurrences(of: "</body>", with: "\(footer)\n</body>")
        let about = home.replacingOccurrences(of: "<main><p>Hi</p></main>", with: "<main><p>About</p></main>")
        let vue = "<html><body><header><h1>Plain</h1></header><div id=app>{{ message }}</div>\(footer)</body></html>"
        let lone = "<html><body><header>Other</header><p>x</p></body></html>"
        try write(".nojekyll", "")
        try write("index.html", home)
        try write("about.html", about)
        try write("app.html", vue)
        try write("lone.html", lone)
        try write("_redirects", "/old /new")
        try write("assets/_fonts/a.woff2", "x")
        try write(".well-known/security.txt", "x")
        return ["index.html": home, "about.html": about, "app.html": vue, "lone.html": lone]
    }

    func testMovingToJekyllSharesPartsAndKeepsEveryFileServed() throws {
        let pages = try makeSite()
        let plan = JekyllAdoption.plan(root: root, pages: pages)
        XCTAssertTrue(plan.isWorthDoing)
        XCTAssertEqual(plan.shared.map(\.path), ["_includes/header.html", "_includes/footer.html"])
        XCTAssertEqual(plan.shared.map(\.pages), [["about.html", "index.html"], ["about.html", "index.html"]])
        XCTAssertEqual(plan.leftAlone, ["app.html"], "a page with {{ }} would change under Jekyll")
        XCTAssertEqual(plan.changedPages, ["about.html", "index.html"])
        XCTAssertEqual(plan.removals, [".nojekyll"])
        XCTAssertEqual(plan.keptNames, [".well-known", "_fonts", "_redirects"])
        XCTAssertEqual(plan.writes["_config.yml"], "include:\n  - \".well-known\"\n  - \"_fonts\"\n  - \"_redirects\"\n")

        let home = try XCTUnwrap(plan.writes["index.html"])
        XCTAssertTrue(home.hasPrefix(JekyllAdoption.frontMatter))
        XCTAssertTrue(home.contains("{% include header.html %}"))
        XCTAssertTrue(home.contains("{% include footer.html %}"))
        // Putting the includes back gives the page exactly as it was.
        var rebuilt = String(home.dropFirst(JekyllAdoption.frontMatter.count))
        for file in plan.shared {
            rebuilt = rebuilt.replacingOccurrences(of: "{% include \((file.path as NSString).lastPathComponent) %}", with: plan.writes[file.path]!)
        }
        XCTAssertEqual(rebuilt, pages["index.html"])
        XCTAssertNil(plan.writes["lone.html"])
        XCTAssertNil(plan.writes["app.html"])
    }

    func testNothingToShareMeansNoMove() throws {
        try write(".nojekyll", "")
        let plan = JekyllAdoption.plan(root: root, pages: ["a.html": "<header>A</header>", "b.html": "<header>B</header>"])
        XCTAssertFalse(plan.isWorthDoing)
        XCTAssertTrue(plan.writes.isEmpty)
        XCTAssertTrue(plan.removals.isEmpty)
    }

    func testAMovedSiteIsAJekyllWebsiteWhosePagesStayHTML() throws {
        let pages = try makeSite()
        let plan = JekyllAdoption.plan(root: root, pages: pages)
        for (path, text) in plan.writes { try write(path, text) }
        for path in plan.removals { try FileManager.default.removeItem(at: root.appending(path: path)) }
        let site = try SiteLoader.load(root)
        XCTAssertEqual(site.kind, .website)
        let home = try XCTUnwrap(site.documents.first { $0.relativePath == "index.html" })
        XCTAssertTrue(home.isHTMLPage)
        XCTAssertFalse(home.isStatic)
        XCTAssertEqual(home.title, "Home")
        XCTAssertTrue(try XCTUnwrap(site.documents.first { $0.relativePath == "app.html" }).isStatic)
    }

    // MARK: Kind of site

    func testAKindChosenInSettingsWins() throws {
        try write("_config.yml", "title: X\n")
        try write("index.md", "---\ntitle: Home\n---\nHi")
        XCTAssertEqual(try SiteLoader.load(root).kind, .website)
        let chosen = try SiteLoader.load(root, options: SiteLoader.Options(kind: .blog))
        XCTAssertEqual(chosen.kind, .blog)
        XCTAssertEqual(chosen.detectedKind, .website)
        XCTAssertEqual(try SiteLoader.load(root, options: SiteLoader.Options(kind: .handBuilt)).kind, .handBuilt)
    }

    // MARK: Workflows

    static let hugo = """
    name: Deploy
    on: push
    jobs:
      build:
        steps:
          - uses: peaceiris/actions-hugo@v3
          - run: hugo --minify
          - uses: actions/upload-pages-artifact@v3
            with: { path: ./public }
      deploy:
        steps:
          - uses: actions/deploy-pages@v4
    """

    static let staticUpload = """
    jobs:
      deploy:
        steps:
          - uses: actions/checkout@v4
          # npm run build is not needed
          - uses: actions/upload-pages-artifact@v3
            with: { path: '.' }
          - uses: actions/deploy-pages@v4
    """

    static let jekyll = """
    jobs:
      build:
        steps:
          - run: npm run build
          - uses: actions/jekyll-build-pages@v1
          - uses: actions/upload-pages-artifact@v3
    """

    func testWorkflowsTellHowTheSiteIsBuilt() {
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.hugo]), .otherGenerator)
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.staticUpload]), .filesAsIs, "a commented-out build step does not count")
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.jekyll]), .jekyll)
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.hugo, Self.jekyll]), .jekyll, "a site Inkwell can edit is never locked by mistake")
        XCTAssertNil(PagesWorkflow.build(workflows: ["jobs:\n  test:\n    steps:\n      - run: npm run build\n"]), "not a Pages workflow")
    }

    func testASiteBuiltByAnotherGeneratorOpensReadOnly() throws {
        try write("README.md", "# Docs")
        try write("content/post.md", "---\ntitle: A\n---\nHi")
        try write(".github/workflows/pages.yml", Self.hugo)
        let site = try SiteLoader.load(root)
        XCTAssertEqual(site.kind, .generated)
        XCTAssertTrue(site.builtByWorkflow)
        // A branch build means the workflow does not build the site.
        XCTAssertNotEqual(try SiteLoader.load(root, options: SiteLoader.Options(pagesBuildType: "legacy")).kind, .generated)
    }

    func testAStaticUploadServesFilesAsTheyAre() throws {
        try write("index.html", "<html><head><title>Hi</title></head><body><p>Hi</p></body></html>")
        try write("about.html", "---\ntitle: About\n---\n<p>About</p>")
        try write(".github/workflows/static.yml", Self.staticUpload)
        let site = try SiteLoader.load(root)
        XCTAssertEqual(site.kind, .handBuilt)
        XCTAssertTrue(try XCTUnwrap(site.documents.first { $0.relativePath == "about.html" }).isStatic, "front matter is served as text")
    }

    func testTheScheduledPostWorkflowDoesNotDeploy() {
        XCTAssertNil(PagesWorkflow.build(workflows: [Schedule.workflow]))
    }
}

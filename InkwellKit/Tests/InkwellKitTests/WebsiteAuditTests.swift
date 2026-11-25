import Foundation
@testable import InkwellCore
import XCTest

/// Regressions found in the audit of hand-built website support (SPEC §4.12).
final class WebsiteAuditTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "inkwell-web-audit-\(UUID().uuidString)")
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

    // MARK: 1. Head fields with CRLF and emoji

    func testAddingAHeadFieldAfterCRLFAndEmojiDoesNotCrash() {
        let crlf = "<html>\r\n<head>\r\n  <title>Hi</title>\r\n</head>\r\n<body></body></html>"
        let added = HTMLHead.setting(.description, to: "New", in: crlf)
        XCTAssertEqual(added, "<html>\r\n<head>\r\n  <title>Hi</title>\r\n  <meta name=\"description\" content=\"New\">\r\n</head>\r\n<body></body></html>")

        let emoji = "<html><head>\n<title>🎉🎉🎉 Party</title>\n</head><body></body></html>"
        let withEmoji = HTMLHead.setting(.description, to: "A party", in: emoji)
        XCTAssertTrue(withEmoji.contains("</title>\n<meta name=\"description\" content=\"A party\">\n</head>"), withEmoji)
        let inline = "<html><head><title>🎉🎉🎉 Party</title></head><body></body></html>"
        XCTAssertEqual(HTMLHead.setting(.description, to: "A party", in: inline),
                       "<html><head><title>🎉🎉🎉 Party</title><meta name=\"description\" content=\"A party\"></head><body></body></html>")
        XCTAssertEqual(HTMLHead(withEmoji).description, "A party")

        let emojiOwnLine = "<html><head>\n  <title>🎉🎉🎉 Party</title>\n</head><body></body></html>"
        XCTAssertEqual(HTMLHead.setting(.image, to: "a.png", in: emojiOwnLine),
                       "<html><head>\n  <title>🎉🎉🎉 Party</title>\n  <meta property=\"og:image\" content=\"a.png\">\n</head><body></body></html>")
    }

    func testANewPageFromASourceWithoutATitle() {
        let source = "<!doctype html>\r\n<html><head>\r\n<link rel=\"stylesheet\" href=\"s.css\">\r\n</head>\r\n"
            + "<body><header>🎉 Hi</header><main></main></body></html>"
        let page = HTMLPageTemplate.make(from: source, title: "Pricing", sourceIsHome: true)
        XCTAssertEqual(HTMLHead(page).title, "Pricing")
        XCTAssertTrue(page.contains("<header>🎉 Hi</header>"))
    }

    // MARK: 2. Quotes in attribute values

    func testApostrophesAreEscapedInSingleQuotedAttributes() throws {
        let html = "<head><meta name='description' content='Old'></head>"
        let updated = HTMLHead.setting(.description, to: "It's mine", in: html)
        XCTAssertEqual(updated, "<head><meta name='description' content='It&#39;s mine'></head>")
        XCTAssertEqual(HTMLHead(updated).description, "It's mine")

        let link = "<p><a href='a.html'>A</a></p>"
        let changed = try XCTUnwrap(PageEditing.replacingLink(0, with: "bob's.html", expecting: "a.html", in: link))
        XCTAssertEqual(changed, "<p><a href='bob&#39;s.html'>A</a></p>")
    }

    // MARK: 3. Entities

    func testNamedAndNumericEntitiesDecode() {
        XCTAssertEqual(HTMLHead.decode("Caf&eacute; &rarr; &raquo; &times; &ntilde; &euro; &#233; &#xE9; &amp;lt; &bogus;"),
                       "Café → » × ñ € é é &lt; &bogus;")
    }

    func testEditingTextWithEntitiesIsNotRefusedOrDoubleEscaped() throws {
        let html = "<p>Caf&eacute; menu</p>"
        let edited = try XCTUnwrap(PageEditing.replacingText(0, with: "Café lunch", expecting: "Café menu", in: html))
        XCTAssertEqual(edited, "<p>Café lunch</p>")

        let page = "<head><title>Caf&eacute; Rouge</title></head>"
        XCTAssertEqual(HTMLHead(page).title, "Café Rouge")
        XCTAssertEqual(HTMLHead.setting(.title, to: "Café Rouge", in: page), page, "the same words leave the file alone")
        XCTAssertEqual(HTMLHead.setting(.title, to: "Café Rouge Bar", in: page), "<head><title>Café Rouge Bar</title></head>")
    }

    // MARK: 4. Workflows

    static let appCI = """
    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - run: npm ci && npm run build
          - uses: actions/upload-pages-artifact@v3
            with:
              path: docs
      deploy:
        steps:
          - uses: actions/deploy-pages@v4
    """

    static let astro = """
    jobs:
      build:
        steps:
          - run: npm run build
          - uses: actions/upload-pages-artifact@v3
            with:
              path: ./dist
          - uses: actions/cache@v4
            with:
              path: node_modules
      deploy:
        steps:
          - uses: actions/deploy-pages@v4
    """

    static let peaceiris = """
    jobs:
      deploy:
        steps:
          - uses: peaceiris/actions-hugo@v3
          - run: hugo --minify
          - uses: peaceiris/actions-gh-pages@v4
            with:
              github_token: ${{ secrets.GITHUB_TOKEN }}
              publish_dir: ./public
    """

    static let separateJobs = """
    jobs:
      test:
        steps:
          - run: npm run build && npm test
      pages:
        steps:
          - uses: actions/upload-pages-artifact@v3
            with: { path: '.' }
          - uses: actions/deploy-pages@v4
    """

    func testOnlyThePublishingJobAndItsFolderCount() {
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.appCI], siteFolder: "docs"), .filesAsIs,
                       "uploading the site's own folder serves it as it is, whatever else the job builds")
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.astro]), .otherGenerator)
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.peaceiris]), .otherGenerator)
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.separateJobs]), .filesAsIs, "a build in another job does not count")
        XCTAssertEqual(PagesWorkflow.build(workflows: [Self.appCI, Self.astro], siteFolder: "docs"), .filesAsIs, "never locked by mistake")
    }

    func testAHandBuiltDocsSiteWithAppCIStaysEditable() throws {
        try write(".github/workflows/ci.yml", Self.appCI)
        let docs = root.appending(path: "docs")
        try write("index.html", "<html><head><title>App</title></head><body><p>Hi</p></body></html>", in: docs)
        try write("about.html", "<html><head><title>About</title></head><body><p>About</p></body></html>", in: docs)
        let site = try SiteLoader.load(docs)
        XCTAssertNotEqual(site.kind, .generated)
        XCTAssertFalse(site.builtByWorkflow)

        // Another generator's workflow does not lock a folder with a hand-written home page either.
        try write(".github/workflows/ci.yml", Self.astro)
        XCTAssertNotEqual(try SiteLoader.load(docs).kind, .generated)
    }

    // MARK: 6. Pictures with alternatives

    func testReplacingAPictureDropsItsAlternatives() throws {
        let img = #"<p><img src="a.jpg" srcset="a@2x.jpg 2x" sizes="50vw" alt="A"></p>"#
        XCTAssertEqual(PageEditing.imageSource(0, in: img), "a.jpg")
        XCTAssertEqual(try XCTUnwrap(PageEditing.replacingImage(0, with: "b.jpg", expecting: "a.jpg", in: img)),
                       #"<p><img src="b.jpg" alt="A"></p>"#)
        XCTAssertNil(PageEditing.replacingImage(0, with: "b.jpg", expecting: "other.jpg", in: img), "not the picture that was clicked")

        let picture = """
        <picture>
          <source srcset="a.webp" type="image/webp">
          <img src="a.jpg" alt="A">
        </picture>
        """
        XCTAssertEqual(try XCTUnwrap(PageEditing.replacingImage(0, with: "b.png", in: picture)), """
        <picture>
          <img src="b.png" alt="A">
        </picture>
        """)
    }

    // MARK: 7 and 8. Moving to Jekyll

    func testAnExistingIncludeListIsAddedTo() {
        XCTAssertEqual(JekyllAdoption.including(["_redirects"], in: "title: X\ninclude:\n  - .htaccess\n# end\n"),
                       "title: X\ninclude:\n  - .htaccess\n  - \"_redirects\"\n# end\n")
        XCTAssertEqual(JekyllAdoption.including(["_redirects", ".htaccess"], in: "include: [.htaccess] # served\ntitle: X\n"),
                       "include: [.htaccess, \"_redirects\"] # served\ntitle: X\n")
        XCTAssertEqual(JekyllAdoption.including(["_a"], in: "title: X"), "title: X\ninclude:\n  - \"_a\"\n")
        XCTAssertNil(JekyllAdoption.including(["_a"], in: "include: [\n  .htaccess\n]\n"), "a form Inkwell does not edit")
    }

    func testThePlanSaysWhatItCannotKeepAndWhichMarkdownBecomesPages() throws {
        try write(".nojekyll", "")
        try write("_config.yml", "include: [\n  .htaccess\n]\n")
        try write("_redirects", "/a /b")
        try write("CHANGELOG.md", "# Changes")
        try write("README.md", "# Read me")
        let header = "<header><h1>X</h1></header>"
        let pages = ["a.html": "<html><body>\(header)<p>A</p></body></html>", "b.html": "<html><body>\(header)<p>B</p></body></html>"]
        let plan = JekyllAdoption.plan(root: root, pages: pages)
        XCTAssertTrue(plan.isWorthDoing)
        XCTAssertEqual(plan.keptNames, [])
        XCTAssertEqual(plan.notKept, ["_redirects"])
        XCTAssertNil(plan.writes["_config.yml"])
        XCTAssertEqual(plan.markdownShown, ["CHANGELOG.md"])
    }

    // MARK: 9. Project sites

    func testAProjectSitesBasePathIsInferredFromItsLinks() throws {
        let project = root.appending(path: "steam/docs")
        try write(".nojekyll", "", in: project)
        try write("index.html", #"<html><head><link rel="stylesheet" href="/steam/style.css"></head><body><a href="/steam/about.html">A</a></body></html>"#,
                  in: project)
        try write("about.html", #"<html><body><img src="/steam/media/a.png" alt="a"><a href="https://x.org/">x</a></body></html>"#, in: project)
        try write("style.css", "body{}", in: project)
        try write("media/a.png", "x", in: project)
        let site = try SiteLoader.load(project)
        XCTAssertEqual(site.config.baseurl, "/steam")
        XCTAssertEqual(site.documents.first { $0.relativePath == "about.html" }?.url, "/steam/about.html")
        let report = SiteHealth.check(site)
        XCTAssertFalse(report.issues.contains { $0.id.hasPrefix("links:") || $0.id.hasPrefix("images:") }, "\(report.issues.map(\.title))")

        // A folder of that name in the site means the links point into it.
        let other = root.appending(path: "media-site")
        try write("index.html", #"<html><body><a href="/media-site/a.html">x</a></body></html>"#, in: other)
        try write("media-site/a.html", "<p>x</p>", in: other)
        XCTAssertEqual(try SiteLoader.load(other).config.baseurl, "")
    }

    // MARK: 10. Kind chosen for files served as they are

    func testAJekyllKindIsNotTakenForFilesServedAsTheyAre() throws {
        try write(".nojekyll", "")
        try write("index.html", "<html><head><title>Hi</title></head><body></body></html>")
        let site = try SiteLoader.load(root, options: SiteLoader.Options(kind: .blog))
        XCTAssertEqual(site.kind, .handBuilt)
        XCTAssertTrue(site.filesServedAsIs)
        XCTAssertEqual(try SiteLoader.load(root, options: SiteLoader.Options(kind: .generated)).kind, .generated)
    }

    // MARK: 11. .htm pages

    func testHTMPagesAreListed() throws {
        try write(".nojekyll", "")
        try write("index.htm", "<html><head><title>Old school</title></head><body></body></html>")
        let site = try SiteLoader.load(root)
        XCTAssertEqual(site.documents.map(\.relativePath), ["index.htm"])
        XCTAssertTrue(site.documents[0].isStatic)
    }
}

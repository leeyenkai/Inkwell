import Foundation
@testable import InkwellCore
import XCTest

final class HealthTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-health-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureSite(), to: temp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func write(_ path: String, _ text: String) throws {
        let url = temp.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func ids(_ report: SiteHealth.Report) -> Set<String> { Set(report.issues.map(\.id)) }

    func testFindsContentLinkAndImageProblems() throws {
        try write("_notes/2026-07-01-broken.md", """
        ---
        title: "Broken
        date: 2026-07-01
        ---

        Lorem ipsum. See [gone](/notes/nowhere/), [fine](/notes/sample-essay/#part) and ![](/assets/images/missing.jpg).
        """)
        try write("_notes/2026-07-02-twin.md", "---\ntitle: Twin\ndate: 2026-07-02\npermalink: /notes/sample-essay/\n---\n\nSame address.\n")
        try write("_site/index.html", "<html></html>")
        try write("assets/.DS_Store", "x")
        let report = SiteHealth.check(try SiteLoader.load(temp))
        let found = ids(report)
        XCTAssertTrue(found.contains("fm:_notes/2026-07-01-broken.md"))
        XCTAssertTrue(found.contains("placeholder:_notes/2026-07-01-broken.md"))
        let links = try XCTUnwrap(report.issues.first { $0.id == "links:_notes/2026-07-01-broken.md" })
        XCTAssertEqual(links.detail, "/notes/nowhere/")
        XCTAssertEqual(links.title, "1 link in “Broken” goes nowhere")
        XCTAssertTrue(found.contains("images:_notes/2026-07-01-broken.md"))
        XCTAssertTrue(found.contains("alt:_notes/2026-07-01-broken.md"))
        XCTAssertTrue(found.contains("dup:/notes/sample-essay/"))
        XCTAssertEqual(report.issues.first?.severity, .error)

        // Repository fixes remove the files and ignore them from now on.
        guard case let .edits(edits, _)? = report.issues.first(where: { $0.id == "site-folder" })?.fix else { return XCTFail("no _site fix") }
        XCTAssertEqual(edits.first, ContentEdit(path: "_site/index.html", newText: nil))
        XCTAssertEqual(edits.last?.path, ".gitignore")
        XCTAssertTrue(found.contains("ds-store"))
    }

    func testSharingRespectsWhatIsThere() throws {
        // The fixture has jekyll-seo-tag with {% seo %}, a sitemap plugin and a description; no feed, favicon or 404 page.
        var report = SiteHealth.check(try SiteLoader.load(temp))
        XCTAssertFalse(ids(report).contains("seo-tag"))
        XCTAssertFalse(ids(report).contains("sitemap"))
        XCTAssertFalse(ids(report).contains("description"))
        XCTAssertTrue(ids(report).isSuperset(of: ["feed", "favicon", "404"]))

        let feed = try XCTUnwrap(report.issues.first { $0.id == "feed" })
        guard case let .edits(edits, summary)? = feed.fix else { return XCTFail("no feed fix") }
        XCTAssertTrue(summary.contains("jekyll-feed"))
        for edit in edits { try edit.apply(to: temp) }
        let config = try String(contentsOf: temp.appending(path: "_config.yml"), encoding: .utf8)
        XCTAssertTrue(config.contains("  - jekyll-sitemap\n  - jekyll-feed\n"))
        let layout = try String(contentsOf: temp.appending(path: "_layouts/default.html"), encoding: .utf8)
        XCTAssertTrue(layout.contains("    {% feed_meta %}\n</head>"), layout)

        // A hand-written feed counts, so a second one is never offered.
        try write("_config.yml", config.replacingOccurrences(of: "  - jekyll-feed\n", with: ""))
        try write("feed.xml", "---\nlayout: null\n---\n<feed/>")
        report = SiteHealth.check(try SiteLoader.load(temp))
        XCTAssertFalse(ids(report).contains("feed"))

        let notFound = try XCTUnwrap(report.issues.first { $0.id == "404" })
        guard case let .edits(pageEdits, _)? = notFound.fix else { return XCTFail("no 404 fix") }
        XCTAssertEqual(pageEdits.map(\.path), ["404.md"])
    }

    func testSEOFixWithoutTheTag() throws {
        try write("_config.yml", try String(contentsOf: temp.appending(path: "_config.yml"), encoding: .utf8)
            .replacingOccurrences(of: "  - jekyll-seo-tag   # <title> and link preview tags\n", with: ""))
        try write("_layouts/default.html", "<html>\n<head>\n  <title>{{ page.title }}</title>\n</head>\n<body>{{ content }}</body>\n</html>\n")
        let report = SiteHealth.check(try SiteLoader.load(temp))
        guard case let .edits(edits, _)? = report.issues.first(where: { $0.id == "seo-tag" })?.fix else { return XCTFail("no seo fix") }
        XCTAssertEqual(edits.map(\.path), ["_config.yml", "_layouts/default.html"])
        XCTAssertEqual(edits[1].newText, "<html>\n<head>\n  <title>{{ page.title }}</title>\n  {% seo %}\n</head>\n<body>{{ content }}</body>\n</html>\n")
    }

    func testLinkExtraction() {
        let body = "[a](/x/) [b]({{ '/y/' | relative_url }}) [c](https://e.com) <a href=\"/z#k\">z</a> ![i](/img.png) [d](/w?q=1)"
        XCTAssertEqual(SiteHealth.internalLinks(in: body), ["/x/", "/y/", "/w", "/z"])
    }
}

final class MaskingTests: XCTestCase {
    func testCommentsAndCodeAreNotLinksOrImages() {
        let body = "<!-- ![x](/a.jpg) 🙂 [l](/gone/) -->\n```\n![y](/b.jpg)\n```\n![z](/c.jpg) [m](/here/)"
        let images = ContentChecks.images(in: body)
        XCTAssertEqual(images.map(\.path), ["/c.jpg"])
        XCTAssertEqual(String(body[images[0].range]), "![z](/c.jpg)")
        XCTAssertEqual(SiteHealth.internalLinks(in: body), ["/here/"])
    }
}

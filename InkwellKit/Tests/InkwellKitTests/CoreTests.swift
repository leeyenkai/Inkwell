import Foundation
@testable import InkwellCore
import XCTest

func fixtureSite() -> URL {
    Bundle.module.resourceURL!.appending(path: "Fixtures/site", directoryHint: .isDirectory)
}

final class YAMLTests: XCTestCase {
    func testConfigShapes() throws {
        let text = try String(contentsOf: fixtureSite().appending(path: "_config.yml"), encoding: .utf8)
        let config = SiteConfig(yaml: YAML.parse(text))
        XCTAssertEqual(config.title, "Sample Site")
        XCTAssertEqual(config.url, "https://example.github.io")
        XCTAssertEqual(config.baseurl, "")
        XCTAssertEqual(config.permalink, "/:collection/:title/")
        XCTAssertEqual(config.collections.map(\.name), ["sidenotes", "notes", "travel"])
        XCTAssertEqual(config.collections.first?.permalink, "/sidenotes/:title/")
        XCTAssertEqual(config.plugins, ["jekyll-seo-tag", "jekyll-sitemap"])
        XCTAssertEqual(config.defaultValues(forCollection: "notes").first?.value, .string("post"))
        XCTAssertTrue(config.defaultValues(forCollection: "travel").isEmpty)
    }

    func testScalars() {
        XCTAssertEqual(YAML.scalar("\"Say \\\"hi\\\"\""), .string("Say \"hi\""))
        XCTAssertEqual(YAML.scalar("'it''s'"), .string("it's"))
        XCTAssertEqual(YAML.scalar("true"), .bool(true))
        XCTAssertEqual(YAML.scalar("42"), .int(42))
        XCTAssertEqual(YAML.scalar("2026-06-20"), .string("2026-06-20"))
        XCTAssertEqual(YAML.scalar("[a, \"b, c\"]"), .list([.string("a"), .string("b, c")]))
        XCTAssertEqual(YAML.scalar("value # comment"), .string("value"))
        XCTAssertEqual(YAML.scalar("\"# not a comment\""), .string("# not a comment"))
    }

    func testNavigationList() throws {
        let text = try String(contentsOf: fixtureSite().appending(path: "_data/navigation.yml"), encoding: .utf8)
        let items = YAML.parse(text).list ?? []
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[1]["title"], .string("notes"))
        XCTAssertEqual(items[1]["url"], .string("/notes"))
    }

    func testBlockScalar() {
        let value = YAML.parse("a: |\n  line one\n  line two\nb: 2\n")
        XCTAssertEqual(value["a"], .string("line one\nline two\n"))
        XCTAssertEqual(value["b"], .int(2))
    }
}

final class FrontMatterTests: XCTestCase {
    let sample = "---\ntitle: \"A politics of morality\"\ndate: 2026-06-20\npublished: true\n---\n\n\nThe body.\n"

    func testRoundTripIsByteIdentical() throws {
        XCTAssertEqual(FrontMatterDocument(text: sample).text, sample)
        let dir = fixtureSite()
        for path in ["_notes/2026-06-20-sample-essay.md", "_notes/2025-12-01-second-note.md", "sidenotes.md", "index.md"] {
            let text = try String(contentsOf: dir.appending(path: path), encoding: .utf8)
            XCTAssertEqual(FrontMatterDocument(text: text).text, text, path)
        }
        XCTAssertEqual(FrontMatterDocument(text: "No front matter\n").text, "No front matter\n")
        XCTAssertEqual(FrontMatterDocument(text: "---\n---\n").text, "---\n---\n")
    }

    func testSettingTheSameValueChangesNothing() {
        var doc = FrontMatterDocument(text: sample)
        doc.set("title", raw: YAMLFormat.quoted("A politics of morality"))
        doc.set("date", raw: "2026-06-20")
        XCTAssertEqual(doc.text, sample)
    }

    func testEditTouchesOnlyThatLine() {
        var doc = FrontMatterDocument(text: sample)
        doc.set("title", raw: YAMLFormat.quoted("New \"title\""))
        XCTAssertEqual(doc.text, sample.replacingOccurrences(of: "title: \"A politics of morality\"", with: "title: \"New \\\"title\\\"\""))
        XCTAssertEqual(doc.value("title"), .string("New \"title\""))
    }

    func testInsertFollowsOrderAndRemoveDropsLine() {
        var doc = FrontMatterDocument(text: sample)
        doc.set("byline", raw: YAMLFormat.quoted("Sub"), order: ["title", "byline", "date", "published"])
        XCTAssertEqual(doc.lines, ["title: \"A politics of morality\"", "byline: \"Sub\"", "date: 2026-06-20", "published: true"])
        doc.set("byline", raw: nil)
        XCTAssertEqual(doc.text, sample)
        doc.set("tags", raw: YAMLFormat.list(["ethics", "politics"]))
        XCTAssertEqual(doc.lines.last, "tags: [ethics, politics]")
    }

    func testValidation() {
        let broken = FrontMatterDocument(text: "---\ntitle: \"Unclosed\ndate: 2026-6-20\n---\nBody")
        let issues = Validation.frontMatter(broken, filename: "2026-6-20-x.md", inCollection: true)
        XCTAssertTrue(issues.contains { $0.field == "title" && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.message.contains("zero-padded") })

        let mismatch = FrontMatterDocument(text: "---\ntitle: \"Fine\"\ndate: 2026-06-21\n---\n")
        XCTAssertTrue(Validation.frontMatter(mismatch, filename: "2026-06-20-fine.md", inCollection: true)
            .contains { $0.message.contains("does not match") })

        let good = FrontMatterDocument(text: sample)
        XCTAssertEqual(Validation.frontMatter(good, filename: "2026-06-20-morality.md", inCollection: true), [])
        let escaped = FrontMatterDocument(text: "---\ntitle: \"Ends with \\\"quote\\\"\"\n---\n")
        XCTAssertEqual(Validation.frontMatter(escaped, filename: "x.md", inCollection: false), [])
    }
}

final class SiteTests: XCTestCase {
    func testLoadsSectionsInNavOrder() throws {
        let site = try SiteLoader.load(fixtureSite())
        XCTAssertEqual(site.sections.map(\.label), ["About", "Notes", "Sidenotes", "Travel", "Photos", "Pages"])
        XCTAssertEqual(Set(site.documents(in: "pages").map(\.relativePath)), ["notes.md", "sidenotes.md"])
        XCTAssertEqual(site.documents(in: "pages").first { $0.relativePath == "notes.md" }?.url, "/notes.html")
        XCTAssertEqual(site.sections[0].kind, .page("index.md"))
        XCTAssertEqual(site.documents(in: "notes").map(\.title), ["A sample essay", "Second note"])
        XCTAssertEqual(site.documents(in: "notes").first?.url, "/notes/sample-essay/")
        XCTAssertEqual(site.documents(in: "sidenotes").count, 2)
        XCTAssertEqual(site.documents(in: "sidenotes").first { $0.title == "Hidden" }?.publishedFlag, false)
        XCTAssertEqual(site.documents(in: "travel").count, 0)
        XCTAssertEqual(site.name, "example.github.io")
    }

    func testSlugFilenameAndPermalink() throws {
        XCTAssertEqual(Slug.make("A politics of morality"), "a-politics-of-morality")
        XCTAssertEqual(Slug.make("What about Estonia?"), "what-about-estonia")
        XCTAssertEqual(Slug.make("Café — naïve’s"), "cafe-naives")
        XCTAssertEqual(Slug.make("   "), "untitled")
        let date = try XCTUnwrap(SiteDate.parse("2026-01-08"))
        XCTAssertEqual(Filename.make(date: date, slug: "x"), "2026-01-08-x.md")
        let parts = Filename.parse("2026-1-8-romney.md")
        XCTAssertFalse(parts.isZeroPadded)
        XCTAssertEqual(parts.slug, "romney")
        let site = try SiteLoader.load(fixtureSite())
        XCTAssertEqual(Permalink.url(collection: "notes", filename: "2026-06-20-morality.md", date: date, config: site.config), "/notes/morality/")
        XCTAssertEqual(Permalink.display("/notes/morality/", config: site.config), "example.github.io/notes/morality/")
    }

    func testSchemaInference() throws {
        let folder = fixtureSite().appending(path: "_notes")
        let docs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .map { try FrontMatterDocument(text: String(contentsOf: $0, encoding: .utf8)) }
        let fields = SchemaInference.infer(docs)
        XCTAssertEqual(fields.map(\.key), ["title", "byline", "date", "published"])
        XCTAssertEqual(fields.first { $0.key == "byline" }?.isUniversal, false)
        XCTAssertEqual(fields.first { $0.key == "date" }?.kind, .date)
        XCTAssertEqual(fields.first { $0.key == "published" }?.defaultBool, true)
    }

    func testDraftStoreKeepsDraftsOutsideTheSite() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "inkwell-drafts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let site = try SiteLoader.load(fixtureSite())
        let store = DraftStore(base: base, siteRoot: site.root)
        let date = try XCTUnwrap(SiteDate.parse("2026-06-20"))
        let url = try store.create(collection: "notes", title: "A sample essay", date: date, text: "---\ntitle: \"A sample essay\"\n---\n",
                                   siteRoot: site.root)
        XCTAssertEqual(url.lastPathComponent, "2026-06-20-a-sample-essay.md")
        XCTAssertFalse(url.path.hasPrefix(site.root.path))
        let drafts = store.drafts(for: site)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.origin, .localDraft)
        XCTAssertEqual(drafts.first?.relativePath, "_notes/2026-06-20-a-sample-essay.md")
    }

    func testImageReferences() {
        let body = "![Alt]({{ '/assets/images/a.jpg' | relative_url }})\n![](b.png)\n<img src=\"/c.jpg\" alt=\"\">"
        let refs = ContentChecks.images(in: body)
        XCTAssertEqual(refs.map(\.path), ["/assets/images/a.jpg", "b.png", "/c.jpg"])
        XCTAssertEqual(refs.map(\.alt), ["Alt", "", ""])
    }
}

final class ExcerptTests: XCTestCase {
    func testExcerptDropsNestedMarkers() {
        XCTAssertEqual(Excerpt.make("> #### *“Quote”*\n>*Line*"), "“Quote” Line")
    }
}

final class AuditFixTests: XCTestCase {
    func testCRLFAndBOMFrontMatterRoundTripAndEdit() {
        let crlf = "\u{FEFF}---\r\ntitle: \"A\"\r\ndate: 2026-01-02\r\n---\r\nBody\r\n"
        var doc = FrontMatterDocument(text: crlf)
        XCTAssertTrue(doc.hasFrontMatter)
        XCTAssertEqual(doc.text, crlf)
        XCTAssertEqual(doc.value("title"), .string("A"))
        doc.set("title", raw: YAMLFormat.quoted("B"))
        XCTAssertEqual(doc.text, "\u{FEFF}---\r\ntitle: \"B\"\r\ndate: 2026-01-02\r\n---\r\nBody\r\n")
    }

    func testWrappedValuesDoNotHideLaterKeys() {
        let yaml = YAML.parse("description: A long line\n  that wraps\ntitle: \"Two\n  lines\"\nauthor: Me\n")
        XCTAssertEqual(yaml["description"], .string("A long line that wraps"))
        XCTAssertEqual(yaml["title"], .string("Two lines"))
        XCTAssertEqual(yaml["author"], .string("Me"))
        let doc = FrontMatterDocument(text: "---\ntitle: \"Two\n  lines\"\n---\n")
        XCTAssertEqual(Validation.frontMatter(doc, filename: "x.md", inCollection: false), [])
    }

    func testPermalinkStyles() {
        var config = SiteConfig(yaml: YAML.parse("timezone: Asia/Singapore\n"))
        let date = SiteDate.parse("2026-06-20", timeZone: config.timeZone)
        XCTAssertEqual(Permalink.url(collection: "posts", filename: "2026-06-20-hello.md", date: date, config: config), "/2026/06/20/hello.html")
        XCTAssertEqual(Permalink.url(collection: "posts", filename: "2026-06-20-hello.md", date: date, config: config, categories: ["Life"]),
                       "/life/2026/06/20/hello.html")
        config.permalink = "pretty"
        XCTAssertEqual(Permalink.url(collection: "posts", filename: "2026-06-20-hello.md", date: date, config: config), "/2026/06/20/hello/")
        XCTAssertEqual(Permalink.url(collection: "recipes", filename: "soup.md", date: nil, config: config), "/recipes/soup/")
        XCTAssertEqual(Permalink.pageURL(relativePath: "about.md", config: config), "/about/")
        config.permalink = nil
        config.baseurl = "/blog"
        XCTAssertEqual(Permalink.pageURL(relativePath: "about.md", config: config), "/blog/about.html")
        XCTAssertEqual(Permalink.pageURL(relativePath: "index.md", config: config), "/blog/")
    }

    func testPagesOutsideNavigationAndBaseurlImages() throws {
        let site = try SiteLoader.load(fixtureSite())
        XCTAssertFalse(site.documents(in: "pages").contains { $0.relativePath == "index.md" || $0.relativePath == "photos.md" })
        XCTAssertEqual(ContentChecks.plainPath("{{ site.baseurl }}/assets/a.jpg"), "/assets/a.jpg")
    }
}

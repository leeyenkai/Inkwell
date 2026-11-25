import Foundation
@testable import InkwellCore
@testable import InkwellMarkdown
@testable import InkwellTemplate
import XCTest

private func apply(_ result: FormattingResult, to text: String) -> String {
    var s = text as NSString
    for edit in result.edits { s = s.replacingCharacters(in: edit.range, with: edit.replacement) as NSString }
    return s as String
}

final class ElementAttributeTests: XCTestCase {
    func testSavingTwiceEscapesOnceAndKeepsOtherAttributes() {
        let text = "<div class=\"ik-callout wide\" id=\"tip\" data-tone=\"a &amp; b\" style=\"color: red\" markdown=\"1\">\nHi\n</div>\n"
        let span = PageElements.find(in: text)[0]
        XCTAssertEqual(span.attributes["tone"], "a & b")
        let once = apply(PageElements.update(span, in: text, attributes: span.attributes), to: text)
        let opening = #"<div class="ik-callout wide" data-tone="a &amp; b" style="color: red" id="tip" markdown="1">"#
        XCTAssertEqual(once, opening + "\nHi\n</div>\n")
        let again = PageElements.find(in: once)[0]
        XCTAssertEqual(again.attributes["tone"], "a & b")
        XCTAssertEqual(apply(PageElements.update(again, in: once, attributes: again.attributes), to: once), once)
    }

    func testBackgroundPictureStyleFollowsTheSettings() {
        let text = "<div class=\"ik-hero\" style=\"background-image: url('{{ '/a.jpg' | relative_url }}')\" markdown=\"1\">\n# Hi\n</div>"
        let span = PageElements.find(in: text)[0]
        let cleared = apply(PageElements.update(span, in: text, attributes: [:]), to: text)
        XCTAssertTrue(cleared.hasPrefix("<div class=\"ik-hero\" markdown=\"1\">\n"), cleared)
    }

    func testButtonTextAndLinkAreDecoded() {
        let line = "<a class=\"ik-button\" href=\"https://example.com/?a=1&amp;b=2\">Tom &amp; Jerry</a>"
        let span = PageElements.find(in: line)[0]
        XCTAssertEqual(span.attributes["href"], "https://example.com/?a=1&b=2")
        XCTAssertEqual(span.attributes["text"], "Tom & Jerry")
        XCTAssertEqual(apply(PageElements.update(span, in: line, attributes: span.attributes), to: line), line)
    }

    func testEntityDecoding() {
        XCTAssertEqual(PageElements.decodeEntities("&amp;lt; &#39;&#x41;&quot;"), "&lt; 'A\"")
        XCTAssertEqual(PageElements.decodeEntities("a & b &unknown; &"), "a & b &unknown; &")
    }

    func testWindowsLineEndings() {
        let text = "Intro\r\n\r\n<div class=\"ik-callout\" data-tone=\"note\" markdown=\"1\">\r\nHi\r\n</div>\r\n"
        let found = PageElements.find(in: text)
        XCTAssertEqual(found.map(\.kind), [.callout])
        let span = found[0]
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: span.openRange), "<div class=\"ik-callout\" data-tone=\"note\" markdown=\"1\">")
        XCTAssertEqual(ns.substring(with: span.innerRange!), "Hi")
        let updated = apply(PageElements.update(span, in: text, attributes: ["tone": "tip"], inner: "One\nTwo"), to: text)
        XCTAssertEqual(updated, "Intro\r\n\r\n<div class=\"ik-callout\" data-tone=\"tip\" markdown=\"1\">\r\nOne\r\nTwo\r\n</div>\r\n")
    }

    func testPlainDivInsideAnElementDoesNotCloseIt() {
        let text = """
        <div class="ik-callout" markdown="1">
        <div class="note">
        inner
        </div>
        after
        </div>
        tail
        """
        let span = PageElements.find(in: text)[0]
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: span.innerRange!), "<div class=\"note\">\ninner\n</div>\nafter")
        XCTAssertEqual(NSMaxRange(span.range), ns.range(of: "</div>\ntail").location + 6)
        let updated = apply(PageElements.update(span, in: text, attributes: [:], inner: "new"), to: text)
        XCTAssertEqual(updated, "<div class=\"ik-callout\" markdown=\"1\">\nnew\n</div>\ntail")
    }
}

final class LinkAndToggleTests: XCTestCase {
    func testAngleBracketAddresses() {
        XCTAssertEqual(MarkdownLink.all(in: "[a](<)").map(\.url), ["<"])
        XCTAssertEqual(MarkdownLink.all(in: "[a](<foo)").map(\.url), ["<foo"])
        XCTAssertEqual(MarkdownLink.all(in: "[a](<foo bar>)").map(\.url), ["foo bar"])
    }

    func toggled(_ text: String, _ selection: NSRange, _ marker: String) -> String {
        apply(Formatting.toggle(text, selection: selection, open: marker), to: text)
    }

    func testItalicAndBoldShareStars() {
        XCTAssertEqual(toggled("**word**", NSRange(location: 2, length: 4), "*"), "***word***")
        XCTAssertEqual(toggled("***word***", NSRange(location: 3, length: 4), "**"), "*word*")
        XCTAssertEqual(toggled("***word***", NSRange(location: 3, length: 4), "*"), "**word**")
        XCTAssertEqual(toggled("*word*", NSRange(location: 1, length: 4), "*"), "word")
        XCTAssertEqual(toggled("**word**", NSRange(location: 0, length: 8), "*"), "***word***")
        XCTAssertEqual(toggled("*a **b** c*", NSRange(location: 0, length: 11), "*"), "a **b** c")
        XCTAssertEqual(toggled("**a *b* c**", NSRange(location: 0, length: 11), "**"), "a *b* c")
    }

    func testSelectionWithSeveralStyledPartsIsStyledOnce() {
        XCTAssertEqual(toggled("*a* and *b*", NSRange(location: 0, length: 11), "*"), "*a and b*")
        XCTAssertEqual(toggled("**a** and **b**", NSRange(location: 0, length: 15), "**"), "**a and b**")
        let result = Formatting.toggle("*a* and *b*", selection: NSRange(location: 0, length: 11), open: "*")
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 7))
        // A star with spaces on both sides is a plain character, not a style to remove.
        XCTAssertEqual(toggled("2 * 3", NSRange(location: 0, length: 5), "*"), "*2 * 3*")
        XCTAssertEqual(toggled("*2 * 3*", NSRange(location: 0, length: 7), "*"), "2 * 3")
    }
}

final class LiquidSafetyTests: XCTestCase {
    func render(_ source: String) -> String {
        LiquidTemplate(source).render(LiquidContext())
    }

    func testSliceAndTruncateWords() {
        XCTAssertEqual(render("{{ 'hello' | slice: 1, -1 }}"), "")
        XCTAssertEqual(render("{{ 'hello' | slice: -10, 2 }}"), "")
        XCTAssertEqual(render("{{ 'hello' | slice: -3, 2 }}"), "ll")
        XCTAssertEqual(render("{{ 'hello' | slice: 99 }}"), "")
        XCTAssertEqual(render("{{ 'hello' | slice: 1e30, 1e30 }}"), "")
        XCTAssertEqual(render("{{ 'a b c' | truncatewords: -1 }}"), "a...")
        XCTAssertEqual(render("{{ 'a b c' | truncate: 1e30 }}"), "a b c")
    }

    func testArithmetic() {
        XCTAssertEqual(render("{{ 7 | modulo: 0 }}"), "")
        XCTAssertEqual(render("{{ -7 | modulo: 3 }}"), "2")
        XCTAssertEqual(render("{{ 7 | modulo: 2.5 }}"), render("{{ 2.0 }}"))
        XCTAssertEqual(render("{{ 7 | modulo: 0.5 }}"), render("{{ 0.0 }}"))
        XCTAssertEqual(render("{{ -7 | divided_by: 2 }}"), "-4")
        XCTAssertEqual(render("{{ 6 | divided_by: 3 }}"), "2")
        XCTAssertEqual(render("{{ '3' | plus: 1 }}"), "4")
        XCTAssertEqual(render("{{ 2.5 | plus: 1 }}"), render("{{ 3.5 }}"))
        XCTAssertFalse(render("{{ 9223372036854775807 | plus: 1 }}").isEmpty)
        XCTAssertFalse(render("{{ 9223372036854775807 | times: 9 }}").isEmpty)
        XCTAssertFalse(render("{{ 1e300 | times: 1e300 | floor }}").isEmpty)
        XCTAssertFalse(render("{{ 1e300 | ceil }}").isEmpty)
        XCTAssertEqual(render("{{ 2.7 | floor }}"), "2")
    }

    func testLoopBounds() {
        XCTAssertEqual(render("{% for i in (1..5) offset: -2 limit: 3 %}{{ i }}{% endfor %}"), "1")
        XCTAssertEqual(render("{% for i in (1..5) limit: -1 %}x{% endfor %}"), "")
        XCTAssertEqual(render("{% for i in (1..5) offset: 2 limit: 2 %}{{ i }}{% endfor %}"), "34")
        XCTAssertEqual(render("{% for i in (1..3) limit: 1e30 %}{{ i }}{% endfor %}"), "123")
        XCTAssertEqual(render("{% for i in (1..3) offset: 1e30 %}{{ i }}{% endfor %}"), "")
        XCTAssertEqual(render("{% for i in (1..1e30) limit: 2 %}{{ i }}{% endfor %}"), "12")
        XCTAssertEqual(render("{% for i in (1..1000000000) %}{% if forloop.last %}{{ forloop.length }}{% endif %}{% endfor %}"), "10000")
    }
}

final class FrontMatterQuotingTests: XCTestCase {
    func testMultilineValuesStayOneField() {
        let value = "line one\n---\ntitle: injected\twith tab\r\u{1}end \\ \"q\" naïve “quotes” \u{2028}x"
        let quoted = YAMLFormat.quoted(value)
        XCTAssertFalse(quoted.contains("\n"))
        XCTAssertFalse(quoted.contains("\r"))
        XCTAssertTrue(quoted.contains("naïve “quotes”"))
        var doc = FrontMatterDocument(text: "---\ntitle: \"Post\"\n---\nBody\n")
        doc.set("description", raw: quoted)
        XCTAssertEqual(doc.keys, ["title", "description"])
        XCTAssertEqual(doc.value("description")?.string, value)
        let reopened = FrontMatterDocument(text: doc.text)
        XCTAssertEqual(reopened.body, "Body\n")
        XCTAssertEqual(reopened.value("description")?.string, value)
        XCTAssertEqual(reopened.value("title")?.string, "Post")
        var same = reopened
        same.set("description", raw: YAMLFormat.quoted(value))
        XCTAssertEqual(same.text, reopened.text)
        XCTAssertEqual(YAMLFormat.plainOrQuoted("a\nb"), "\"a\\nb\"")
    }

    func testDoubleQuotedEscapes() {
        XCTAssertEqual(YAML.scalar(#""a\x41é\U0001F600\0b\r""#), .string("aAé😀\0b\r"))
    }
}

final class SiteDateTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let singapore = TimeZone(identifier: "Asia/Singapore")!

    func testOffsets() throws {
        let moment = try XCTUnwrap(SiteDate.parse("2026-06-20 10:00:00", timeZone: utc))
        for text in ["2026-06-20T10:00:00Z", "2026-06-20T18:00:00+08:00", "2026-06-20 18:00:00 +08:00", "2026-06-20 18:00:00 +0800",
                     "2026-06-20 18:00:00+0800", "2026-06-20T05:00:00-05:00", "2026-06-20 10:00:00 UTC", "2026-06-20T10:00:00.250Z"] {
            let parsed = SiteDate.parse(text, timeZone: singapore)?.timeIntervalSince1970 ?? 0
            XCTAssertEqual(parsed, moment.timeIntervalSince1970, accuracy: 1, text)
        }
        XCTAssertEqual(SiteDate.parse("2026-06-20 18:00", timeZone: singapore), moment)
        XCTAssertNil(SiteDate.parse("2026-02-30"))
        XCTAssertNil(SiteDate.parse("26-06-20"))
        XCTAssertNil(SiteDate.parse("2026-06-20x"))
        XCTAssertNotNil(SiteDate.parse("2026-6-5"))
    }

    func testFilenameDateIsInTheSiteZone() throws {
        let kiritimati = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        XCTAssertEqual(Filename.parse("2026-06-20-x.md", timeZone: kiritimati).date, SiteDate.parse("2026-06-20", timeZone: kiritimati))
        let config = SiteConfig(yaml: YAML.parse("timezone: Pacific/Kiritimati\n"))
        let date = SiteLoader.date(values: .map([]), filename: "2026-06-20-x.md", config: config)
        let url = SiteLoader.url(relativePath: "_posts/2026-06-20-x.md", values: .map([]), date: date, config: config)
        XCTAssertEqual(url, "/2026/06/20/x.html")
    }

    func testDateWithOffsetIsShownInTheSiteZone() {
        let config = SiteConfig(yaml: YAML.parse("timezone: America/New_York\n"))
        let values = YAML.parse("date: 2026-06-21T02:00:00Z\n")
        let date = SiteLoader.date(values: values, filename: "2026-06-21-x.md", config: config)
        let url = SiteLoader.url(relativePath: "_posts/2026-06-21-x.md", values: values, date: date, config: config)
        XCTAssertEqual(url, "/2026/06/20/x.html")
    }
}

final class PermalinkTests: XCTestCase {
    func config(_ yaml: String) -> SiteConfig { SiteConfig(yaml: YAML.parse(yaml)) }

    func testPageEndingsFollowTheStyle() {
        let cases = ["": "/about.html", "permalink: pretty": "/about/", "permalink: date": "/about.html",
                     "permalink: /:categories/:title/": "/about/", "permalink: /:year/:title": "/about",
                     "permalink: /:title:output_ext": "/about.html"]
        for (yaml, expected) in cases {
            XCTAssertEqual(Permalink.pageURL(relativePath: "about.md", config: config(yaml)), expected, yaml)
        }
        XCTAssertEqual(Permalink.pageURL(relativePath: "albums/index.md", config: config("permalink: /:title")), "/albums/")
        let plain = config("permalink: /:title\ncollections:\n  notes:\n    output: true\n")
        XCTAssertEqual(SiteLoader.url(relativePath: "_notes/foo.md", values: .map([]), date: nil, config: plain), "/notes/foo")
    }

    func testFrontMatterSlug() {
        let site = config("collections:\n  notes:\n    permalink: /notes/:title/\n  links:\n    permalink: /links/:slug/\n")
        let values = YAML.parse("slug: Custom Slug!\n")
        let url = { (path: String, values: YAMLValue) in SiteLoader.url(relativePath: path, values: values, date: nil, config: site) }
        XCTAssertEqual(url("_notes/2026-01-01-x.md", values), "/notes/Custom-Slug!/")
        XCTAssertEqual(url("_links/2026-01-01-x.md", values), "/links/custom-slug/")
        XCTAssertEqual(url("_notes/2026-01-01-my-post.md", .map([])), "/notes/my-post/")
    }

    func testFrontMatterPermalinkWithPlaceholders() {
        let site = config("collections:\n  notes:\n    output: true\n")
        let values = YAML.parse("permalink: /essays/:title/\n")
        XCTAssertEqual(SiteLoader.url(relativePath: "_notes/2026-01-01-x.md", values: values, date: nil, config: site), "/essays/x/")
        XCTAssertEqual(SiteLoader.url(relativePath: "about.md", values: YAML.parse("permalink: /me/\n"), date: nil, config: site), "/me/")
    }
}

final class NestedCollectionTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appending(path: "inkwell-nested-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func write(_ path: String, _ text: String) throws {
        let url = temp.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testSubfoldersAreRead() throws {
        try write("_config.yml", "title: Nested\npermalink: pretty\ncollections:\n  notes:\n    output: true\n")
        let post = "---\ntitle: \"A\"\n---\nText\n"
        try write("_posts/2024-01-01-top.md", post)
        try write("_posts/2023/2023-03-01-nested.md", post)
        try write("_posts/_hidden/2023-01-01-a.md", post)
        try write("_posts/.git/2023-01-01-b.md", post)
        try write("_posts/2023/2023-01-02-backup.md~", post)
        try write("_notes/sub/foo.md", post)
        let site = try SiteLoader.load(temp)
        let posts = site.documents.filter { $0.sectionID == "posts" }.map(\.relativePath).sorted()
        XCTAssertEqual(posts, ["_posts/2023/2023-03-01-nested.md", "_posts/2024-01-01-top.md"])
        XCTAssertEqual(site.documents.first { $0.relativePath == "_posts/2023/2023-03-01-nested.md" }?.url, "/2023/03/01/nested/")
        XCTAssertEqual(site.documents.first { $0.relativePath == "_notes/sub/foo.md" }?.url, "/notes/sub/foo/")
    }

    func testMoveKeepsAFixedPermalink() throws {
        try write("_config.yml", "title: Moves\n")
        try write("_posts/2026-01-01-fixed.md", "---\ntitle: \"Fixed\"\npermalink: /fixed/\n---\nText\n")
        try write("_posts/2026-01-02-other.md", "---\ntitle: \"Other\"\n---\nSee [it](/fixed/).\n")
        let site = try SiteLoader.load(temp)
        let doc = try XCTUnwrap(site.documents.first { $0.relativePath == "_posts/2026-01-01-fixed.md" })
        XCTAssertEqual(doc.url, "/fixed/")
        let text = try String(contentsOf: doc.fileURL, encoding: .utf8)
        let plan = MovePlanner.plan(document: doc, text: text, newPath: "_posts/2026-01-01-renamed.md", keepOldAddress: true, site: site,
                                    configText: "title: Moves\n")
        XCTAssertEqual(plan.newURL, "/fixed/")
        XCTAssertEqual(plan.updatedLinks, [])
        XCTAssertFalse(plan.edits.contains { $0.path == "_config.yml" })
        let moved = try XCTUnwrap(plan.edits.first { $0.path == "_posts/2026-01-01-renamed.md" }?.newText)
        XCTAssertEqual(moved, text)
    }

    func testMoveKeepsCategories() throws {
        try write("_config.yml", "title: Moves\n")
        try write("_posts/2026-06-20-trip.md", "---\ntitle: \"Trip\"\ncategories: [travel]\n---\nText\n")
        try write("_posts/2026-06-21-other.md", "---\ntitle: \"Other\"\n---\nSee [it](/travel/2026/06/20/trip.html).\n")
        let site = try SiteLoader.load(temp)
        let doc = try XCTUnwrap(site.documents.first { $0.relativePath == "_posts/2026-06-20-trip.md" })
        XCTAssertEqual(doc.url, "/travel/2026/06/20/trip.html")
        let plan = MovePlanner.plan(document: doc, text: try String(contentsOf: doc.fileURL, encoding: .utf8),
                                    newPath: "_posts/2026-06-20-journey.md", keepOldAddress: false, site: site, configText: nil)
        XCTAssertEqual(plan.newURL, "/travel/2026/06/20/journey.html")
        XCTAssertEqual(plan.updatedLinks, ["_posts/2026-06-21-other.md"])
        let other = try XCTUnwrap(plan.edits.first { $0.path == "_posts/2026-06-21-other.md" }?.newText)
        XCTAssertTrue(other.contains("(/travel/2026/06/20/journey.html)"), other)
    }
}

import Foundation
import InkwellCore
@testable import InkwellTemplate
import XCTest

final class LiquidTests: XCTestCase {
    func render(_ source: String, _ vars: [String: LiquidValue] = [:], site: LiquidValue = .object(["baseurl": .string("/blog")])) -> String {
        let context = LiquidContext(vars)
        context.site = site
        context.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return LiquidTemplate(source).render(context)
    }

    func testOutputAndFilters() {
        XCTAssertEqual(render("{{ 'x/y.css' | relative_url }}"), "/blog/x/y.css")
        XCTAssertEqual(render("{{ name | default: 'anon' | upcase }}"), "ANON")
        XCTAssertEqual(render("{{ page.collection | prepend: '/' }}", ["page": .object(["collection": .string("notes")])]), "/notes")
        XCTAssertEqual(render("{{ '<b>hi</b>' | strip_html }}"), "hi")
        XCTAssertEqual(render("{{ 'a b c d' | truncatewords: 2 }}"), "a b...")
    }

    func testDates() {
        let date = SiteDate.parse("2026-06-20", timeZone: TimeZone(identifier: "Asia/Singapore")!)!
        let vars: [String: LiquidValue] = ["d": .date(date)]
        XCTAssertEqual(render("{{ d | date: \"%B %d, %Y\" }}", vars), "June 20, 2026")
        XCTAssertEqual(render("{{ d | date: \"%b %-d, %Y\" }}", vars), "Jun 20, 2026")
        XCTAssertEqual(render("{{ d | date_to_xmlschema }}", vars), "2026-06-20T00:00:00+08:00")
    }

    func testControlFlow() {
        let items: LiquidValue = .array([
            .object(["t": .string("a"), "n": .int(2), "published": .bool(true)]),
            .object(["t": .string("b"), "n": .int(1), "published": .bool(false)]),
            .object(["t": .string("c"), "n": .int(3)]),
        ])
        XCTAssertEqual(render("{% for i in items reversed %}{{ i.t }}{% endfor %}", ["items": items]), "cba")
        XCTAssertEqual(render("{% for i in items limit: 2 %}{{ forloop.index }}{% endfor %}", ["items": items]), "12")
        XCTAssertEqual(render("{% assign s = items | sort: 'n' %}{% for i in s %}{{ i.t }}{% endfor %}", ["items": items]), "bac")
        XCTAssertEqual(render("{% assign s = items | where_exp: 'x', 'x.published != false' %}{{ s.size }}", ["items": items]), "2")
        XCTAssertEqual(render("{% if items.size == 3 and 'abc' contains 'b' %}yes{% else %}no{% endif %}", ["items": items]), "yes")
        XCTAssertEqual(render("{% unless false %}u{% endunless %}{% if nil %}x{% elsif 1 > 0 %}e{% endif %}"), "ue")
        XCTAssertEqual(render("{% case 2 %}{% when 1 %}one{% when 2 %}two{% endcase %}"), "two")
        XCTAssertEqual(render("{% capture c %}in{% endcapture %}{{ c }}-{% raw %}{{ kept }}{% endraw %}"), "in-{{ kept }}")
        XCTAssertEqual(render("a  {{- 'b' -}}  c"), "abc")
    }

    func testUnknownTagsAreReported() {
        let template = LiquidTemplate("x{% feed_meta %}y")
        XCTAssertEqual(template.unsupportedTags, ["feed_meta"])
        XCTAssertEqual(template.render(LiquidContext()), "xy")
    }
}

final class PreviewBuilderTests: XCTestCase {
    func testPostRendersThroughLayouts() throws {
        let site = try SiteLoader.load(fixtureSite())
        let builder = PreviewBuilder(site: site, timeZone: TimeZone(identifier: "Asia/Singapore")!)
        let doc = try XCTUnwrap(site.documents(in: "notes").first)
        let text = try String(contentsOf: doc.fileURL, encoding: .utf8)
        let page = builder.render(text: text, relativePath: doc.relativePath, url: doc.url)
        XCTAssertTrue(page.html.contains("<title>A sample essay | Sample Site</title>"))
        XCTAssertTrue(page.html.contains("<h1>A sample essay</h1>"))
        XCTAssertTrue(page.html.contains("<p class=\"post-byline\">And a subtitle</p>"))
        XCTAssertTrue(page.html.contains("June 20, 2026"))
        XCTAssertTrue(page.html.contains("<a href=\"/notes\" class=\"active\">notes</a>"))
        XCTAssertTrue(page.html.contains("<img src=\"/assets/images/test.jpg\" alt=\"A test image\" />"))
        XCTAssertTrue(page.html.contains("class=\"footnote\""))
        XCTAssertTrue(page.html.contains("← Back to notes"))
        XCTAssertEqual(page.unsupportedTags, [])
    }

    func testIndexPagesListCollections() throws {
        let site = try SiteLoader.load(fixtureSite())
        let builder = PreviewBuilder(site: site)
        let notes = try String(contentsOf: site.root.appending(path: "notes.md"), encoding: .utf8)
        let html = builder.render(text: notes, relativePath: "notes.md", url: "/notes").html
        let first = try XCTUnwrap(html.range(of: "A sample essay")), second = try XCTUnwrap(html.range(of: "Second note"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)

        let sidenotes = try String(contentsOf: site.root.appending(path: "sidenotes.md"), encoding: .utf8)
        let chain = builder.render(text: sidenotes, relativePath: "sidenotes.md", url: "/sidenotes").html
        XCTAssertTrue(chain.contains("Quoted words in a sidenote"))
        XCTAssertFalse(chain.contains("Not on the site"))
        XCTAssertTrue(chain.contains("Jan 18, 2026"))
    }
}

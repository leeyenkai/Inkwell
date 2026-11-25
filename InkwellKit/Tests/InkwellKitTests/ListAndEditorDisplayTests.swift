import Foundation
@testable import InkwellCore
@testable import InkwellMarkdown
import XCTest

final class PageExcerptTests: XCTestCase {
    func testPageExcerptSkipsTitleHeadingAndLiquidOutput() {
        let body = """

        # Travel

        Places I've been and stories from the road

        <ul class="post-list">
        {% for post in site.travel reversed %}
          <li>{{ post.title }}{% if post.excerpt %}<p>{{ post.excerpt }}</p>{% endif %}</li>
        {% endfor %}
        </ul>

        {% if site.travel.size == 0 %}
        <p>Nothing here yet.</p>
        {% endif %}
        """
        XCTAssertEqual(Excerpt.make(body, title: "Travel"), "Places I've been and stories from the road")
    }

    func testOtherHeadingsStay() {
        XCTAssertEqual(Excerpt.make("## Why\n\nBecause.", title: "Travel"), "Why Because.")
        XCTAssertEqual(Excerpt.make("# Travel\n\nText"), "Travel Text")
        XCTAssertEqual(Excerpt.make("<h1>Page not found</h1>\n\n<p>Sorry.</p>", title: "Page not found"), "Sorry.")
    }
}

final class LinkDisplayTests: XCTestCase {
    func testLinkAddressHidesLikeTheOpeningBracket() {
        let line = "- [Email](mailto:you@example.com)"
        let spans = MarkdownScanner.scan(line)
        let ns = line as NSString
        let hidden = spans.filter { $0.style == .syntax }.map { ns.substring(with: $0.range) }
        XCTAssertTrue(hidden.contains("["), "\(hidden)")
        XCTAssertTrue(hidden.contains("](mailto:you@example.com)"), "\(hidden)")
        XCTAssertEqual(spans.filter { $0.style == .link }.map { ns.substring(with: $0.range) }, ["Email"])
    }

    func testClearFormattingStillUnwrapsLink() throws {
        let text = "[a](b) and more"
        let result = try XCTUnwrap(EditorCommands.clearFormatting(text, selection: NSRange(location: 0, length: 6)))
        XCTAssertEqual(result.applied(to: text), "a and more")
    }
}

import Foundation
@testable import InkwellMarkdown
import XCTest

final class ElementRenderTests: XCTestCase {
    func testMarkdownInsideHTML() {
        let md = """
        <div class="ik-timeline" markdown="1">
        - **2019** Moved to *Singapore*
        - **2021** Started the blog
        </div>

        After.
        """
        let html = MarkdownRenderer().html(md)
        XCTAssertTrue(html.contains("<div class=\"ik-timeline\">\n<ul>"), html)
        XCTAssertTrue(html.contains("<li><strong>2019</strong> Moved to <em>Singapore</em></li>"), html)
        XCTAssertTrue(html.contains("</ul>\n</div>\n<p>After.</p>"), html)
        XCTAssertFalse(html.contains("markdown="))
    }

    func testNestedElementsAndDetails() {
        let md = """
        <div class="ik-columns" markdown="1">
        <div markdown="1">
        ## Left
        Text
        </div>
        <div markdown="1">
        Right
        </div>
        </div>

        <details markdown="1">
        <summary>More</summary>

        Hidden *text*.
        </details>
        """
        let html = MarkdownRenderer().html(md)
        XCTAssertTrue(html.contains("<div class=\"ik-columns\">\n<div>\n<h2 id=\"left\">Left</h2>"), html)
        XCTAssertTrue(html.contains("<div>\n<p>Right</p>\n</div>\n</div>"), html)
        XCTAssertTrue(html.contains("<details>\n<summary>More</summary>\n<p>Hidden <em>text</em>.</p>\n</details>"), html)
    }

    func testTableOfContents() {
        let md = "* TOC\n{:toc}\n\n## One\n\n### One A\n\n## Two\n"
        let html = MarkdownRenderer().html(md)
        XCTAssertTrue(html.contains(#"<ul id="markdown-toc">"#), html)
        XCTAssertTrue(html.contains(##"<li><a href="#one" id="markdown-toc-one">One</a>"##), html)
        XCTAssertTrue(html.contains(##"<li><a href="#one-a" id="markdown-toc-one-a">One A</a></li>"##), html)
        XCTAssertTrue(html.contains(##"<li><a href="#two" id="markdown-toc-two">Two</a></li>"##), html)
        XCTAssertFalse(html.contains("{:toc}"))
    }
}

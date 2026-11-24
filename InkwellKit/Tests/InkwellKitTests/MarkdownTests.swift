import Foundation
@testable import InkwellMarkdown
import XCTest

final class RendererTests: XCTestCase {
    let r = MarkdownRenderer()

    func testParagraphsAndEmphasis() {
        XCTAssertEqual(r.html("Some *em* and **strong** and ***both***."),
                       "<p>Some <em>em</em> and <strong>strong</strong> and <strong><em>both</em></strong>.</p>\n")
        XCTAssertEqual(r.html("snake_case_word stays"), "<p>snake_case_word stays</p>\n")
        XCTAssertEqual(r.html("~~gone~~"), "<p><del>gone</del></p>\n")
        XCTAssertEqual(r.html("`a < b`"), "<p><code class=\"language-plaintext highlighter-rouge\">a &lt; b</code></p>\n")
    }

    func testHeadingIDs() {
        XCTAssertEqual(r.html("## What about Estonia?"), "<h2 id=\"what-about-estonia\">What about Estonia?</h2>\n")
        XCTAssertEqual(r.html("# A\n\n# A"), "<h1 id=\"a\">A</h1>\n<h1 id=\"a-1\">A</h1>\n")
    }

    func testSmartTypography() {
        XCTAssertEqual(r.html("It's \"quoted\" -- and --- done..."),
                       "<p>It&#8217;s &#8220;quoted&#8221; &#8211; and &#8212; done&#8230;</p>\n")
        XCTAssertEqual(r.html("\\- Someone"), "<p>- Someone</p>\n")
    }

    func testLinksAndImages() {
        XCTAssertEqual(r.html("[site](https://example.com \"T\")"), "<p><a href=\"https://example.com\" title=\"T\">site</a></p>\n")
        XCTAssertEqual(r.html("![Alt text](/a.jpg)"), "<p><img src=\"/a.jpg\" alt=\"Alt text\" /></p>\n")
        XCTAssertEqual(r.html("[ref][1]\n\n[1]: https://x.org"), "<p><a href=\"https://x.org\">ref</a></p>\n")
        XCTAssertEqual(r.html("<https://x.org>"), "<p><a href=\"https://x.org\">https://x.org</a></p>\n")
    }

    func testBlockquotesStaySeparateAcrossBlankLines() {
        let html = r.html("> *one*\n\n>*two*")
        XCTAssertEqual(html, "<blockquote>\n<p><em>one</em></p>\n</blockquote>\n<blockquote>\n<p><em>two</em></p>\n</blockquote>\n")
        XCTAssertTrue(r.html("> #### Title\n> line").contains("<h4 id=\"title\">Title</h4>"))
    }

    func testListsAndTasks() {
        XCTAssertEqual(r.html("- a\n- b"), "<ul>\n  <li>a</li>\n  <li>b</li>\n</ul>\n")
        XCTAssertEqual(r.html("1. a\n2. b"), "<ol>\n  <li>a</li>\n  <li>b</li>\n</ol>\n")
        XCTAssertTrue(r.html("- [x] done").contains("checked=\"checked\""))
        XCTAssertTrue(r.html("- a\n\n- b").contains("<li><p>a</p>"))
    }

    func testFootnotes() {
        let html = r.html("Text.[^n]\n\n[^n]: The note.")
        XCTAssertTrue(html.contains("<sup id=\"fnref:n\" role=\"doc-noteref\"><a href=\"#fn:n\" class=\"footnote\" rel=\"footnote\">1</a></sup>"))
        XCTAssertTrue(html.contains("<li id=\"fn:n\">"))
        XCTAssertTrue(html.contains("The note.&nbsp;<a href=\"#fnref:n\" class=\"reversefootnote\""))
    }

    func testRulesCodeTablesAndHTML() {
        XCTAssertEqual(r.html("***"), "<hr />\n")
        XCTAssertTrue(r.html("```swift\nlet a = 1 < 2\n```").contains("<code>let a = 1 &lt; 2\n</code>"))
        let table = r.html("| a | b |\n|:--|--:|\n| 1 | 2 |")
        XCTAssertTrue(table.contains("<th style=\"text-align: left\">a</th>"))
        XCTAssertTrue(table.contains("<td style=\"text-align: right\">2</td>"))
        let html = "<div class=\"photo-item\">\n  <img src=\"/a.jpg\" alt=\"x\">\n\n  <p>c</p>\n</div>"
        XCTAssertEqual(r.html(html), html + "\n")
        XCTAssertEqual(r.html("A <u>b</u> <mark>c</mark>"), "<p>A <u>b</u> <mark>c</mark></p>\n")
    }
}

final class FormattingTests: XCTestCase {
    func testToggleWrapsAndUnwraps() {
        let wrapped = Formatting.toggle("say hi", selection: NSRange(location: 4, length: 2), open: "**")
        XCTAssertEqual(apply(wrapped, to: "say hi"), "say **hi**")
        XCTAssertEqual(wrapped.selection, NSRange(location: 6, length: 2))
        let unwrapped = Formatting.toggle("say **hi**", selection: NSRange(location: 6, length: 2), open: "**")
        XCTAssertEqual(apply(unwrapped, to: "say **hi**"), "say hi")
        let tags = Formatting.toggle("x", selection: NSRange(location: 0, length: 1), open: "<u>", close: "</u>")
        XCTAssertEqual(apply(tags, to: "x"), "<u>x</u>")
    }

    func testHeadingAndPrefix() {
        XCTAssertEqual(apply(Formatting.heading("Title\nBody", selection: NSRange(location: 2, length: 0), level: 2), to: "Title\nBody"),
                       "## Title\nBody")
        XCTAssertEqual(apply(Formatting.heading("## Title", selection: NSRange(location: 4, length: 0), level: 2), to: "## Title"), "Title")
        XCTAssertEqual(apply(Formatting.heading("# Title", selection: NSRange(location: 3, length: 0), level: 3), to: "# Title"), "### Title")
        XCTAssertEqual(apply(Formatting.linePrefix("a\nb", selection: NSRange(location: 0, length: 3), prefix: "> "), to: "a\nb"), "> a\n> b")
    }

    func testFootnotesAreNumberedInReadingOrder() {
        let text = "First.[^1] Second."
        let result = Formatting.footnote(text, at: 6)
        XCTAssertEqual(result.text, "First.[^1][^2] Second.\n\n[^1]: ")
        let next = Formatting.footnote(result.text + "one", at: 22)
        XCTAssertEqual(next.text, "First.[^1][^2] Second.[^3]\n\n[^1]: one\n[^3]: ")
        XCTAssertEqual(Formatting.renumberFootnotes("b[^2] a[^1]\n\n[^1]: one\n[^2]: two"), "b[^1] a[^2]\n\n[^2]: one\n[^1]: two")
    }

    func testScannerStylesWithoutChangingText() {
        let spans = MarkdownScanner.scan("# Head\nSome **bold** and {{ x }}\n> quote")
        XCTAssertTrue(spans.contains { $0.style == .heading(1) })
        XCTAssertTrue(spans.contains { $0.style == .bold && $0.range == NSRange(location: 12, length: 8) })
        XCTAssertTrue(spans.contains { $0.style == .liquid })
        XCTAssertTrue(spans.contains { $0.style == .quote })
    }

    func apply(_ result: FormattingResult, to text: String) -> String {
        var s = text as NSString
        for edit in result.edits { s = s.replacingCharacters(in: edit.range, with: edit.replacement) as NSString }
        return s as String
    }
}

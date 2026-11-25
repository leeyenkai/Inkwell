import Foundation
@testable import InkwellMarkdown
import XCTest

final class SmartTypingTests: XCTestCase {
    func apply(_ result: FormattingResult?, to text: String) -> String? {
        guard let result else { return nil }
        var s = text as NSString
        for edit in result.edits { s = s.replacingCharacters(in: edit.range, with: edit.replacement) as NSString }
        return s as String
    }

    func testReturnContinuesAndEndsLists() {
        XCTAssertEqual(apply(SmartTyping.newline(in: "- one", at: 5), to: "- one"), "- one\n- ")
        XCTAssertEqual(apply(SmartTyping.newline(in: "9. nine", at: 7), to: "9. nine"), "9. nine\n10. ")
        XCTAssertEqual(apply(SmartTyping.newline(in: "  - [x] done", at: 12), to: "  - [x] done"), "  - [x] done\n  - [ ] ")
        XCTAssertEqual(apply(SmartTyping.newline(in: "- one\n- ", at: 8), to: "- one\n- "), "- one\n")
        XCTAssertEqual(apply(SmartTyping.newline(in: "> quote", at: 7), to: "> quote"), "> quote\n> ")
        XCTAssertNil(SmartTyping.newline(in: "plain", at: 5))
    }

    func testTabNestsListItems() {
        XCTAssertEqual(apply(SmartTyping.indent(in: "- a\n- b", selection: NSRange(location: 5, length: 0), outdent: false), to: "- a\n- b"), "- a\n  - b")
        XCTAssertEqual(apply(SmartTyping.indent(in: "- a\n  - b", selection: NSRange(location: 8, length: 0), outdent: true), to: "- a\n  - b"), "- a\n- b")
        XCTAssertNil(SmartTyping.indent(in: "text", selection: NSRange(location: 1, length: 0), outdent: false))
    }

    func testSlashBlocks() {
        // Words after the slash are kept, behind the new marker.
        let text = "Intro\n/qu"
        let quote = SmartTyping.insert(.quote, in: text, slashAt: 6)
        XCTAssertEqual(apply(quote, to: text), "Intro\n> qu")
        XCTAssertEqual(quote.selection, NSRange(location: 8, length: 0))
        let table = SmartTyping.insert(.table, in: "/", slashAt: 0)
        XCTAssertEqual(apply(table, to: "/"), "| Column | Column |\n| --- | --- |\n|  |  |")
        XCTAssertEqual(table.selection, NSRange(location: 2, length: 6))
        XCTAssertEqual(apply(SmartTyping.insert(.code, in: "/", slashAt: 0), to: "/"), "```\n\n```")
    }

    func testEmbeds() {
        XCTAssertTrue(SmartTyping.embed(for: "https://www.youtube.com/watch?v=abc123")?.contains("youtube-nocookie.com/embed/abc123") == true)
        XCTAssertTrue(SmartTyping.embed(for: "https://youtu.be/xyz")?.contains("/embed/xyz") == true)
        XCTAssertTrue(SmartTyping.embed(for: "https://vimeo.com/12345")?.contains("player.vimeo.com/video/12345") == true)
        XCTAssertNil(SmartTyping.embed(for: "https://example.com/video"))
    }

    func testHTMLToMarkdown() {
        let html = """
        <html><body><!--StartFragment--><h2>Title &amp; more</h2><p>Some <b>bold</b>, <em>italic</em> and a \
        <a href="https://example.com">link</a>.</p><ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>\
        <blockquote><p>Quoted words</p></blockquote><ol><li>first</li><li>second</li></ol><p><img src="/a.jpg" alt="A"></p>\
        <!--EndFragment--></body></html>
        """
        XCTAssertEqual(HTMLToMarkdown.convert(html), """
        ## Title & more

        Some **bold**, *italic* and a [link](https://example.com).

        - one
        - two
          - nested

        > Quoted words

        1. first
        2. second

        ![A](/a.jpg)
        """)
    }
}

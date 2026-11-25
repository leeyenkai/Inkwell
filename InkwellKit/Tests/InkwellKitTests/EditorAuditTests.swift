import Foundation
@testable import InkwellCore
@testable import InkwellMarkdown
import XCTest

/// Regressions found in the pre-release audit of the writing editor.
final class EditorAuditTests: XCTestCase {
    // MARK: Slash menu and Return

    func testSlashBlockKeepsTheRestOfTheLine() {
        let text = "/hello world\nnext"
        XCTAssertEqual(SmartTyping.insert(.heading1, in: text, slashAt: 0).applied(to: text), "# hello world\nnext")
        XCTAssertEqual(SmartTyping.insert(.quote, in: text, slashAt: 0).applied(to: text), "> hello world\nnext")
        XCTAssertEqual(SmartTyping.insert(.code, in: text, slashAt: 0).applied(to: text), "```\nhello world\n```\nnext")
        XCTAssertEqual(SmartTyping.insert(.divider, in: text, slashAt: 0).applied(to: text), "***\n\nhello world\nnext")
        // An empty line still gets the block alone.
        XCTAssertEqual(SmartTyping.insert(.code, in: "/\nx", slashAt: 0).applied(to: "/\nx"), "```\n\n```\nx")
        XCTAssertEqual(SmartTyping.insert(.heading2, in: "/", slashAt: 0).applied(to: "/"), "## ")
    }

    func testReturnAtTheStartOfAListOrQuoteLineIsAPlainNewline() {
        XCTAssertNil(SmartTyping.newline(in: "- one\n- two", at: 6))
        XCTAssertNil(SmartTyping.newline(in: "1. one\n2. two", at: 7))
        XCTAssertNil(SmartTyping.newline(in: "> one", at: 0))
        XCTAssertNil(SmartTyping.newline(in: "- one", at: 1), "inside the marker")
        // At the end of an item it still continues the list.
        XCTAssertEqual(SmartTyping.newline(in: "- one", at: 5)?.applied(to: "- one"), "- one\n- ")
        XCTAssertEqual(SmartTyping.newline(in: "- one\r\n", at: 5)?.applied(to: "- one\r\n"), "- one\n- \r\n")
    }

    // MARK: CRLF

    func testMovingLinesKeepsCRLFLinesApart() {
        let text = "a\r\nb\r\nc\r\n"
        let up = EditorCommands.moveLines(text, selection: NSRange(location: 3, length: 0), up: true)?.applied(to: text)
        XCTAssertEqual(up, "b\r\na\r\nc\r\n")
        let down = EditorCommands.moveLines(text, selection: NSRange(location: 3, length: 0), up: false)?.applied(to: text)
        XCTAssertEqual(down, "a\r\nc\r\nb\r\n")
        let last = "a\r\nb"
        XCTAssertEqual(EditorCommands.moveLines(last, selection: NSRange(location: 3, length: 0), up: true)?.applied(to: last), "b\r\na")
        XCTAssertEqual(EditorCommands.moveLines(last, selection: NSRange(location: 0, length: 0), up: false)?.applied(to: last), "b\r\na")
    }

    func testCodeBlockOnCRLFLines() {
        let text = "x\r\ny\r\nz\r\n"
        let result = EditorCommands.toggleCodeBlock(text, selection: NSRange(location: 3, length: 0)).applied(to: text)
        XCTAssertEqual(result, "x\r\n```\r\ny\r\n```\r\nz\r\n")
    }

    // MARK: Front matter round trip

    func testMixedLineEndingsComeBackByteForByte() {
        for text in ["---\r\ntitle: a\ndate: 2026-01-01\r\n---\r\nBody\r\n", "---\ntitle: a\r\n---\nBody", "---\r\ntitle: a\r\n---",
                     "---\r\ntitle: a\r\n---\r", "\u{FEFF}---\r\ntitle: a\n---\nBody"] {
            XCTAssertEqual(FrontMatterDocument(text: text).text, text)
        }
    }

    func testAnEditKeepsTheOtherLinesEndings() {
        var doc = FrontMatterDocument(text: "---\r\ntitle: a\ndate: 2026-01-01\r\n---\r\nBody")
        doc.set("title", raw: "b")
        XCTAssertEqual(doc.text, "---\r\ntitle: b\ndate: 2026-01-01\r\n---\r\nBody")
        doc.set("tags", raw: "[x]")
        XCTAssertEqual(doc.text, "---\r\ntitle: b\ndate: 2026-01-01\r\ntags: [x]\r\n---\r\nBody")
        var plain = FrontMatterDocument(text: "Body\r\nmore\r\n")
        plain.set("title", raw: "c")
        XCTAssertEqual(plain.text, "---\r\ntitle: c\r\n---\r\nBody\r\nmore\r\n")
    }

    func testByteOrderMarkSurvivesReadingAndSaving() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "inkwell-bom-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("---\ntitle: a\n---\nBody\n".utf8)
        try bytes.write(to: url)
        let text = try TextFile.read(url)
        XCTAssertEqual(Data(FrontMatterDocument(text: text).text.utf8), bytes)
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        XCTAssertThrowsError(try TextFile.read(url), "invalid UTF-8 is refused, never saved back damaged")
    }

    // MARK: Links

    func testAddressesWithParentheses() throws {
        let text = "See [Foo](https://en.wikipedia.org/wiki/Foo_(bar)) now"
        let link = try XCTUnwrap(MarkdownLink.all(in: text).first)
        XCTAssertEqual(link.url, "https://en.wikipedia.org/wiki/Foo_(bar)")
        XCTAssertEqual(Formatting.removeLink(text, link: link).applied(to: text), "See Foo now")
        let edited = Formatting.setLink(text, selection: NSRange(location: 6, length: 0), url: "https://x.org", title: "").applied(to: text)
        XCTAssertEqual(edited, "See [Foo](https://x.org) now")
        XCTAssertEqual(Formatting.writtenAddress("https://a.org/x_(y)"), "https://a.org/x_(y)")
        XCTAssertEqual(Formatting.writtenAddress("https://a.org/x)"), "<https://a.org/x)>")
        XCTAssertEqual(Formatting.writtenAddress("a b"), "<a b>")
        // The editor's own styling sees the whole link too.
        let spans = MarkdownScanner.scan(text).filter { $0.style == .link }
        XCTAssertEqual(spans.map { (text as NSString).substring(with: $0.range) }, ["Foo"])
    }

    func testEscapedTitlesStayOneLink() throws {
        let text = "[\(Formatting.escapeLabel("[Draft] plan"))](/x)"
        XCTAssertEqual(text, #"[\[Draft\] plan](/x)"#)
        let link = try XCTUnwrap(MarkdownLink.all(in: text).first)
        XCTAssertEqual(link.url, "/x")
        XCTAssertEqual(link.range, NSRange(location: 0, length: (text as NSString).length))
        XCTAssertTrue(MarkdownLink.all(in: "x[^1] y").isEmpty, "a footnote is not a link")
    }

    // MARK: Footnotes

    func testOrphanDefinitionsKeepTheirOwnLabels() {
        let text = "x[^2] y\n\n[^1]: orphan\n[^2]: two\n"
        let result = Formatting.footnote(text, at: 0).text
        let definitions = result.components(separatedBy: "\n").filter { $0.hasPrefix("[^") }
        let labels = definitions.map { String($0.prefix { $0 != ":" }) }
        XCTAssertEqual(Set(labels).count, labels.count, result)
        XCTAssertTrue(result.hasPrefix("[^1]x[^2] y"), result)
        XCTAssertTrue(result.contains("[^2]: two"), result)
        XCTAssertTrue(result.contains(": orphan"), result)
    }
}

import Foundation
@testable import InkwellMarkdown
import XCTest

final class LinkTests: XCTestCase {
    func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    func testFindsLinksAtTheCursor() {
        let text = "See [the post](/notes/estonia/ \"Estonia\") and <https://example.com> but not ![pic](/a.jpg)."
        let links = MarkdownLink.all(in: text)
        XCTAssertEqual(links.map(\.url), ["/notes/estonia/", "https://example.com"])
        XCTAssertEqual(links.first?.text, "the post")
        let inText = MarkdownLink.find(in: text, at: NSRange(location: range(of: "post", in: text).location, length: 0))
        XCTAssertEqual(inText?.url, "/notes/estonia/")
        XCTAssertEqual(MarkdownLink.find(in: text, at: NSRange(location: range(of: "example", in: text).location, length: 0))?.isAutolink, true)
        XCTAssertNil(MarkdownLink.find(in: text, at: NSRange(location: range(of: "pic", in: text).location, length: 0)))
        // Just after the closing bracket is outside the link.
        XCTAssertNil(MarkdownLink.find(in: text, at: NSRange(location: NSMaxRange(links[0].range), length: 0)))
        XCTAssertEqual(MarkdownLink.all(in: "[spaced](<my file.pdf>)").first?.url, "my file.pdf")
    }

    func testSetLinkWrapsSelectionOrInsertsTitle() {
        let text = "Read about Estonia today"
        let selection = range(of: "Estonia", in: text)
        let wrapped = Formatting.setLink(text, selection: selection, url: "/notes/estonia/", title: "Estonia in winter")
        let linked = wrapped.applied(to: text)
        XCTAssertEqual(linked, "Read about [Estonia](/notes/estonia/) today")
        XCTAssertEqual(wrapped.selection.location, range(of: " today", in: linked).location)
        // A trailing space from a double-click stays outside the brackets.
        XCTAssertEqual(Formatting.setLink(text, selection: NSRange(location: 11, length: 8), url: "/x/", title: "").applied(to: text),
                       "Read about [Estonia](/x/) today")
        // Nothing selected: the post's title becomes the text.
        let inserted = Formatting.setLink("Go: ", selection: NSRange(location: 4, length: 0), url: "/notes/estonia/", title: "Estonia [draft]")
        XCTAssertEqual(inserted.applied(to: "Go: "), "Go: [Estonia \\[draft\\]](/notes/estonia/)")
        XCTAssertEqual(inserted.selection.location, ("Go: [Estonia \\[draft\\]](/notes/estonia/)" as NSString).length)
    }

    func testEditingAnExistingLinkChangesOnlyTheAddress() {
        let text = "A [link](https://old.example) here"
        let result = Formatting.setLink(text, selection: NSRange(location: 4, length: 0), url: "https://new.example/page", title: "ignored")
        XCTAssertEqual(result.edits, [TextEdit(range(of: "https://old.example", in: text), "https://new.example/page")])
        XCTAssertEqual(result.applied(to: text), "A [link](https://new.example/page) here")
        let auto = "Mail <https://a.example> now"
        XCTAssertEqual(Formatting.setLink(auto, selection: NSRange(location: 8, length: 0), url: "mailto:me@example.com", title: "").applied(to: auto),
                       "Mail [https://a.example](mailto:me@example.com) now")
    }

    func testRemoveLinkKeepsText() {
        let text = "A [link](/x/ \"t\") here"
        let link = MarkdownLink.find(in: text, at: NSRange(location: 4, length: 0))!
        let removed = Formatting.removeLink(text, link: link)
        XCTAssertEqual(removed.applied(to: text), "A link here")
        XCTAssertEqual(removed.selection, NSRange(location: 2, length: 4))
    }

    func testAddressesFromTypedText() {
        XCTAssertEqual(LinkInput.address(from: "https://example.com/a?b=1"), "https://example.com/a?b=1")
        XCTAssertEqual(LinkInput.address(from: " example.com "), "https://example.com")
        XCTAssertEqual(LinkInput.address(from: "www.example.org/page"), "https://www.example.org/page")
        XCTAssertEqual(LinkInput.address(from: "me@example.com"), "mailto:me@example.com")
        XCTAssertEqual(LinkInput.address(from: "mailto:me@example.com"), "mailto:me@example.com")
        XCTAssertEqual(LinkInput.address(from: "/notes/estonia/"), "/notes/estonia/")
        XCTAssertEqual(LinkInput.address(from: "#history"), "#history")
        XCTAssertNil(LinkInput.address(from: "estonia winter"))
        XCTAssertNil(LinkInput.address(from: "estonia"))
        XCTAssertNil(LinkInput.address(from: "https://"))
        XCTAssertTrue(LinkInput.isExplicit("www.example.org"))
        XCTAssertFalse(LinkInput.isExplicit("node.js"))
    }

    func testDestinations() {
        XCTAssertEqual(LinkDestination("#intro"), .anchor("intro"))
        XCTAssertEqual(LinkDestination("/notes/estonia/#snow"), .site("/notes/estonia/"))
        XCTAssertEqual(LinkDestination("{{ site.baseurl }}/notes/estonia/"), .site("/notes/estonia/"))
        XCTAssertEqual(LinkDestination("https://example.com"), .web(URL(string: "https://example.com")!))
        XCTAssertEqual(LinkDestination("mailto:me@example.com"), .web(URL(string: "mailto:me@example.com")!))
        XCTAssertNil(LinkDestination("relative/page"))
    }

    func testHeadingAnchorsMatchTheRenderer() {
        let text = "Intro\n\n## Hello, World\n\nText\n\n### Hello, World\n\n```\n# not a heading\n```\n"
        let headings = HeadingAnchor.list(in: text)
        XCTAssertEqual(headings.map(\.title), ["Hello, World", "Hello, World"])
        XCTAssertEqual(headings.map(\.level), [2, 3])
        XCTAssertEqual(headings.first?.anchor, "hello-world")
        XCTAssertNotEqual(headings[0].anchor, headings[1].anchor, "repeated titles get distinct ids")
        XCTAssertTrue(HeadingAnchor.list(in: "No headings here.").isEmpty)
    }

    func testSearchRanking() {
        let day: TimeInterval = 86400
        let entries = [
            LinkSearch.Entry(title: "Winter in Estonia", url: "/notes/estonia/", detail: "Notes", date: Date(timeIntervalSince1970: 3 * day)),
            LinkSearch.Entry(title: "Estonia", url: "/travel/estonia/", detail: "Travel", date: Date(timeIntervalSince1970: 1 * day)),
            LinkSearch.Entry(title: "Café culture", url: "/notes/cafe/", detail: "Notes", date: Date(timeIntervalSince1970: 2 * day)),
            LinkSearch.Entry(title: "About", url: "/about/", detail: "Page", date: nil),
        ]
        let headings = [HeadingAnchor(level: 2, title: "Estonian food", anchor: "estonian-food")]
        let estonia = LinkSearch.results(query: "estonia", entries: entries, headings: headings)
        XCTAssertEqual(estonia.map(\.url), ["/travel/estonia/", "/notes/estonia/", "#estonian-food"])
        XCTAssertEqual(LinkSearch.results(query: "cafe", entries: entries, headings: []).first?.title, "Café culture")
        // Nothing typed: the latest first, and an address on the clipboard on top.
        let empty = LinkSearch.results(query: "", clipboard: "https://example.com", entries: entries, headings: [])
        XCTAssertEqual(empty.first?.kind, .web)
        XCTAssertEqual(empty.dropFirst().first?.url, "/notes/estonia/")
        // The selected words suggest posts.
        XCTAssertEqual(LinkSearch.results(query: "", context: "café", entries: entries, headings: []).first?.url, "/notes/cafe/")
        // A typed address comes first; a bare word that looks like a domain comes after the posts.
        XCTAssertEqual(LinkSearch.results(query: "https://a.example", entries: entries, headings: []).first?.url, "https://a.example")
        XCTAssertEqual(LinkSearch.results(query: "me@example.com", entries: entries, headings: []).first?.kind, .email)
        XCTAssertEqual(LinkSearch.results(query: "about.me", entries: entries, headings: []).last?.url, "https://about.me")
        XCTAssertEqual(LinkSearch.results(query: "#est", entries: entries, headings: headings).first?.url, "#estonian-food")
    }

    func testPastedRoundTrip() {
        // Linking then removing the link gives back the same bytes.
        let text = "Plain words here.\n"
        let selection = range(of: "words", in: text)
        let linked = Formatting.setLink(text, selection: selection, url: "https://example.com", title: "").applied(to: text)
        let link = MarkdownLink.find(in: linked, at: NSRange(location: 8, length: 0))!
        XCTAssertEqual(Formatting.removeLink(linked, link: link).applied(to: linked), text)
    }
}

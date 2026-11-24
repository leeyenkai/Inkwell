import Foundation
@testable import InkwellMarkdown
import XCTest

final class PageElementTests: XCTestCase {
    let page = """
    # Trip

    <div class="ik-timeline" markdown="1">
    - **2019** Moved to Singapore
    - **2021** Started the blog
    </div>

    <div class="ik-columns" markdown="1">
    <div markdown="1">
    Left
    </div>
    <div markdown="1">
    Right
    </div>
    </div>

    {% include inkwell/recent.html collection="notes" limit=5 %}

    <a class="ik-button ik-button--outline" href="{{ '/about/' | relative_url }}">About me</a>

    ```
    <div class="ik-map" markdown="1">
    </div>
    ```
    """

    func apply(_ result: FormattingResult, to text: String) -> String {
        var s = text as NSString
        for edit in result.edits { s = s.replacingCharacters(in: edit.range, with: edit.replacement) as NSString }
        return s as String
    }

    func testFindsElements() {
        let found = PageElements.find(in: page)
        XCTAssertEqual(found.map(\.kind), [.timeline, .columns, .recent, .button])
        let ns = page as NSString
        let timeline = found[0]
        XCTAssertEqual(ns.substring(with: timeline.openRange), "<div class=\"ik-timeline\" markdown=\"1\">")
        XCTAssertEqual(ns.substring(with: timeline.closeRange!), "</div>")
        XCTAssertEqual(PageElements.timeline(ns.substring(with: timeline.innerRange!))?.map(\.date), ["2019", "2021"])
        XCTAssertEqual(found[2].attributes, ["collection": "notes", "limit": "5"])
        XCTAssertEqual(found[3].attributes["text"], "About me")
        XCTAssertEqual(found[3].attributes["style"], "outline")
        XCTAssertEqual(PageElements.plainPath(found[3].attributes["href"] ?? ""), "/about/")
        let right = ns.range(of: "Right").location
        XCTAssertEqual(PageElements.element(in: page, at: right)?.kind, .columns)
    }

    func testUpdatingSettingsAndItems() {
        let text = "<div class=\"ik-gallery\" data-columns=\"3\" markdown=\"1\">\n![A](/a.jpg)\n</div>\n"
        let span = PageElements.find(in: text)[0]
        XCTAssertEqual(span.attributes["columns"], "3")
        let pictures = PageElements.pictures((text as NSString).substring(with: span.innerRange!)) ?? []
        XCTAssertEqual(pictures.map(\.path), ["/a.jpg"])
        let more = pictures + [PageElements.Picture(path: "/b.jpg", alt: "B", caption: "Bee")]
        let result = PageElements.update(span, in: text, attributes: ["columns": "2"], inner: PageElements.picturesMarkdown(more))
        let updated = apply(result, to: text)
        XCTAssertEqual(updated, """
        <div class="ik-gallery" data-columns="2" markdown="1">
        ![A]({{ '/a.jpg' | relative_url }})
        ![B]({{ '/b.jpg' | relative_url }} "Bee")
        </div>

        """)
        XCTAssertEqual(PageElements.pictures((updated as NSString).substring(with: PageElements.find(in: updated)[0].innerRange!))?.count, 2)
    }

    func testItemRoundTrips() {
        let places = [PageElements.Place(name: "Marina Bay", latitude: 1.2834, longitude: 103.8607)]
        XCTAssertEqual(PageElements.placesMarkdown(places), "- [Marina Bay](geo:1.2834,103.8607)")
        XCTAssertEqual(PageElements.places(PageElements.placesMarkdown(places)), places)
        let cards = [PageElements.Card(title: "One", link: "/one/", text: "A thing.", image: "/one.jpg"),
                     PageElements.Card(title: "Two", link: "", text: "")]
        XCTAssertEqual(PageElements.cards(PageElements.cardsMarkdown(cards)), cards)
        let items = [PageElements.TimelineItem(date: "May 2020", text: "Graduated")]
        XCTAssertEqual(PageElements.timeline(PageElements.timelineMarkdown(items)), items)
        XCTAssertNil(PageElements.timeline("Just a paragraph"))
    }

    func testColumnsAndInsertion() {
        let inner = "<div markdown=\"1\">\nA\n</div>\n<div markdown=\"1\">\nB\n</div>"
        XCTAssertEqual(PageElements.columnCount(inner), 2)
        XCTAssertEqual(PageElements.columnCount(PageElements.columns(inner, count: 3)), 3)
        XCTAssertEqual(PageElements.columnCount(PageElements.columns(inner, count: 1)), 2, "columns with text stay")
        let text = "Intro\n\nOutro\n"
        let result = PageElements.insertion("X", in: text, at: 2)
        XCTAssertEqual(apply(result, to: text), "Intro\n\nX\n\n\nOutro\n")
    }
}

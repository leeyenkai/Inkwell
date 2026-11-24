import Foundation
@testable import InkwellMarkdown
import XCTest

final class EditorCommandsTests: XCTestCase {
    func apply(_ result: FormattingResult?, to text: String) -> String? {
        result?.applied(to: text)
    }

    func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    // MARK: Moving lines

    func testMoveLinesUpAndDown() {
        let text = "one\ntwo\nthree"
        let down = EditorCommands.moveLines(text, selection: NSRange(location: 1, length: 0), up: false)
        XCTAssertEqual(apply(down, to: text), "two\none\nthree")
        XCTAssertEqual(down?.selection, NSRange(location: 5, length: 0))
        XCTAssertEqual(down?.edits.count, 1, "one edit, so one undo step")
        let up = EditorCommands.moveLines(text, selection: NSRange(location: 9, length: 2), up: true)
        XCTAssertEqual(apply(up, to: text), "one\nthree\ntwo")
        XCTAssertEqual(up?.selection, NSRange(location: 5, length: 2))
        XCTAssertNil(EditorCommands.moveLines(text, selection: NSRange(location: 0, length: 0), up: true))
        XCTAssertNil(EditorCommands.moveLines(text, selection: NSRange(location: 10, length: 0), up: false))
        // The last line without a newline moving down past… nothing; the one before it moving down swaps endings.
        let second = EditorCommands.moveLines(text, selection: NSRange(location: 5, length: 0), up: false)
        XCTAssertEqual(apply(second, to: text), "one\nthree\ntwo")
        // A selection of two whole lines, ending at the start of the next, moves both and not the next.
        let two = EditorCommands.moveLines("a\nb\nc\nd\n", selection: NSRange(location: 2, length: 4), up: true)
        XCTAssertEqual(apply(two, to: "a\nb\nc\nd\n"), "b\nc\na\nd\n")
        // Moving down then up gives back the same bytes.
        let there = apply(down, to: text) ?? ""
        XCTAssertEqual(apply(EditorCommands.moveLines(there, selection: down!.selection, up: true), to: there), text)
    }

    func testMovingNumberedItemsRenumbers() {
        let text = "1. a\n2. b\n3. c\n"
        let moved = EditorCommands.moveLines(text, selection: NSRange(location: 10, length: 0), up: true)
        XCTAssertEqual(apply(moved, to: text), "1. a\n2. c\n3. b\n")
    }

    // MARK: Checklists

    func testCheckboxToggleChangesOneCharacter() {
        let text = "- [ ] milk\n- [x] eggs\n* [X] bread\n- not a task\n1. [ ] numbered"
        XCTAssertEqual(EditorCommands.checkbox(in: text, line: 3), NSRange(location: 2, length: 3))
        let tick = EditorCommands.toggleCheckbox(text, line: 0, selection: NSRange(location: 8, length: 0))
        XCTAssertEqual(tick?.edits, [TextEdit(NSRange(location: 3, length: 1), "x")])
        XCTAssertEqual(tick?.selection, NSRange(location: 8, length: 0))
        let eggs = range(of: "eggs", in: text).location
        XCTAssertEqual(apply(EditorCommands.toggleCheckbox(text, line: eggs, selection: NSRange(location: 0, length: 0)), to: text)?
            .contains("- [ ] eggs"), true)
        let bread = range(of: "bread", in: text).location
        XCTAssertEqual(apply(EditorCommands.toggleCheckbox(text, line: bread, selection: NSRange()), to: text)?
            .contains("* [ ] bread"), true)
        XCTAssertNil(EditorCommands.toggleCheckbox(text, line: range(of: "not a", in: text).location, selection: NSRange()))
        XCTAssertNotNil(EditorCommands.checkbox(in: text, line: range(of: "numbered", in: text).location))
        // Ticking twice gives back the same bytes.
        let once = apply(tick, to: text) ?? ""
        XCTAssertEqual(apply(EditorCommands.toggleCheckbox(once, line: 0, selection: NSRange()), to: once), text)
    }

    // MARK: Numbered lists

    func testReturnRenumbersTheRestOfTheList() {
        let text = "1. a\n2. b\n3. c"
        let result = EditorCommands.newline(text, at: 4)
        XCTAssertEqual(apply(result, to: text), "1. a\n2. \n3. b\n4. c")
        XCTAssertEqual(result?.selection, NSRange(location: 8, length: 0))
        // A list starting at 5 keeps counting from 5.
        XCTAssertEqual(apply(EditorCommands.newline("5. a\n6. b", at: 4), to: "5. a\n6. b"), "5. a\n6. \n7. b")
        // Bullets are left alone.
        XCTAssertEqual(apply(EditorCommands.newline("- a\n- b", at: 3), to: "- a\n- b"), "- a\n- \n- b")
        XCTAssertNil(EditorCommands.newline("plain", at: 5))
    }

    func testTabAndShiftTabRenumber() {
        let text = "1. a\n2. b\n3. c\n4. d"
        let nested = EditorCommands.indent(text, selection: NSRange(location: range(of: "b", in: text).location, length: 0), outdent: false)
        let afterTab = apply(nested, to: text) ?? ""
        XCTAssertEqual(afterTab, "1. a\n   1. b\n2. c\n3. d")
        XCTAssertEqual(nested?.selection.location, range(of: "b", in: afterTab).location)
        let b = NSRange(location: range(of: "b", in: afterTab).location, length: 0)
        let back = EditorCommands.indent(afterTab, selection: b, outdent: true)
        XCTAssertEqual(apply(back, to: afterTab), text)
        // Two nested items, the first taken out: it joins the outer list and the other becomes its first child.
        let deep = "1. a\n   1. b\n   2. c\n2. d"
        let out = EditorCommands.indent(deep, selection: NSRange(location: range(of: "b", in: deep).location, length: 0), outdent: true)
        XCTAssertEqual(apply(out, to: deep), "1. a\n2. b\n   1. c\n3. d")
    }

    func testRenumberKeepsBlankLinesAndStopsAtParagraphs() {
        let text = "1. a\n\n1. b\n\n1. c\n\nAfter\n\n1. other"
        let edits = EditorCommands.renumber(text, around: 0)
        let fixed = FormattingResult(edits: edits, selection: NSRange()).applied(to: text)
        XCTAssertEqual(fixed, "1. a\n\n2. b\n\n3. c\n\nAfter\n\n1. other")
        XCTAssertTrue(EditorCommands.renumber("1. a\n2. b", around: 0).isEmpty, "a correct list is not touched")
    }

    func testListCommands() {
        let text = "milk\neggs\n\nbread"
        let all = NSRange(location: 0, length: (text as NSString).length)
        let result = EditorCommands.list(.numbers, in: text, selection: all)
        XCTAssertEqual(apply(result, to: text), "1. milk\n2. eggs\n\n3. bread")
        let numbered = apply(result, to: text) ?? ""
        let again = EditorCommands.list(.numbers, in: numbered, selection: NSRange(location: 0, length: (numbered as NSString).length))
        XCTAssertEqual(apply(again, to: numbered), text, "applying it twice gives back the same bytes")
        func list(_ kind: FormatState.List, _ text: String) -> String? {
            apply(EditorCommands.list(kind, in: text, selection: NSRange(location: 0, length: (text as NSString).length)), to: text)
        }
        XCTAssertEqual(list(.numbers, "- a\n- b"), "1. a\n2. b")
        XCTAssertEqual(list(.checklist, "1. a\n2. b"), "- [ ] a\n- [ ] b")
        XCTAssertEqual(list(.bullets, "- [x] a"), "- a")
        XCTAssertEqual(apply(EditorCommands.list(.bullets, in: "- a", selection: NSRange(location: 3, length: 0)), to: "- a"), "a")
        let empty = EditorCommands.list(.checklist, in: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(apply(empty, to: ""), "- [ ] ")
        XCTAssertEqual(empty.selection, NSRange(location: 6, length: 0))
    }

    func testIndentQuotes() {
        XCTAssertEqual(apply(EditorCommands.indent("> a", selection: NSRange(location: 2, length: 0), outdent: false), to: "> a"), ">> a")
        XCTAssertEqual(apply(EditorCommands.indent("> a", selection: NSRange(location: 2, length: 0), outdent: true), to: "> a"), "a")
        XCTAssertNil(EditorCommands.indent("plain", selection: NSRange(location: 1, length: 0), outdent: false))
    }

    // MARK: Code blocks

    func testCodeBlockLanguage() {
        let text = "Intro\n\n```\nlet a = 1\n```\n\n```ruby\nputs 1\n```\n"
        let inside = range(of: "let a", in: text).location
        let block = EditorCommands.codeBlock(in: text, at: inside)
        XCTAssertEqual(block?.language, "")
        XCTAssertNil(EditorCommands.codeBlock(in: text, at: 2))
        let swift = EditorCommands.setCodeLanguage(text, block: block!, language: "swift", selection: NSRange(location: inside, length: 0))
        let written = apply(swift, to: text) ?? ""
        XCTAssertTrue(written.contains("```swift\nlet a = 1\n```"))
        XCTAssertEqual(swift.selection.location, inside + 5)
        let ruby = EditorCommands.codeBlock(in: written, at: range(of: "puts", in: written).location)
        XCTAssertEqual(ruby?.language, "ruby")
        let cleared = apply(EditorCommands.setCodeLanguage(written, block: ruby!, language: "", selection: NSRange()), to: written)
        XCTAssertEqual(cleared, "Intro\n\n```swift\nlet a = 1\n```\n\n```\nputs 1\n```\n")
    }

    func testToggleCodeBlockRoundTrips() {
        let text = "a\nlet x = 1\nb"
        let selection = NSRange(location: 2, length: 3)
        let wrapped = EditorCommands.toggleCodeBlock(text, selection: selection)
        let on = apply(wrapped, to: text) ?? ""
        XCTAssertEqual(on, "a\n```\nlet x = 1\n```\nb")
        XCTAssertEqual((on as NSString).substring(with: wrapped.selection), "let")
        let off = EditorCommands.toggleCodeBlock(on, selection: wrapped.selection)
        XCTAssertEqual(apply(off, to: on), text)
        XCTAssertEqual(off.selection, selection)
    }

    // MARK: Clear formatting

    func testClearFormatting() {
        let text = "Some **bold** and *it* with <sup>2</sup> and [a link](/x/) end"
        let all = EditorCommands.clearFormatting(text, selection: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(apply(all, to: text), "Some bold and it with 2 and a link end")
        // The selection is just the word inside the markers.
        let bold = range(of: "bold", in: text)
        let one = EditorCommands.clearFormatting(text, selection: bold)
        let cleared = apply(one, to: text) ?? ""
        XCTAssertEqual(cleared, "Some bold and *it* with <sup>2</sup> and [a link](/x/) end")
        XCTAssertEqual((cleared as NSString).substring(with: one!.selection), "bold")
        let under = "x <u>under</u> y"
        XCTAssertEqual(apply(EditorCommands.clearFormatting(under, selection: NSRange(location: 5, length: 5)), to: under), "x under y")
        XCTAssertNil(EditorCommands.clearFormatting("plain text", selection: NSRange(location: 0, length: 5)))
        XCTAssertEqual(apply(EditorCommands.clearFormatting("a <mark>**b**</mark> c", selection: NSRange(location: 2, length: 18)),
                             to: "a <mark>**b**</mark> c"), "a b c")
    }

    func testSuperscriptAndSubscriptToggle() {
        let text = "x2 and H2O"
        let sup = Formatting.toggle(text, selection: NSRange(location: 1, length: 1), open: "<sup>", close: "</sup>")
        let on = apply(sup, to: text) ?? ""
        XCTAssertEqual(on, "x<sup>2</sup> and H2O")
        XCTAssertEqual(apply(Formatting.toggle(on, selection: sup.selection, open: "<sup>", close: "</sup>"), to: on), text)
        XCTAssertTrue(FormatState.at(on, selection: NSRange(location: 7, length: 0)).superscript)
    }

    // MARK: State at the cursor

    func testFormatStateAtCursor() {
        let text = "## Title\n\nSome **bold** and <u>under</u> and [link](/x/).\n\n- [ ] task\n1. one\n> quote\n\n```swift\ncode\n```\n"
        XCTAssertEqual(FormatState.at(text, selection: NSRange(location: 4, length: 0)).block, .heading(2))
        let bold = FormatState.at(text, selection: NSRange(location: range(of: "old", in: text).location, length: 0))
        XCTAssertTrue(bold.bold)
        XCTAssertFalse(bold.italic)
        XCTAssertTrue(FormatState.at(text, selection: range(of: "under", in: text)).underline)
        XCTAssertTrue(FormatState.at(text, selection: NSRange(location: range(of: "ink", in: text).location, length: 0)).link)
        XCTAssertEqual(FormatState.at(text, selection: NSRange(location: range(of: "task", in: text).location, length: 0)).list, .checklist)
        XCTAssertEqual(FormatState.at(text, selection: NSRange(location: range(of: "one", in: text).location, length: 0)).list, .numbers)
        XCTAssertTrue(FormatState.at(text, selection: NSRange(location: range(of: "quote", in: text).location, length: 0)).quote)
        let code = FormatState.at(text, selection: NSRange(location: range(of: "code", in: text).location, length: 0))
        XCTAssertEqual(code.block, .code)
        XCTAssertEqual(code.codeLanguage, "swift")
        XCTAssertNil(FormatState.at(text, selection: NSRange(location: 12, length: 0)).codeLanguage)
    }
}

import Foundation
@testable import InkwellMarkdown
import XCTest

final class TableTests: XCTestCase {
    func testParseAndFormat() throws {
        let text = "|Name|Score|\n|:--|--:|\n|Ann|10|\n|Bob \\| Co|`a|b`|"
        let table = try XCTUnwrap(MarkdownTable.parse(text))
        XCTAssertEqual(table.header, ["Name", "Score"])
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows, [["Ann", "10"], ["Bob | Co", "`a|b`"]])
        XCTAssertEqual(table.markdown, """
        | Name     | Score |
        | :------- | ----: |
        | Ann      |    10 |
        | Bob \\| Co | `a|b` |
        """.replacingOccurrences(of: "| Name     |", with: "| Name      |")
            .replacingOccurrences(of: "| :------- |", with: "| :-------- |")
            .replacingOccurrences(of: "| Ann      |", with: "| Ann       |"))
        // Formatting is stable: parsing the output gives the same table.
        XCTAssertEqual(MarkdownTable.parse(table.markdown), table)
    }

    func testRaggedRowsAndCentre() throws {
        let table = try XCTUnwrap(MarkdownTable.parse("| a | b | c |\n| :-: | --- | --- |\n| 1 |\n"))
        XCTAssertEqual(table.rows, [["1", "", ""]])
        XCTAssertEqual(table.markdown, "|  a  | b   | c   |\n| :-: | --- | --- |\n|  1  |     |     |")
    }

    func testEditing() {
        var table = MarkdownTable.blank(columns: 2, rows: 1)
        table.insertColumn(at: 1)
        table.header[1] = "Middle"
        table.alignments[1] = .center
        table.insertRow(at: 0)
        table.rows[0] = ["x", "y", "z"]
        table.moveRow(from: 0, by: 1)
        table.moveColumn(from: 2, by: -1)
        XCTAssertEqual(table.header, ["Column 1", "Column 2", "Middle"])
        XCTAssertEqual(table.rows, [["", "", ""], ["x", "z", "y"]])
        table.removeColumn(at: 0)
        table.removeRow(at: 0)
        XCTAssertEqual(table.rows, [["z", "y"]])
        XCTAssertEqual(table.alignments, [.none, .center])
    }

    func testCellsWithLineBreaksStayOnOneLine() {
        let table = MarkdownTable(header: ["A"], rows: [["one\ntwo"]])
        XCTAssertEqual(table.markdown, "| A       |\n| ------- |\n| one two |")
    }

    func testWideCharactersLineUp() {
        let table = MarkdownTable(header: ["城市", "x"], rows: [["Tallinn", "y"]])
        XCTAssertEqual(table.markdown, "| 城市    | x   |\n| ------- | --- |\n| Tallinn | y   |")
    }

    func testFindAroundCursor() throws {
        let text = "Intro\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nAfter | with a pipe? no, separated.\n"
        let inside = (text as NSString).range(of: "1 |").location
        let found = try XCTUnwrap(MarkdownTable.find(in: text, at: inside))
        XCTAssertEqual((text as NSString).substring(with: found.range), "| a | b |\n| - | - |\n| 1 | 2 |")
        XCTAssertNil(MarkdownTable.find(in: text, at: 2))
        XCTAssertNil(MarkdownTable.find(in: "a | b\nnot a delimiter\n", at: 1))
        let ranges = MarkdownTable.ranges(in: text + "\n---\n\n```\n| x |\n| - |\n```\n")
        XCTAssertEqual(ranges, [found.range])
    }

    func testImageLines() {
        let text = """
        ![Snow](/assets/a.jpg)
        Text with ![inline](/b.png) image.
        ![Liquid]({{ '/assets/c.jpg' | relative_url }} "Title"){: .wide}

        ```
        ![code](/d.jpg)
        ```
        """
        let lines = ImageLines.find(in: text)
        XCTAssertEqual(lines.map(\.target), ["/assets/a.jpg", "{{ '/assets/c.jpg' | relative_url }}"])
        XCTAssertEqual(lines.map(\.alt), ["Snow", "Liquid"])
        XCTAssertEqual((text as NSString).substring(with: lines[0].range), "![Snow](/assets/a.jpg)")
    }
}

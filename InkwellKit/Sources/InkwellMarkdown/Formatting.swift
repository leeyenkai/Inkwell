import Foundation

/// One replacement in the editor's text, in UTF-16 units so it maps straight onto `NSTextView`.
public struct TextEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String

    public init(_ range: NSRange, _ replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public struct FormattingResult: Sendable, Equatable {
    /// Applied in order; each range refers to the text after the previous edits.
    public var edits: [TextEdit]
    public var selection: NSRange

    public init(edits: [TextEdit], selection: NSRange) {
        self.edits = edits
        self.selection = selection
    }
}

/// The formatting commands. Each one returns the smallest edit that does the job, so undo and diffs stay small.
public enum Formatting {
    public static func toggle(_ text: String, selection: NSRange, open: String, close: String? = nil) -> FormattingResult {
        let ns = text as NSString
        let close = close ?? open
        let o = (open as NSString).length, c = (close as NSString).length
        let selected = ns.substring(with: selection)
        if selected.hasPrefix(open), selected.hasSuffix(close), selection.length >= o + c {
            let inner = (selected as NSString).substring(with: NSRange(location: o, length: selection.length - o - c))
            return FormattingResult(edits: [TextEdit(selection, inner)], selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        if selection.location >= o, NSMaxRange(selection) + c <= ns.length,
           ns.substring(with: NSRange(location: selection.location - o, length: o)) == open,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: c)) == close {
            let outer = NSRange(location: selection.location - o, length: selection.length + o + c)
            return FormattingResult(edits: [TextEdit(outer, selected)], selection: NSRange(location: selection.location - o, length: selection.length))
        }
        var core = selection
        while core.length > 0, isSpace(ns.character(at: NSMaxRange(core) - 1)) { core.length -= 1 }
        let wrapped = open + ns.substring(with: core) + close
        return FormattingResult(edits: [TextEdit(core, wrapped)], selection: NSRange(location: core.location + o, length: core.length))
    }

    public static func link(_ text: String, selection: NSRange, url: String) -> FormattingResult {
        let ns = text as NSString
        let label = selection.length > 0 ? ns.substring(with: selection) : "link"
        let replacement = "[\(label)](\(url))"
        let labelStart = selection.location + 1
        return FormattingResult(edits: [TextEdit(selection, replacement)],
                                selection: NSRange(location: labelStart, length: (label as NSString).length))
    }

    /// Sets the heading level of every line in the selection; level 0 makes them plain paragraphs.
    public static func heading(_ text: String, selection: NSRange, level: Int) -> FormattingResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        var edits: [TextEdit] = []
        var location = lineRange.location
        var delta = 0
        var cursorShift = 0
        while location < NSMaxRange(lineRange) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line)
            let existing = content.prefix { $0 == "#" }.count
            var markerLength = existing
            if existing > 0, content.dropFirst(existing).first == " " { markerLength += 1 }
            let newMarker = level > 0 ? String(repeating: "#", count: level) + " " : ""
            let same = existing == level && markerLength > 0
            let marker = same ? "" : newMarker
            edits.append(TextEdit(NSRange(location: line.location + delta, length: markerLength), marker))
            if line.location <= selection.location { cursorShift = (marker as NSString).length - markerLength }
            delta += (marker as NSString).length - markerLength
            location = NSMaxRange(line)
        }
        let newLocation = max(lineRange.location, selection.location + cursorShift)
        return FormattingResult(edits: edits, selection: NSRange(location: newLocation, length: selection.length))
    }

    /// Prefixes each selected line, or removes the prefix when every line already has it.
    public static func linePrefix(_ text: String, selection: NSRange, prefix: String) -> FormattingResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: selection)
        var lines: [NSRange] = []
        var location = lineRange.location
        repeat {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            lines.append(line)
            location = NSMaxRange(line)
        } while location < NSMaxRange(lineRange)
        let all = lines.allSatisfy { ns.substring(with: $0).hasPrefix(prefix) }
        var edits: [TextEdit] = []
        var delta = 0
        let p = (prefix as NSString).length
        for line in lines {
            if all {
                edits.append(TextEdit(NSRange(location: line.location + delta, length: p), ""))
                delta -= p
            } else if !ns.substring(with: line).hasPrefix(prefix) {
                edits.append(TextEdit(NSRange(location: line.location + delta, length: 0), prefix))
                delta += p
            }
        }
        let first = all ? -p : p
        return FormattingResult(edits: edits, selection: NSRange(location: max(lineRange.location, selection.location + first),
                                                                 length: max(0, selection.length + delta - first)))
    }

    /// Inserts the next footnote at the cursor and its definition at the end, then numbers all footnotes in reading order.
    public static func footnote(_ text: String, at cursor: Int) -> (text: String, selection: NSRange) {
        let numbers = footnoteLabels(text).compactMap { Int($0) }
        let label = "\((numbers.max() ?? 0) + 1)"
        let ns = text as NSString
        var result = ns.replacingCharacters(in: NSRange(location: cursor, length: 0), with: "[^\(label)]")
        if !result.hasSuffix("\n") { result += "\n" }
        let hasDefinitions = text.range(of: #"(?m)^\[\^[^\]]+\]:"#, options: .regularExpression) != nil
        if !result.hasSuffix("\n\n"), !hasDefinitions { result += "\n" }
        result += "[^\(label)]: "
        let renumbered = renumberFootnotes(result)
        return (renumbered, NSRange(location: (renumbered as NSString).length, length: 0))
    }

    static func footnoteLabels(_ text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\](?!:)"#)
        let ns = text as NSString
        return (regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Renumbers numeric footnotes 1, 2, 3 in the order their references first appear. Named footnotes are left alone.
    public static func renumberFootnotes(_ text: String) -> String {
        var mapping: [String: String] = [:]
        var next = 1
        for label in footnoteLabels(text) where Int(label) != nil && mapping[label] == nil {
            mapping[label] = "\(next)"
            next += 1
        }
        guard mapping.contains(where: { $0.key != $0.value }) else { return text }
        let regex = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#)
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let label = ns.substring(with: m.range(at: 1))
            out += "[^\(mapping[label] ?? label)]"
            last = NSMaxRange(m.range)
        }
        out += ns.substring(from: last)
        return out
    }

    public static func divider(_ text: String, at cursor: Int) -> FormattingResult {
        let ns = text as NSString
        let before = cursor > 0 && ns.character(at: cursor - 1) != 10 ? "\n\n" : (cursor > 1 && ns.character(at: cursor - 2) != 10 ? "\n" : "")
        let insert = before + "***\n\n"
        return FormattingResult(edits: [TextEdit(NSRange(location: cursor, length: 0), insert)],
                                selection: NSRange(location: cursor + (insert as NSString).length, length: 0))
    }

    static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 10 || c == 9 }
}

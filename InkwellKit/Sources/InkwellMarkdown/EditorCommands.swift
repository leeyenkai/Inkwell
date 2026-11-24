import Foundation

extension FormattingResult {
    /// The text once these edits are made.
    public func applied(to text: String) -> String {
        var s = text as NSString
        for edit in edits { s = s.replacingCharacters(in: edit.range, with: edit.replacement) as NSString }
        return s as String
    }

    /// Adds edits made to the result text, keeping the selection on the same characters.
    func appending(_ more: [TextEdit]) -> FormattingResult {
        var selection = selection
        for edit in more {
            let delta = (edit.replacement as NSString).length - edit.range.length
            if NSMaxRange(edit.range) <= selection.location {
                selection.location = max(0, selection.location + delta)
            } else if edit.range.location < NSMaxRange(selection) {
                selection.length = max(0, selection.length + delta)
            }
        }
        return FormattingResult(edits: edits + more, selection: selection)
    }
}

/// Line and block commands for the editor: moving lines, checklists, numbered lists, nesting, code blocks.
public enum EditorCommands {
    // MARK: Lines

    /// The whole lines the selection touches. A selection ending at the start of a line does not take that line.
    static func lineBlock(_ ns: NSString, _ selection: NSRange) -> NSRange {
        var sel = selection
        if sel.length > 0, NSMaxRange(sel) <= ns.length, ns.character(at: NSMaxRange(sel) - 1) == 10 { sel.length -= 1 }
        return ns.lineRange(for: sel)
    }

    /// Moves the lines the selection touches up or down past one line, in one edit. Nil at the top or bottom.
    public static func moveLines(_ text: String, selection: NSRange, up: Bool) -> FormattingResult? {
        let ns = text as NSString
        let block = lineBlock(ns, selection)
        var blockText = ns.substring(with: block)
        if up {
            guard block.location > 0 else { return nil }
            let previous = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var previousText = ns.substring(with: previous)
            if !blockText.hasSuffix("\n") {
                // The last line has no newline; the one moving down past it takes over that ending.
                blockText += "\n"
                previousText.removeLast()
            }
            let replacement = blockText + previousText
            let result = FormattingResult(edits: [TextEdit(NSUnionRange(previous, block), replacement)],
                                          selection: NSRange(location: selection.location - previous.length, length: selection.length))
            return renumbered(result, text: text, near: previous.location)
        }
        guard NSMaxRange(block) < ns.length else { return nil }
        let next = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        var nextText = ns.substring(with: next)
        if !nextText.hasSuffix("\n") {
            nextText += "\n"
            blockText.removeLast()
        }
        let shift = (nextText as NSString).length
        let result = FormattingResult(edits: [TextEdit(NSUnionRange(block, next), nextText + blockText)],
                                      selection: NSRange(location: selection.location + shift, length: selection.length))
        return renumbered(result, text: text, near: block.location)
    }

    // MARK: Checklists

    static let taskPattern = #"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(\[[ xX]\])(?=[ \t]|$)"#

    /// The `[ ]` or `[x]` of the checklist item on the line holding `location`.
    public static func checkbox(in text: String, line location: Int) -> NSRange? {
        let ns = text as NSString
        guard location <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: location, length: 0))
        guard let m = MarkdownScanner.regex("(?m)" + taskPattern)?.firstMatch(in: text, range: line), m.range.location == line.location else { return nil }
        return m.range(at: 1)
    }

    /// Ticks or unticks the checklist item on the line holding `location`, changing only the character in the box.
    public static func toggleCheckbox(_ text: String, line location: Int, selection: NSRange) -> FormattingResult? {
        guard let box = checkbox(in: text, line: location) else { return nil }
        let inner = NSRange(location: box.location + 1, length: 1)
        let checked = (text as NSString).substring(with: inner) != " "
        return FormattingResult(edits: [TextEdit(inner, checked ? " " : "x")], selection: selection)
    }

    // MARK: Numbered lists

    struct ListLine {
        var range: NSRange
        var indent: Int
        var ordered: Bool
        var number: Int?
        var numberRange: NSRange?
    }

    static func listLine(_ ns: NSString, _ range: NSRange) -> ListLine? {
        let line = ns.substring(with: range)
        guard let m = SmartTyping.listPattern?.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        let indent = (line as NSString).substring(with: m.range(at: 1)).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let numberRange = m.range(at: 3)
        guard numberRange.location != NSNotFound else { return ListLine(range: range, indent: indent, ordered: false) }
        return ListLine(range: range, indent: indent, ordered: true, number: Int((line as NSString).substring(with: numberRange)),
                        numberRange: NSRange(location: range.location + numberRange.location, length: numberRange.length))
    }

    /// The lines of the list holding `location`: items, their indented continuation lines and single blank lines between.
    static func listLines(_ ns: NSString, around location: Int) -> [NSRange] {
        guard ns.length > 0 else { return [] }
        let start = ns.lineRange(for: NSRange(location: min(location, ns.length), length: 0))
        func belongs(_ r: NSRange) -> Bool {
            let s = ns.substring(with: r)
            return listLine(ns, r) != nil || (s.first == " " || s.first == "\t") && !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func blank(_ r: NSRange) -> Bool { ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard belongs(start) || blank(start) else { return [] }
        var lines = [start]
        var r = start
        while r.location > 0 {
            let previous = ns.lineRange(for: NSRange(location: r.location - 1, length: 0))
            if belongs(previous) {
                lines.insert(previous, at: 0)
            } else if blank(previous), previous.location > 0, belongs(ns.lineRange(for: NSRange(location: previous.location - 1, length: 0))) {
                lines.insert(previous, at: 0)
            } else {
                break
            }
            r = previous
        }
        r = start
        while NSMaxRange(r) < ns.length {
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(r), length: 0))
            if belongs(next) {
                lines.append(next)
            } else if blank(next), NSMaxRange(next) < ns.length, belongs(ns.lineRange(for: NSRange(location: NSMaxRange(next), length: 0))) {
                lines.append(next)
            } else {
                break
            }
            r = next
        }
        return lines
    }

    /// Numbers the list around `location` 1, 2, 3 at each level. A top-level list keeps the number it starts at;
    /// a nested list starts at 1. Only numbers that change are edited, from the end, so the ranges stay valid.
    public static func renumber(_ text: String, around location: Int) -> [TextEdit] {
        let ns = text as NSString
        var stack: [(indent: Int, ordered: Bool, next: Int)] = []
        var edits: [TextEdit] = []
        // Continuation lines belong to the item above and change nothing.
        for range in listLines(ns, around: location) {
            guard let item = listLine(ns, range) else { continue }
            while let last = stack.last, last.indent > item.indent { stack.removeLast() }
            if let last = stack.last, last.indent == item.indent {
                if item.ordered, last.ordered {
                    if item.number != last.next, let r = item.numberRange { edits.append(TextEdit(r, "\(last.next)")) }
                    stack[stack.count - 1].next += 1
                    continue
                }
                // A bulleted run turning into a numbered one (or back) starts afresh at this level.
                stack.removeLast()
            }
            let nested = !stack.isEmpty
            if item.ordered, nested, item.number != 1, let r = item.numberRange { edits.append(TextEdit(r, "1")) }
            stack.append((item.indent, item.ordered, (nested ? 1 : item.number ?? 1) + 1))
        }
        return edits.reversed()
    }

    static func renumbered(_ result: FormattingResult, text: String, near location: Int) -> FormattingResult {
        let after = result.applied(to: text)
        let edits = renumber(after, around: min(location, (after as NSString).length))
        return edits.isEmpty ? result : result.appending(edits)
    }

    /// Return on a list or quote line, then the list renumbered so the numbers after the new item move up.
    public static func newline(_ text: String, at cursor: Int) -> FormattingResult? {
        guard let result = SmartTyping.newline(in: text, at: cursor) else { return nil }
        return renumbered(result, text: text, near: cursor)
    }

    // MARK: Nesting

    /// Nests or unnests list items (renumbering the list) or quote lines. Nil when the lines are neither.
    public static func indent(_ text: String, selection: NSRange, outdent: Bool) -> FormattingResult? {
        let ns = text as NSString
        if let result = SmartTyping.indent(in: text, selection: selection, outdent: outdent) {
            return renumbered(result, text: text, near: lineBlock(ns, selection).location)
        }
        let block = lineBlock(ns, selection)
        var lines: [NSRange] = []
        var location = block.location
        repeat {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            lines.append(line)
            location = NSMaxRange(line)
        } while location < NSMaxRange(block)
        guard lines.allSatisfy({ ns.substring(with: $0).hasPrefix(">") }) else { return nil }
        var edits: [TextEdit] = []
        var delta = 0
        var firstShift = 0
        for line in lines {
            let content = ns.substring(with: line)
            let change: Int
            if outdent {
                let remove = content.hasPrefix("> ") ? 2 : 1
                edits.append(TextEdit(NSRange(location: line.location + delta, length: remove), ""))
                change = -remove
            } else {
                edits.append(TextEdit(NSRange(location: line.location + delta, length: 0), content.hasPrefix("> ") ? ">" : "> "))
                change = content.hasPrefix("> ") ? 1 : 2
            }
            if line.location == block.location { firstShift = change }
            delta += change
        }
        return FormattingResult(edits: edits, selection: NSRange(location: max(block.location, selection.location + firstShift),
                                                                 length: max(0, selection.length + delta - firstShift)))
    }

    /// Makes the selected lines a numbered list, numbered from 1, or takes the numbers away when they all have them.
    public static func numberedList(_ text: String, selection: NSRange) -> FormattingResult {
        let ns = text as NSString
        let block = lineBlock(ns, selection)
        var lines: [NSRange] = []
        var location = block.location
        repeat {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            lines.append(line)
            location = NSMaxRange(line)
        } while location < NSMaxRange(block)
        let pattern = MarkdownScanner.regex(#"^(\s*)(\d+[.)]|[-*+])\s+"#)
        func marker(_ line: NSRange) -> NSTextCheckingResult? { pattern?.firstMatch(in: text, range: line) }
        func blank(_ line: NSRange) -> Bool { ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let allNumbered = lines.filter { !blank($0) }.allSatisfy { line in
            marker(line).map { ns.substring(with: $0.range(at: 2)).first?.isNumber == true } ?? false
        }
        var edits: [TextEdit] = []
        var delta = 0, firstShift = 0, number = 1
        for line in lines {
            if blank(line), lines.count > 1 { continue }
            let existing = marker(line)
            let replace = existing.map { NSRange(location: $0.range(at: 2).location, length: $0.range.length - $0.range(at: 1).length) }
                ?? NSRange(location: line.location, length: 0)
            let new = allNumbered ? "" : "\(number). "
            number += 1
            edits.append(TextEdit(NSRange(location: replace.location + delta, length: replace.length), new))
            let change = (new as NSString).length - replace.length
            if line.location == block.location { firstShift = change }
            delta += change
        }
        let result = FormattingResult(edits: edits, selection: NSRange(location: max(block.location, selection.location + firstShift),
                                                                       length: max(0, selection.length + delta - firstShift)))
        return allNumbered ? result : renumbered(result, text: text, near: block.location)
    }

    // MARK: Code blocks

    /// A fenced code block: the opening fence line, the info string (language) on it, and the whole block.
    public struct CodeBlock: Sendable, Equatable {
        public var range: NSRange
        public var infoRange: NSRange
        public var language: String
    }

    static let fencePattern = #"(?m)^[ ]{0,3}(`{3,}|~{3,})[ \t]*([^`\n]*?)[ \t]*$"#

    /// The fenced block the location is in, fences included.
    public static func codeBlock(in text: String, at location: Int) -> CodeBlock? {
        let ns = text as NSString
        guard let regex = MarkdownScanner.regex(fencePattern) else { return nil }
        var open: NSTextCheckingResult?
        var found: CodeBlock?
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m else { return }
            guard let start = open else {
                if m.range.location > location { stop.pointee = true } else { open = m }
                return
            }
            let fence = ns.substring(with: start.range(at: 1)), close = ns.substring(with: m.range(at: 1))
            guard close.first == fence.first, close.count >= fence.count, m.range(at: 2).length == 0 else { return }
            let range = NSRange(location: start.range.location, length: NSMaxRange(m.range) - start.range.location)
            if location >= range.location, location <= NSMaxRange(range) {
                found = CodeBlock(range: range, infoRange: start.range(at: 2), language: ns.substring(with: start.range(at: 2)))
            }
            open = nil
            if NSMaxRange(m.range) >= location { stop.pointee = true }
        }
        return found
    }

    /// Writes the language on the opening fence; an empty language clears it.
    public static func setCodeLanguage(_ text: String, block: CodeBlock, language: String, selection: NSRange) -> FormattingResult {
        let fence = block.infoRange
        let ns = text as NSString
        // A fence with nothing after it: write straight after the backticks.
        let replace = fence.length == 0 ? NSRange(location: fence.location, length: 0) : fence
        let lineStart = ns.lineRange(for: NSRange(location: block.range.location, length: 0)).location
        let afterFence = ns.substring(with: NSRange(location: lineStart, length: replace.location - lineStart))
        let trimmedReplace = afterFence.hasSuffix(" ") && language.isEmpty
            ? NSRange(location: replace.location - 1, length: replace.length + 1) : replace
        let delta = (language as NSString).length - trimmedReplace.length
        var sel = selection
        if sel.location > trimmedReplace.location { sel.location += delta }
        return FormattingResult(edits: [TextEdit(trimmedReplace, language)], selection: sel)
    }

    /// Wraps the selected lines in a fenced code block, or unwraps the block the cursor is in.
    public static func toggleCodeBlock(_ text: String, selection: NSRange) -> FormattingResult {
        let ns = text as NSString
        if let block = codeBlock(in: text, at: selection.location) {
            let open = ns.lineRange(for: NSRange(location: block.range.location, length: 0))
            let closeLine = ns.lineRange(for: NSRange(location: NSMaxRange(block.range) - 1, length: 0))
            // Remove the closing fence first so the opening one's range stays put.
            var closeRemove = closeLine
            if NSMaxRange(closeLine) == ns.length, closeLine.location > 0, ns.character(at: NSMaxRange(closeLine) - 1) != 10 {
                closeRemove = NSRange(location: closeLine.location - 1, length: closeLine.length + 1)
            }
            let edits = [TextEdit(closeRemove, ""), TextEdit(open, "")]
            let newLength = ns.length - closeRemove.length - open.length
            let location = min(max(open.location, selection.location - open.length), newLength)
            return FormattingResult(edits: edits, selection: NSRange(location: location, length: min(selection.length, newLength - location)))
        }
        let block = lineBlock(ns, selection)
        var inner = ns.substring(with: block)
        let hadNewline = inner.hasSuffix("\n")
        if hadNewline { inner.removeLast() }
        let replacement = "```\n" + inner + "\n```" + (hadNewline ? "\n" : "")
        return FormattingResult(edits: [TextEdit(block, replacement)],
                                selection: NSRange(location: block.location + 4 + (selection.location - block.location), length: selection.length))
    }

    /// Languages offered for code blocks, as written after the fence.
    public static let codeLanguages = [
        "bash", "c", "cpp", "csharp", "css", "diff", "go", "html", "java", "javascript", "json", "kotlin", "liquid", "markdown",
        "php", "plaintext", "python", "ruby", "rust", "scss", "shell", "sql", "swift", "typescript", "xml", "yaml",
    ]

    // MARK: Clear formatting

    static let inlineTags = ["u", "mark", "sup", "sub", "s", "del", "ins", "em", "strong", "b", "i", "small", "kbd", "code", "span"]

    /// Takes bold, italic, underline, strikethrough, highlight, code, superscript, subscript and links off the selection,
    /// keeping the words. Markers just outside the selection that wrap it are removed too.
    public static func clearFormatting(_ text: String, selection: NSRange) -> FormattingResult? {
        let ns = text as NSString
        guard selection.length > 0 else { return nil }
        let paragraph = ns.paragraphRange(for: selection)
        let spans = MarkdownScanner.scan(ns.substring(with: paragraph))
            .map { StyleSpan($0.style, NSRange(location: $0.range.location + paragraph.location, length: $0.range.length)) }
        var remove: [NSRange] = []
        let styled: Set<MarkdownStyle> = [.bold, .italic, .strike, .highlight, .underline, .code]
        // A styled span touching the selection loses its markers at both ends.
        for span in spans where styled.contains(span.style) && NSIntersectionRange(span.range, selection).length > 0 {
            remove += spans.filter { $0.style == .syntax && $0.range.length <= 7 && NSIntersectionRange($0.range, span.range).length == $0.range.length }
                .filter { $0.range.location == span.range.location || NSMaxRange($0.range) == NSMaxRange(span.range) }
                .map(\.range)
        }
        for link in MarkdownLink.all(in: text, range: paragraph) where NSIntersectionRange(link.range, selection).length > 0 && !link.isAutolink {
            remove.append(NSRange(location: link.range.location, length: link.textRange.location - link.range.location))
            remove.append(NSRange(location: NSMaxRange(link.textRange), length: NSMaxRange(link.range) - NSMaxRange(link.textRange)))
        }
        // Inline HTML such as <sup> and <span>: each pair whose content touches or wraps the selection.
        let tagPattern = "<(/?)(" + inlineTags.joined(separator: "|") + ")(?:\\s[^>]*)?>"
        var open: [String: [NSRange]] = [:]
        for m in MarkdownScanner.regex(tagPattern)?.matches(in: text, range: paragraph) ?? [] {
            let name = ns.substring(with: m.range(at: 2))
            if m.range(at: 1).length == 0 {
                open[name, default: []].append(m.range)
            } else if let start = open[name]?.popLast() {
                let pair = NSRange(location: start.location, length: NSMaxRange(m.range) - start.location)
                if NSIntersectionRange(pair, selection).length > 0 { remove += [start, m.range] }
            }
        }
        // Merged where they touch or repeat, and removed from the end so each range stays valid.
        var merged: [NSRange] = []
        for r in remove.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, r.location <= NSMaxRange(last) { merged[merged.count - 1] = NSUnionRange(last, r) } else { merged.append(r) }
        }
        let unique = Array(merged.reversed())
        guard !unique.isEmpty else { return nil }
        var start = selection.location, end = NSMaxRange(selection)
        for r in unique {
            if NSMaxRange(r) <= start { start -= r.length } else if r.location < start { start = r.location }
            if NSMaxRange(r) <= end { end -= r.length } else if r.location < end { end = r.location }
        }
        return FormattingResult(edits: unique.map { TextEdit($0, "") }, selection: NSRange(location: start, length: max(0, end - start)))
    }
}

/// What is in effect at the cursor or over the selection, for the formatting bar.
public struct FormatState: Sendable, Equatable {
    public enum Block: Sendable, Equatable {
        case body
        case heading(Int)
        case code
    }

    public enum List: Sendable, Equatable {
        case bullets
        case numbers
        case checklist
    }

    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var highlight = false
    public var code = false
    public var superscript = false
    public var `subscript` = false
    public var link = false
    public var quote = false
    public var block: Block = .body
    public var list: List?
    /// The fenced code block's language, empty for none; nil outside a code block.
    public var codeLanguage: String?

    public init() {}

    /// Looks only at the paragraph around the selection, plus the fences before it, so it stays quick in long posts.
    public static func at(_ text: String, selection: NSRange) -> FormatState {
        var state = FormatState()
        let ns = text as NSString
        guard ns.length > 0 else { return state }
        let sel = NSIntersectionRange(selection, NSRange(location: 0, length: ns.length))
        if let block = EditorCommands.codeBlock(in: text, at: sel.location) {
            state.block = .code
            state.codeLanguage = block.language
            return state
        }
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = ns.substring(with: line)
        let hashes = lineText.prefix { $0 == "#" }.count
        if hashes > 0, hashes <= 6, lineText.dropFirst(hashes).first == " " { state.block = .heading(hashes) }
        state.quote = lineText.hasPrefix(">")
        if let item = EditorCommands.listLine(ns, line) {
            state.list = EditorCommands.checkbox(in: text, line: line.location) != nil ? .checklist : item.ordered ? .numbers : .bullets
        }
        let paragraph = ns.paragraphRange(for: sel)
        guard paragraph.length < 20000 else { return state }
        let local = NSRange(location: sel.location - paragraph.location, length: sel.length)
        let spans = MarkdownScanner.scan(ns.substring(with: paragraph))
        func covers(_ r: NSRange) -> Bool {
            local.length == 0 ? local.location > r.location && local.location < NSMaxRange(r)
                : r.location <= local.location && NSMaxRange(r) >= NSMaxRange(local)
        }
        for span in spans where covers(span.range) {
            switch span.style {
            case .bold: state.bold = true
            case .italic: state.italic = true
            case .underline: state.underline = true
            case .strike: state.strikethrough = true
            case .highlight: state.highlight = true
            case .code: state.code = true
            case .link, .url: state.link = true
            default: break
            }
        }
        let paragraphText = ns.substring(with: paragraph)
        for (tag, flag) in [("sup", \FormatState.superscript), ("sub", \FormatState.subscript)] {
            for m in MarkdownScanner.matches("<\(tag)>(.+?)</\(tag)>", paragraphText) where covers(m.range) { state[keyPath: flag] = true }
        }
        return state
    }
}

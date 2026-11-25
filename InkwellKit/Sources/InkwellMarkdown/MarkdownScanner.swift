import Foundation

public enum MarkdownStyle: Sendable, Hashable {
    case frontMatter
    case heading(Int)
    /// Markers such as `**`, `#` and `>` that the editor dims.
    case syntax
    case bold
    case italic
    case strike
    case highlight
    case underline
    case code
    case codeBlock
    case quote
    case listMarker
    case link
    case url
    case image
    case footnoteRef
    case footnoteDef
    case rule
    case liquid
    case html
    case math
}

public struct StyleSpan: Sendable, Hashable {
    public var style: MarkdownStyle
    public var range: NSRange

    public init(_ style: MarkdownStyle, _ range: NSRange) {
        self.style = style
        self.range = range
    }
}

/// Finds the ranges the live-preview editor styles. It never changes the text: styling is attributes only,
/// so what is saved is exactly what was typed.
public enum MarkdownScanner {
    public static func scan(_ text: String) -> [StyleSpan] {
        let ns = text as NSString
        var spans: [StyleSpan] = []
        var blocked: [NSRange] = []
        var location = 0
        var inFence = false
        var inMath = false
        var lineIndex = 0
        var inFrontMatter = false

        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            var contentRange = lineRange
            while contentRange.length > 0, [10, 13].contains(ns.character(at: NSMaxRange(contentRange) - 1)) { contentRange.length -= 1 }
            let line = ns.substring(with: contentRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer {
                location = NSMaxRange(lineRange)
                lineIndex += 1
            }

            if lineIndex == 0, trimmed == "---" {
                inFrontMatter = true
                spans.append(StyleSpan(.frontMatter, contentRange))
                blocked.append(lineRange)
                continue
            }
            if inFrontMatter {
                spans.append(StyleSpan(.frontMatter, contentRange))
                blocked.append(lineRange)
                if trimmed == "---" || trimmed == "..." { inFrontMatter = false }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                spans.append(StyleSpan(.codeBlock, contentRange))
                spans.append(StyleSpan(.syntax, contentRange))
                blocked.append(lineRange)
                continue
            }
            if inFence {
                spans.append(StyleSpan(.codeBlock, contentRange))
                blocked.append(lineRange)
                continue
            }
            if trimmed == "$$" || (trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count > 4) {
                if trimmed == "$$" { inMath.toggle() }
                spans.append(StyleSpan(.math, contentRange))
                blocked.append(lineRange)
                continue
            }
            if inMath {
                spans.append(StyleSpan(.math, contentRange))
                blocked.append(lineRange)
                continue
            }
            let start = contentRange.location
            if let m = firstMatch(#"^(#{1,6})\s+"#, line) {
                let level = m.range(at: 1).length
                spans.append(StyleSpan(.heading(level), contentRange))
                spans.append(StyleSpan(.syntax, NSRange(location: start, length: m.range.length)))
            } else if firstMatch(#"^ {0,3}([-*_])( *\1){2,} *$"#, line) != nil {
                spans.append(StyleSpan(.rule, contentRange))
                spans.append(StyleSpan(.syntax, contentRange))
                blocked.append(lineRange)
                continue
            } else if let m = firstMatch(#"^(\s*>\s?)+"#, line) {
                spans.append(StyleSpan(.quote, contentRange))
                spans.append(StyleSpan(.syntax, NSRange(location: start, length: m.range.length)))
            } else if let m = firstMatch(#"^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, line) {
                spans.append(StyleSpan(.listMarker, NSRange(location: start, length: m.range.length)))
            } else if let m = firstMatch(#"^\[\^[^\]]+\]:"#, line) {
                spans.append(StyleSpan(.footnoteDef, contentRange))
                spans.append(StyleSpan(.syntax, NSRange(location: start, length: m.range.length)))
            } else if firstMatch(#"^\{:.*\}\s*$"#, line) != nil {
                spans.append(StyleSpan(.syntax, contentRange))
                continue
            }
            inline(line, offset: start, spans: &spans, blocked: blocked)
        }
        return spans
    }

    static func inline(_ line: String, offset: Int, spans: inout [StyleSpan], blocked _: [NSRange]) {
        var taken: [NSRange] = []
        func shifted(_ r: NSRange) -> NSRange { NSRange(location: r.location + offset, length: r.length) }
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in matches(#"`[^`]+`"#, line) {
            spans.append(StyleSpan(.code, shifted(m.range)))
            spans.append(StyleSpan(.syntax, shifted(NSRange(location: m.range.location, length: 1))))
            spans.append(StyleSpan(.syntax, shifted(NSRange(location: NSMaxRange(m.range) - 1, length: 1))))
            taken.append(m.range)
        }
        for m in matches(#"\{\{.*?\}\}|\{%.*?%\}"#, line) where free(m.range) {
            spans.append(StyleSpan(.liquid, shifted(m.range)))
            taken.append(m.range)
        }
        for m in matches(#"!\[[^\]]*\]\([^)]*\)"#, line) where free(m.range) {
            spans.append(StyleSpan(.image, shifted(m.range)))
            taken.append(m.range)
        }
        for m in matches(#"(?<!\!)\[([^\]^][^\]]*)\]\(([^)]+)\)"#, line) where free(m.range) {
            let text = m.range(at: 1)
            spans.append(StyleSpan(.link, shifted(text)))
            spans.append(StyleSpan(.syntax, shifted(NSRange(location: m.range.location, length: 1))))
            let tail = NSRange(location: NSMaxRange(text), length: NSMaxRange(m.range) - NSMaxRange(text))
            spans.append(StyleSpan(.url, shifted(tail)))
            // The address hides with the opening bracket away from the cursor, so a link reads as its text alone.
            spans.append(StyleSpan(.syntax, shifted(tail)))
            taken.append(m.range)
        }
        for m in matches(#"\[\^[^\]]+\]"#, line) where free(m.range) {
            spans.append(StyleSpan(.footnoteRef, shifted(m.range)))
            taken.append(m.range)
        }
        let pairs: [(String, MarkdownStyle, Int)] = [
            (#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, .bold, 2),
            (#"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#, .italic, 1),
            (#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#, .italic, 1),
            (#"~~(?=\S)(.+?)(?<=\S)~~"#, .strike, 2),
        ]
        for (pattern, style, width) in pairs {
            for m in matches(pattern, line) where free(m.range) {
                spans.append(StyleSpan(style, shifted(m.range)))
                spans.append(StyleSpan(.syntax, shifted(NSRange(location: m.range.location, length: width))))
                spans.append(StyleSpan(.syntax, shifted(NSRange(location: NSMaxRange(m.range) - width, length: width))))
            }
        }
        for (tag, style) in [("mark", MarkdownStyle.highlight), ("u", .underline)] {
            for m in matches("<\(tag)>(.+?)</\(tag)>", line) where free(m.range) {
                spans.append(StyleSpan(style, shifted(m.range)))
                let open = tag.count + 2, close = tag.count + 3
                spans.append(StyleSpan(.syntax, shifted(NSRange(location: m.range.location, length: open))))
                spans.append(StyleSpan(.syntax, shifted(NSRange(location: NSMaxRange(m.range) - close, length: close))))
                taken.append(NSRange(location: m.range.location, length: open))
                taken.append(NSRange(location: NSMaxRange(m.range) - close, length: close))
            }
        }
        for m in matches(#"</?[a-zA-Z][^>]*>|<!--.*?-->"#, line) where free(m.range) {
            spans.append(StyleSpan(.html, shifted(m.range)))
        }
    }

    static func firstMatch(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        regex(pattern)?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        regex(pattern)?.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) ?? []
    }

    nonisolated(unsafe) static var cache: [String: NSRegularExpression] = [:]
    static let lock = NSLock()

    static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[pattern] { return cached }
        let made = try? NSRegularExpression(pattern: pattern)
        cache[pattern] = made
        return made
    }
}

import Foundation

/// Which palette a `:root` block belongs to: the default one (`light`, for historical reasons the name of the plain
/// `:root` block), or an override for readers in dark mode or light mode.
public enum ColorSchemeKind: String, Sendable, Codable, Hashable {
    case light
    case dark
    case lightMode
}

public enum TokenKind: String, Sendable, Codable, Hashable {
    case color
    case font
    case length
    case number
    case other

    /// A best guess from the value, for themes Inkwell did not write.
    public static func infer(name: String, value: String) -> TokenKind {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        if v.hasPrefix("#") || v.hasPrefix("rgb") || v.hasPrefix("hsl") || v.hasPrefix("oklch") || v.hasPrefix("color(") { return .color }
        if v.range(of: #"^-?[\d.]+(px|rem|em|%|ch|vw|vh)$"#, options: .regularExpression) != nil { return .length }
        if Double(v) != nil { return .number }
        let generic = ["serif", "sans", "mono", "system", "cursive", "rounded"].contains { v.contains($0) }
        if v.contains(",") && generic || name.contains("font-family") || name.hasSuffix("font") && !v.contains("$") && !v.contains("(") {
            return .font
        }
        return .other
    }
}

/// CSS custom properties in `:root` blocks, edited in place. Only the value text of a changed property is replaced,
/// so comments, order and formatting stay as written. Blocks inside `@media (prefers-color-scheme: dark)` are the
/// dark palette.
public struct CSSTokenDocument: Sendable, Equatable {
    public private(set) var text: String

    public struct Token: Sendable, Equatable {
        public var name: String
        public var value: String
        public var scheme: ColorSchemeKind
        public var kind: TokenKind { TokenKind.infer(name: name, value: value) }
        var valueRange: NSRange
    }

    struct Block {
        var scheme: ColorSchemeKind
        var contentRange: NSRange
    }

    public init(text: String) {
        self.text = text
    }

    public var tokens: [Token] {
        var result: [Token] = []
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"(--[A-Za-z0-9_-]+)\s*:\s*"#) else { return [] }
        for block in blocks() {
            let content = Self.maskingComments(ns.substring(with: block.contentRange)) as NSString
            var scanned = 0
            for m in regex.matches(in: content as String, range: NSRange(location: 0, length: content.length)) where m.range.location >= scanned {
                let name = content.substring(with: m.range(at: 1))
                let start = NSMaxRange(m.range)
                let end = Self.valueEnd(in: content, from: start)
                scanned = end
                var trimmedEnd = end
                while trimmedEnd > start, [32, 9, 10, 13].contains(content.character(at: trimmedEnd - 1)) { trimmedEnd -= 1 }
                let valueRange = NSRange(location: block.contentRange.location + start, length: trimmedEnd - start)
                result.append(Token(name: name, value: ns.substring(with: valueRange), scheme: block.scheme, valueRange: valueRange))
            }
        }
        return result
    }

    /// Where a property's value ends: the first `;` or `}` outside quotes and brackets, so `url("data:…;utf8,…")` and
    /// strings with semicolons stay whole.
    static func valueEnd(in text: NSString, from start: Int) -> Int {
        var quote: unichar?
        var depth = 0
        var i = start
        while i < text.length {
            let c = text.character(at: i)
            if let open = quote {
                if c == 92 { i += 2; continue } // a backslash escapes the next character
                if c == open { quote = nil }
            } else if c == 34 || c == 39 {
                quote = c
            } else if c == 40 || c == 91 {
                depth += 1
            } else if c == 41 || c == 93 {
                depth = max(0, depth - 1)
            } else if depth == 0, c == 59 || c == 125 {
                return i
            }
            i += 1
        }
        return min(i, text.length)
    }

    public func value(_ name: String, scheme: ColorSchemeKind = .light) -> String? {
        tokens.last { $0.name == name && $0.scheme == scheme }?.value
    }

    public var hasDarkPalette: Bool { blocks().contains { $0.scheme == .dark } }
    public var hasLightModePalette: Bool { blocks().contains { $0.scheme == .lightMode } }

    /// Sets a property, adding it at the end of the palette's block (and the block itself) when missing.
    public mutating func set(_ name: String, to value: String, scheme: ColorSchemeKind = .light) {
        let ns = text as NSString
        if let token = tokens.last(where: { $0.name == name && $0.scheme == scheme }) {
            guard token.value != value else { return }
            text = ns.replacingCharacters(in: token.valueRange, with: value)
            return
        }
        if let block = blocks().last(where: { $0.scheme == scheme }) {
            let indent = indentation(in: block) ?? "    "
            var insertAt = NSMaxRange(block.contentRange)
            // Insert after the last non-space character, keeping the closing brace on its own line.
            while insertAt > block.contentRange.location, [32, 9, 10].contains(ns.character(at: insertAt - 1)) { insertAt -= 1 }
            text = ns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: "\n\(indent)\(name): \(value);")
            return
        }
        let separator = text.hasSuffix("\n") || text.isEmpty ? "" : "\n"
        switch scheme {
        case .light:
            text += "\(separator)\n:root {\n    \(name): \(value);\n}\n"
        case .dark, .lightMode:
            let mode = scheme == .dark ? "dark" : "light"
            text += "\(separator)\n@media (prefers-color-scheme: \(mode)) {\n    :root {\n        \(name): \(value);\n    }\n}\n"
        }
    }

    func indentation(in block: Block) -> String? {
        let content = (text as NSString).substring(with: block.contentRange)
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("--") { return String(line.prefix { $0 == " " || $0 == "\t" }) }
        }
        return nil
    }

    /// Every `:root` rule with the range of what is between its braces.
    func blocks() -> [Block] {
        let masked = Self.maskingComments(text)
        let chars = Array(masked.utf16)
        var result: [Block] = []
        var stack: [(prelude: String, start: Int)] = []
        var preludeStart = 0
        for (i, c) in chars.enumerated() {
            if c == 123 { // {
                let prelude = String(utf16CodeUnits: Array(chars[preludeStart ..< i]), count: i - preludeStart)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stack.append((prelude, i + 1))
                preludeStart = i + 1
            } else if c == 125 { // }
                if let open = stack.popLast() {
                    let selectors = open.prelude.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if selectors.contains(where: { $0 == ":root" || $0 == "html" }) {
                        let preludes = stack.map { $0.prelude.replacingOccurrences(of: " ", with: "") }
                        let scheme: ColorSchemeKind = preludes.contains { $0.contains("prefers-color-scheme:dark") } ? .dark
                            : preludes.contains { $0.contains("prefers-color-scheme:light") } ? .lightMode : .light
                        result.append(Block(scheme: scheme, contentRange: NSRange(location: open.start, length: i - open.start)))
                    }
                }
                preludeStart = i + 1
            } else if c == 59 { // ;
                preludeStart = i + 1
            }
        }
        return result
    }

    /// Replaces comment text with spaces of the same UTF-16 length, so ranges still line up.
    static func maskingComments(_ text: String) -> String {
        guard text.contains("/*") else { return text }
        var units = Array(text.utf16)
        var i = 0
        while i + 1 < units.count {
            if units[i] == 47, units[i + 1] == 42 { // /*
                var j = i + 2
                while j + 1 < units.count, !(units[j] == 42 && units[j + 1] == 47) { j += 1 }
                let end = min(j + 2, units.count)
                for k in i ..< end where units[k] != 10 { units[k] = 32 }
                i = end
            } else {
                i += 1
            }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }
}

import Foundation

/// Sass variables, as SCSS themes such as minima expose their design: `$brand-color: #2a7ae2 !default;` in the theme,
/// overridden by `$brand-color: #c0392b;` in the site's own `assets/main.scss` before the theme is imported.
public enum SassVariables {
    static let pattern = try? NSRegularExpression(pattern: #"(?m)^\$([A-Za-z0-9_-]+)\s*:\s*(.+?)\s*(!default)?\s*;[ \t]*(?://.*)?$"#)

    /// Top-level `$name: value !default;` declarations, in order (only those marked `!default` when `defaultsOnly`).
    public static func declarations(in text: String, defaultsOnly: Bool) -> [(name: String, value: String)] {
        let ns = text as NSString
        return (pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []).compactMap { m in
            let isDefault = m.range(at: 3).location != NSNotFound
            guard !defaultsOnly || isDefault else { return nil }
            return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
        }
    }

    /// Sets `$name: value;` in a stylesheet: replaces an existing override, or adds one before the first import.
    public static func set(_ name: String, to value: String, in text: String) -> String {
        let ns = text as NSString
        for m in pattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
            where ns.substring(with: m.range(at: 1)) == name && m.range(at: 3).location == NSNotFound {
            return ns.replacingCharacters(in: m.range(at: 2), with: value)
        }
        var lines = text.components(separatedBy: "\n")
        var insertAt = 0
        let isFence: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces) == "---" }
        if let first = lines.first, isFence(first), let close = lines.dropFirst().firstIndex(where: isFence) {
            insertAt = close + 1
        }
        // New overrides go just above the theme import, after any earlier ones.
        if let firstImport = lines.indices.first(where: { $0 >= insertAt && (lines[$0].hasPrefix("@import") || lines[$0].hasPrefix("@use")) }) {
            insertAt = firstImport
        }
        lines.insert("$\(name): \(value);", at: insertAt)
        return lines.joined(separator: "\n")
    }
}

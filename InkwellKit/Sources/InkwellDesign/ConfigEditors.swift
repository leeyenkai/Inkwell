import Foundation
import InkwellCore

/// `_config.yml` edited line by line: changing a setting rewrites only that setting's line, and comments stay.
/// Handles top-level keys and keys one level down (`author.name`, `inkwell.theme`).
public struct ConfigDocument: Sendable, Equatable {
    public private(set) var lines: [String]
    private var trailingNewline: Bool

    public init(text: String) {
        trailingNewline = text.hasSuffix("\n")
        var all = text.components(separatedBy: "\n")
        if trailingNewline { all.removeLast() }
        lines = all
    }

    public var text: String { lines.joined(separator: "\n") + (trailingNewline || lines.isEmpty ? "\n" : "") }
    public var values: YAMLValue { YAML.parse(lines.joined(separator: "\n")) }

    public func value(_ path: String) -> YAMLValue? {
        var value: YAMLValue? = values
        for key in path.split(separator: ".") { value = value?[String(key)] }
        return value
    }

    /// Sets `key` or `parent.key` to an already formatted YAML value; nil removes it. Equal values change nothing.
    public mutating func set(_ path: String, raw: String?) {
        let keys = path.split(separator: ".").map(String.init)
        if let current = value(path), let raw, current == YAML.parse("x: \(raw)")["x"] { return }
        if keys.count == 1 {
            setTop(keys[0], raw: raw)
        } else {
            setNested(keys[0], keys[1], raw: raw)
        }
    }

    struct Span { var key: String; var range: Range<Int> }

    func spans(indent: Int, in range: Range<Int>) -> [Span] {
        var result: [Span] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let line = lines[i]
            let lead = line.prefix { $0 == " " }.count
            let content = String(line.dropFirst(lead))
            if lead == indent, !content.hasPrefix("#"), !content.hasPrefix("- "), let (key, _) = splitKey(content) {
                let end = extent(of: i, indent: indent, limit: range.upperBound)
                result.append(Span(key: key, range: i ..< end))
                i = max(end, i + 1)
            } else {
                i += 1
            }
        }
        return result
    }

    /// The key's own line plus everything nested under it (a list at the same indent counts as nested).
    func extent(of start: Int, indent: Int, limit: Int) -> Int {
        var i = start + 1
        while i < limit {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                let lead = line.prefix { $0 == " " }.count
                if lead < indent || lead == indent && !trimmed.hasPrefix("- ") { break }
            }
            i += 1
        }
        return contentEnd(start, i)
    }

    func contentEnd(_ start: Int, _ end: Int) -> Int {
        var upper = end
        while upper > start + 1 {
            let trimmed = lines[upper - 1].trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
            upper -= 1
        }
        return upper
    }

    func splitKey(_ content: String) -> (String, String)? {
        guard let colon = content.firstIndex(of: ":") else { return nil }
        let after = content.index(after: colon)
        guard after == content.endIndex || content[after] == " " else { return nil }
        let key = content[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") || key.hasPrefix("\"") else { return nil }
        return (key, String(content[after...]))
    }

    mutating func setTop(_ key: String, raw: String?) {
        let top = spans(indent: 0, in: 0 ..< lines.count)
        if let span = top.first(where: { $0.key == key }) {
            if let raw { lines.replaceSubrange(span.range, with: ["\(key): \(raw)"]) } else { lines.removeSubrange(span.range) }
        } else if let raw {
            lines.append("\(key): \(raw)")
        }
    }

    mutating func setNested(_ parent: String, _ key: String, raw: String?) {
        let top = spans(indent: 0, in: 0 ..< lines.count)
        guard let parentSpan = top.first(where: { $0.key == parent }) else {
            guard let raw else { return }
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("\(parent):")
            lines.append("  \(key): \(raw)")
            return
        }
        let inner = parentSpan.range.lowerBound + 1 ..< parentSpan.range.upperBound
        let snapshot = lines
        let firstChild = inner.map { snapshot[$0] }.first {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        let childIndent = firstChild.map { $0.prefix { $0 == " " }.count } ?? 2
        let children = spans(indent: childIndent, in: inner)
        if let child = children.first(where: { $0.key == key }) {
            if let raw {
                lines.replaceSubrange(child.range, with: [String(repeating: " ", count: childIndent) + "\(key): \(raw)"])
            } else {
                lines.removeSubrange(child.range)
            }
        } else if let raw {
            if parentSpan.range.count == 1, let (_, rest) = splitKey(lines[parentSpan.range.lowerBound]),
               !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                lines[parentSpan.range.lowerBound] = "\(parent):"
            }
            lines.insert(String(repeating: " ", count: childIndent) + "\(key): \(raw)", at: children.last?.range.upperBound ?? inner.lowerBound)
        }
    }
}

public struct NavigationEntry: Sendable, Equatable, Hashable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// `_data/navigation.yml`: a list of `title` and `url` pairs. Writing keeps the comment lines at the top of the file.
public struct NavigationDocument: Sendable, Equatable {
    public var entries: [NavigationEntry]
    private var header: [String]

    public init(text: String) {
        let lines = text.components(separatedBy: "\n")
        header = Array(lines.prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") || $0.trimmingCharacters(in: .whitespaces).isEmpty })
        while header.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { header.removeLast() }
        entries = (YAML.parse(text).list ?? []).compactMap { item in
            guard let title = item["title"]?.string, let url = item["url"]?.string else { return nil }
            return NavigationEntry(title: title, url: url)
        }
    }

    public init(entries: [NavigationEntry]) {
        self.entries = entries
        header = ["# Site navigation, in order. Edited by Inkwell; plain YAML, so it can be edited by hand too."]
    }

    public var text: String {
        var out = header.map { $0 + "\n" }.joined()
        for entry in entries {
            out += "- title: \(YAMLFormat.plainOrQuoted(entry.title))\n  url: \(YAMLFormat.plainOrQuoted(entry.url))\n"
        }
        return out
    }

    public mutating func move(from source: Int, to destination: Int) {
        let entry = entries.remove(at: source)
        entries.insert(entry, at: min(destination, entries.count))
    }
}

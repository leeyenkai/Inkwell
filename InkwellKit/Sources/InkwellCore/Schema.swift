import Foundation

public enum FieldKind: Sendable, Hashable {
    case text
    case date
    case toggle
    case tags
}

public struct FieldSpec: Sendable, Hashable, Identifiable {
    public var key: String
    public var kind: FieldKind
    /// How many of the section's files carry the field.
    public var count: Int
    public var total: Int
    public var defaultBool: Bool?

    public var id: String { key }
    public var isUniversal: Bool { total > 0 && count == total }
    public var label: String { key.replacingOccurrences(of: "_", with: " ").capitalized }
}

/// Infers a section's fields from the files already in it, so new posts get what the old ones have.
public enum SchemaInference {
    static let preferredOrder = ["title", "byline", "subtitle", "date", "tags", "categories", "image", "published"]
    static let known: [String: FieldKind] = ["title": .text, "byline": .text, "date": .date, "published": .toggle, "tags": .tags]
    static let handledElsewhere: Set = ["layout", "permalink"]

    public static func infer(_ documents: [FrontMatterDocument]) -> [FieldSpec] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var kinds: [String: FieldKind] = [:]
        var bools: [String: [Bool]] = [:]
        for doc in documents {
            let values = doc.values
            for key in doc.keys where !handledElsewhere.contains(key) {
                if counts[key] == nil { order.append(key) }
                counts[key, default: 0] += 1
                guard let value = values[key] else { continue }
                let kind = kind(of: key, value: value)
                if kinds[key] == nil || kinds[key] == .text { kinds[key] = kind }
                if case let .bool(b) = value { bools[key, default: []].append(b) }
            }
        }
        for key in ["title", "date"] where counts[key] == nil {
            order.append(key)
            counts[key] = 0
        }
        let sorted = order.sorted { a, b in
            let ia = preferredOrder.firstIndex(of: a) ?? preferredOrder.count
            let ib = preferredOrder.firstIndex(of: b) ?? preferredOrder.count
            return ia != ib ? ia < ib : order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
        return sorted.map { key in
            let values = bools[key] ?? []
            let majority = values.isEmpty ? nil : values.filter { $0 }.count * 2 >= values.count
            return FieldSpec(key: key, kind: kinds[key] ?? known[key] ?? .text, count: counts[key] ?? 0, total: documents.count,
                             defaultBool: majority)
        }
    }

    static func kind(of key: String, value: YAMLValue) -> FieldKind {
        if let kind = known[key] { return kind }
        switch value {
        case .bool: return .toggle
        case .list: return .tags
        case let .string(s) where SiteDate.parse(s) != nil && s.count >= 10: return .date
        default: return .text
        }
    }

    public static func preferredOrderKeys(_ fields: [FieldSpec]) -> [String] { fields.map(\.key) }
}

public struct Issue: Sendable, Hashable, Identifiable {
    public enum Severity: Sendable, Hashable { case error, warning }

    public var severity: Severity
    public var field: String?
    public var message: String
    public var id: String { "\(field ?? "-"):\(message)" }

    public init(_ severity: Severity, field: String? = nil, _ message: String) {
        self.severity = severity
        self.field = field
        self.message = message
    }
}

public enum Validation {
    public static func frontMatter(_ doc: FrontMatterDocument, filename: String, inCollection: Bool) -> [Issue] {
        var issues: [Issue] = []
        for span in doc.fieldSpans() {
            guard let raw = doc.rawValue(span.key) else { continue }
            let continuation = doc.rawLines(span.key).dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            let value = ([YAML.stripComment(raw).trimmingCharacters(in: .whitespaces)] + continuation).joined(separator: " ")
            if let quote = value.first, quote == "\"" || quote == "'", !isClosed(value, quote: quote) {
                issues.append(Issue(.error, field: span.key, localized("The \(span.key) has an opening \(String(quote)) but no closing one.")))
            }
        }
        let values = doc.values
        if inCollection, values["title"]?.string?.isEmpty ?? true {
            issues.append(Issue(.warning, field: "title", localized("The post has no title.")))
        }
        let parts = Filename.parse(filename)
        if let raw = values["date"]?.string {
            if SiteDate.parse(raw) == nil {
                issues.append(Issue(.error, field: "date", localized("“\(raw)” is not a date. Use YYYY-MM-DD.")))
            } else if let fileDate = parts.dateText, normalised(raw) != normalised(fileDate) {
                issues.append(Issue(.warning, field: "date", localized("The date \(raw) does not match the filename’s \(fileDate).")))
            }
        }
        if inCollection, parts.dateText != nil, !parts.isZeroPadded {
            issues.append(Issue(.error, field: "date", localized("The filename date is not zero-padded (\(parts.dateText ?? "")).")))
        }
        return issues
    }

    static func isClosed(_ value: String, quote: Character) -> Bool {
        guard value.count >= 2, value.last == quote else { return false }
        if quote == "\"" {
            var backslashes = 0
            for ch in value.dropLast().reversed() {
                if ch == "\\" { backslashes += 1 } else { break }
            }
            return backslashes % 2 == 0
        }
        return true
    }

    static func normalised(_ dateText: String) -> String {
        guard let date = SiteDate.parse(dateText) else { return dateText }
        return YAMLFormat.date(date)
    }
}

public struct ImageReference: Sendable, Hashable {
    public var alt: String
    public var path: String
    public var range: Range<String.Index>

    public init(alt: String, path: String, range: Range<String.Index>) {
        self.alt = alt
        self.path = path
        self.range = range
    }
}

public enum ContentChecks {
    /// The text with HTML comments and fenced code blanked out (same length, so ranges still line up),
    /// because examples there are not real links or images.
    public static func masked(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        for pattern in [#"(?s)<!--.*?-->"#, #"(?ms)^[ \t]*(```|~~~).*?^[ \t]*\1[ \t]*$"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in regex.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
                // One space per UTF-16 unit, so offsets in the original still apply.
                let units = Array(ns.substring(with: m.range).utf16).map { $0 == 10 ? UInt16(10) : UInt16(32) }
                ns.replaceCharacters(in: m.range, with: String(utf16CodeUnits: units, count: units.count))
            }
        }
        return ns as String
    }

    /// Images in Markdown and HTML, with Liquid `relative_url` wrappers reduced to the plain path.
    public static func images(in original: String) -> [ImageReference] {
        let body = masked(original)
        var refs: [ImageReference] = []
        let markdown = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(\s*(\{\{.*?\}\}|[^)\s]+)(?:\s+"[^"]*")?\s*\)"#)
        let ns = original as NSString
        for match in markdown?.matches(in: body, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let range = Range(match.range, in: original) else { continue }
            refs.append(ImageReference(alt: ns.substring(with: match.range(at: 1)), path: plainPath(ns.substring(with: match.range(at: 2))),
                                       range: range))
        }
        let html = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
        for match in html?.matches(in: body, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let range = Range(match.range, in: original) else { continue }
            let tag = ns.substring(with: match.range)
            let src = attribute("src", in: tag) ?? ""
            refs.append(ImageReference(alt: attribute("alt", in: tag) ?? "", path: plainPath(src), range: range))
        }
        return refs
    }

    public static func plainPath(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: #"\{\{\s*site\.(url|baseurl)\s*\}\}"#, with: "", options: .regularExpression)
        if t.hasPrefix("{{"), let quoteStart = t.firstIndex(where: { $0 == "'" || $0 == "\"" }) {
            let quote = t[quoteStart]
            let rest = t[t.index(after: quoteStart)...]
            if let end = rest.firstIndex(of: quote) { return String(rest[..<end]) }
        }
        return t
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let range = tag.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = String(tag[range])
        guard let open = match.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        return String(match[match.index(after: open)...].dropLast())
    }

    public static func wordCount(_ body: String) -> Int {
        Excerpt.make(body, limit: .max).split(whereSeparator: \.isWhitespace).count
    }
}

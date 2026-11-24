import Foundation
import InkwellMarkdown

enum LiquidFilters {
    static func apply(_ name: String, to input: LiquidValue, args: [LiquidValue], rawArgs _: [String], context: LiquidContext) -> LiquidValue {
        let site = context.site
        let arg0 = args.first ?? .null
        switch name {
        // Jekyll
        case "relative_url":
            return .string(joinURL(site["baseurl"].text, input.text))
        case "absolute_url":
            return .string(site["url"].text + joinURL(site["baseurl"].text, input.text))
        case "date":
            guard let date = input.asDate else { return input }
            return .string(LiquidDate.format(date, arg0.text, timeZone: context.timeZone))
        case "date_to_xmlschema":
            return input.asDate.map { .string(LiquidDate.xmlSchema($0, timeZone: context.timeZone)) } ?? input
        case "date_to_rfc822":
            return input.asDate.map { .string(LiquidDate.format($0, "%a, %d %b %Y %H:%M:%S %z", timeZone: context.timeZone)) } ?? input
        case "date_to_string":
            guard let date = input.asDate else { return input }
            if arg0.text == "ordinal" {
                let day = Calendar.current.component(.day, from: date)
                return .string(LiquidDate.ordinalDay(day) + LiquidDate.format(date, " %b %Y", timeZone: context.timeZone))
            }
            return .string(LiquidDate.format(date, "%d %b %Y", timeZone: context.timeZone))
        case "date_to_long_string":
            return input.asDate.map { .string(LiquidDate.format($0, "%d %B %Y", timeZone: context.timeZone)) } ?? input
        case "xml_escape", "escape", "escape_once":
            return .string(MarkdownRenderer.escape(input.text).replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;"))
        case "cgi_escape", "url_encode":
            return .string(input.text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.*")))?
                .replacingOccurrences(of: "%20", with: "+") ?? input.text)
        case "uri_escape", "url_escape":
            return .string(input.text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? input.text)
        case "markdownify":
            return .string(MarkdownRenderer().html(input.text))
        case "smartify":
            return .string(MarkdownRenderer().html(input.text).replacingOccurrences(of: "<p>", with: "").replacingOccurrences(of: "</p>\n", with: ""))
        case "slugify":
            return .string(input.text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-"))
        case "jsonify":
            return .string(json(input))
        case "number_of_words":
            return .int(input.text.split(whereSeparator: \.isWhitespace).count)
        case "array_to_sentence_string":
            let items = input.asArray.map(\.text)
            if items.count <= 2 { return .string(items.joined(separator: " and ")) }
            return .string(items.dropLast().joined(separator: ", ") + ", and " + (items.last ?? ""))
        case "where":
            let key = arg0.text
            let target = args.count > 1 ? args[1] : .null
            return .array(input.asArray.filter { item in
                let v = item[key]
                if case let .array(values) = v { return values.contains { LiquidValue.equal($0, target) } }
                return LiquidValue.equal(v, target) || v.text == target.text
            })
        case "where_exp":
            let variable = arg0.text
            let condition = Condition(args.count > 1 ? args[1].text : "true")
            return .array(input.asArray.filter { item in
                context.scopes.append([variable: item])
                defer { context.scopes.removeLast() }
                return context.test(condition)
            })
        case "group_by":
            var groups: [(String, [LiquidValue])] = []
            for item in input.asArray {
                let key = item[arg0.text].text
                if let i = groups.firstIndex(where: { $0.0 == key }) { groups[i].1.append(item) } else { groups.append((key, [item])) }
            }
            return .array(groups.map { .object(["name": .string($0.0), "items": .array($0.1), "size": .int($0.1.count)]) })
        case "sort":
            let key = args.isEmpty ? nil : arg0.text
            return .array(input.asArray.sorted { a, b in
                let x = key.map { a[$0] } ?? a, y = key.map { b[$0] } ?? b
                if case .null = x { return false }
                if case .null = y { return true }
                return LiquidValue.compare(x, y) == .orderedAscending
            })
        case "sort_natural":
            return .array(input.asArray.sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending })
        case "reverse":
            return .array(input.asArray.reversed())
        case "concat":
            return .array(input.asArray + arg0.asArray)
        case "push":
            return .array(input.asArray + [arg0])
        case "uniq":
            var seen: [LiquidValue] = []
            for item in input.asArray where !seen.contains(where: { LiquidValue.equal($0, item) }) { seen.append(item) }
            return .array(seen)
        case "map":
            return .array(input.asArray.map { $0[arg0.text] })
        case "compact":
            return .array(input.asArray.filter { if case .null = $0 { return false }; return true })
        case "first":
            return input.asArray.first ?? .null
        case "last":
            return input.asArray.last ?? .null
        case "join":
            return .string(input.asArray.map(\.text).joined(separator: args.isEmpty ? " " : arg0.text))
        case "split":
            return .array(input.text.components(separatedBy: arg0.text).map { .string($0) })
        case "size":
            switch input {
            case let .array(a): return .int(a.count)
            case let .object(o): return .int(o.count)
            default: return .int(input.text.count)
            }
        // Strings
        case "default":
            return input.isTruthy && !input.isEmpty ? input : arg0
        case "append": return .string(input.text + arg0.text)
        case "prepend": return .string(arg0.text + input.text)
        case "upcase": return .string(input.text.uppercased())
        case "downcase": return .string(input.text.lowercased())
        case "capitalize": return .string(input.text.prefix(1).uppercased() + input.text.dropFirst())
        case "strip": return .string(input.text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "lstrip": return .string(String(input.text.drop { $0.isWhitespace }))
        case "rstrip": return .string(String(input.text.reversed().drop { $0.isWhitespace }.reversed()))
        case "strip_html": return .string(MarkdownRenderer.stripTags(input.text))
        case "strip_newlines": return .string(input.text.replacingOccurrences(of: "\n", with: ""))
        case "newline_to_br": return .string(input.text.replacingOccurrences(of: "\n", with: "<br />\n"))
        case "remove": return .string(input.text.replacingOccurrences(of: arg0.text, with: ""))
        case "remove_first":
            guard let r = input.text.range(of: arg0.text) else { return input }
            var s = input.text
            s.removeSubrange(r)
            return .string(s)
        case "replace": return .string(input.text.replacingOccurrences(of: arg0.text, with: args.count > 1 ? args[1].text : ""))
        case "replace_first":
            guard let r = input.text.range(of: arg0.text) else { return input }
            return .string(input.text.replacingCharacters(in: r, with: args.count > 1 ? args[1].text : ""))
        case "slice":
            let start = Int(arg0.number ?? 0), length = Int(args.count > 1 ? args[1].number ?? 1 : 1)
            let chars = Array(input.text)
            let from = start < 0 ? max(0, chars.count + start) : min(start, chars.count)
            return .string(String(chars[from ..< min(chars.count, from + length)]))
        case "truncate":
            let limit = Int(arg0.number ?? 50)
            let ellipsis = args.count > 1 ? args[1].text : "..."
            let text = input.text
            guard text.count > limit else { return input }
            return .string(String(text.prefix(max(0, limit - ellipsis.count))) + ellipsis)
        case "truncatewords":
            let limit = Int(arg0.number ?? 15)
            let ellipsis = args.count > 1 ? args[1].text : "..."
            let words = input.text.split(whereSeparator: \.isWhitespace)
            guard words.count > limit else { return input }
            return .string(words.prefix(limit).joined(separator: " ") + ellipsis)
        // Numbers
        case "plus": return arith(input, arg0, +)
        case "minus": return arith(input, arg0, -)
        case "times": return arith(input, arg0, *)
        case "divided_by":
            guard let a = input.number, let b = arg0.number, b != 0 else { return .null }
            if case .int = arg0 { return .int(Int((a / b).rounded(.down))) }
            return .double(a / b)
        case "modulo":
            guard let a = input.number, let b = arg0.number, b != 0 else { return .null }
            return .int(Int(a) % Int(b))
        case "round":
            return .double((input.number ?? 0).rounded())
        case "floor": return .int(Int((input.number ?? 0).rounded(.down)))
        case "ceil": return .int(Int((input.number ?? 0).rounded(.up)))
        case "abs": return .double(abs(input.number ?? 0))
        case "inspect": return .string(json(input))
        default:
            return input
        }
    }

    static func joinURL(_ base: String, _ path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("//") { return path }
        let p = path.hasPrefix("/") ? path : "/" + path
        return base + p
    }

    static func arith(_ a: LiquidValue, _ b: LiquidValue, _ op: (Double, Double) -> Double) -> LiquidValue {
        let x = a.number ?? 0, y = b.number ?? 0
        let result = op(x, y)
        if case .double = a { return .double(result) }
        if case .double = b { return .double(result) }
        return .int(Int(result))
    }

    static func json(_ value: LiquidValue) -> String {
        switch value {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        case let .string(s):
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        case let .date(d): return "\"\(LiquidDate.xmlSchema(d))\""
        case let .array(items): return "[" + items.map(json).joined(separator: ",") + "]"
        case let .object(dict): return "{" + dict.keys.sorted().map { "\"\($0)\":\(json(dict[$0] ?? .null))" }.joined(separator: ",") + "}"
        }
    }
}

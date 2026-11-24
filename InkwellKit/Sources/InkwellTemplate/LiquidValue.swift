import Foundation
import InkwellCore

public indirect enum LiquidValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case date(Date)
    case array([LiquidValue])
    case object([String: LiquidValue])

    public init(_ yaml: YAMLValue) {
        switch yaml {
        case .null: self = .null
        case let .bool(b): self = .bool(b)
        case let .int(i): self = .int(i)
        case let .double(d): self = .double(d)
        case let .string(s): self = .string(s)
        case let .list(items): self = .array(items.map(LiquidValue.init))
        case let .map(entries):
            var dict: [String: LiquidValue] = [:]
            for entry in entries { dict[entry.key] = LiquidValue(entry.value) }
            self = .object(dict)
        }
    }

    public var isTruthy: Bool {
        switch self {
        case .null: false
        case let .bool(b): b
        default: true
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .null: true
        case let .string(s): s.isEmpty
        case let .array(a): a.isEmpty
        case let .object(o): o.isEmpty
        default: false
        }
    }

    public subscript(key: String) -> LiquidValue {
        switch self {
        case let .object(dict):
            if let v = dict[key] { return v }
            if key == "size" { return .int(dict.count) }
            return .null
        case let .array(items):
            switch key {
            case "size": return .int(items.count)
            case "first": return items.first ?? .null
            case "last": return items.last ?? .null
            default: return Int(key).flatMap { $0 >= 0 && $0 < items.count ? items[$0] : nil } ?? .null
            }
        case let .string(s):
            return key == "size" ? .int(s.count) : .null
        default:
            return .null
        }
    }

    public var text: String {
        switch self {
        case .null: ""
        case let .bool(b): b ? "true" : "false"
        case let .int(i): String(i)
        case let .double(d): d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : String(d)
        case let .string(s): s
        case let .date(d): LiquidDate.format(d, "%Y-%m-%d %H:%M:%S %z")
        case let .array(items): items.map(\.text).joined()
        case let .object(dict): "{" + dict.keys.sorted().map { "\"\($0)\"=>\(dict[$0]?.text ?? "")" }.joined(separator: ", ") + "}"
        }
    }

    var number: Double? {
        switch self {
        case let .int(i): Double(i)
        case let .double(d): d
        case let .string(s): Double(s)
        default: nil
        }
    }

    var asDate: Date? {
        switch self {
        case let .date(d): d
        case let .string(s): s == "now" || s == "today" ? Date() : SiteDate.parse(s)
        case let .int(i): Date(timeIntervalSince1970: TimeInterval(i))
        default: nil
        }
    }

    var asArray: [LiquidValue] {
        switch self {
        case let .array(a): a
        case .null: []
        case let .object(o): o.keys.sorted().map { .array([.string($0), o[$0] ?? .null]) }
        default: [self]
        }
    }

    static func equal(_ a: LiquidValue, _ b: LiquidValue) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case let (.bool(x), .bool(y)): x == y
        case let (.string(x), .string(y)): x == y
        case let (.date(x), .date(y)): x == y
        case let (.array(x), .array(y)): x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        default:
            if let x = a.number, let y = b.number, !(a.isString && b.isString) { x == y } else { false }
        }
    }

    var isString: Bool {
        if case .string = self { return true }
        return false
    }

    static func compare(_ a: LiquidValue, _ b: LiquidValue) -> ComparisonResult? {
        if let x = a.asDateStrict, let y = b.asDateStrict { return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
        if case let .string(x) = a, case let .string(y) = b { return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
        if let x = a.number, let y = b.number { return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
        return nil
    }

    var asDateStrict: Date? {
        if case let .date(d) = self { return d }
        return nil
    }
}

public enum LiquidDate {
    /// strftime as Ruby prints it, for the directives themes use.
    public static func format(_ date: Date, _ pattern: String, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let year = c.year ?? 0, month = c.month ?? 1, day = c.day ?? 1
        let hour = c.hour ?? 0, minute = c.minute ?? 0, second = c.second ?? 0, weekday = (c.weekday ?? 1) - 1
        let offset = timeZone.secondsFromGMT(for: date)
        let zone = String(format: "%@%02d%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
        var out = ""
        var chars = Array(pattern)[...]
        while let ch = chars.popFirst() {
            guard ch == "%", var directive = chars.popFirst() else {
                out.append(ch)
                continue
            }
            var unpadded = false
            if directive == "-", let next = chars.popFirst() {
                unpadded = true
                directive = next
            }
            func pad(_ n: Int, _ width: Int = 2) -> String { unpadded ? String(n) : String(format: "%0\(width)d", n) }
            switch directive {
            case "Y": out += String(year)
            case "y": out += pad(year % 100)
            case "m": out += pad(month)
            case "d": out += pad(day)
            case "e": out += unpadded ? String(day) : String(format: "%2d", day)
            case "j": out += pad(calendar.ordinality(of: .day, in: .year, for: date) ?? 1, 3)
            case "H": out += pad(hour)
            case "I": out += pad(hour % 12 == 0 ? 12 : hour % 12)
            case "l": out += String(format: "%2d", hour % 12 == 0 ? 12 : hour % 12)
            case "M": out += pad(minute)
            case "S": out += pad(second)
            case "p": out += hour < 12 ? "AM" : "PM"
            case "P": out += hour < 12 ? "am" : "pm"
            case "B": out += months[month - 1]
            case "b", "h": out += String(months[month - 1].prefix(3))
            case "A": out += days[weekday]
            case "a": out += String(days[weekday].prefix(3))
            case "z": out += zone
            case "Z": out += timeZone.abbreviation(for: date) ?? ""
            case "s": out += String(Int(date.timeIntervalSince1970))
            case "F": out += String(format: "%04d-%02d-%02d", year, month, day)
            case "T": out += String(format: "%02d:%02d:%02d", hour, minute, second)
            case "D": out += String(format: "%02d/%02d/%02d", month, day, year % 100)
            case "%": out += "%"
            default: out += "%" + String(directive)
            }
        }
        return out
    }

    public static func xmlSchema(_ date: Date, timeZone: TimeZone = .current) -> String {
        let s = format(date, "%Y-%m-%dT%H:%M:%S%z", timeZone: timeZone)
        return String(s.dropLast(2)) + ":" + s.suffix(2)
    }

    static func ordinalDay(_ day: Int) -> String {
        let suffix = switch day % 100 {
        case 11, 12, 13: "th"
        default:
            switch day % 10 {
            case 1: "st"
            case 2: "nd"
            case 3: "rd"
            default: "th"
            }
        }
        return "\(day)\(suffix)"
    }
}

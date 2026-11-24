import Foundation

/// A set of colours for an Inkwell theme, with light and dark values for each colour token.
public struct ColorPalette: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var light: [String: String]
    public var dark: [String: String]

    public init(id: String, name: String, light: [String: String], dark: [String: String]) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
    }

    /// The value of one token in one palette, for swatches.
    public func value(_ token: String, dark isDark: Bool = false) -> String? { (isDark ? dark : light)[token] }

    /// Whether the site's tokens already have these colours (light and dark).
    public func matches(_ tokens: DesignTokens) -> Bool {
        DesignPresets.colorTokens.allSatisfy { name in
            let entry = tokens.entries.first { $0.name == name }
            let sameLight = entry?.light?.uppercased() == light[name]?.uppercased()
            return sameLight && (entry?.dark == nil || entry?.dark?.uppercased() == dark[name]?.uppercased())
        }
    }
}

/// A named font stack made only of fonts that are already on readers' devices.
public struct FontStack: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var value: String

    /// The first family in the stack, for showing the name in its own font.
    public var primaryFamily: String {
        value.components(separatedBy: ",")[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
}

/// A heading font with a body font that goes with it.
public struct FontPairing: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var heading: FontStack
    public var body: FontStack

    public func matches(_ tokens: DesignTokens) -> Bool {
        func value(_ name: String) -> String? { tokens.entries.first { $0.name == name }?.light }
        return DesignPresets.sameStack(value("--font-heading"), heading.value) && DesignPresets.sameStack(value("--font-body"), body.value)
    }
}

/// One-click starting points for the Design panel. They set the same tokens as the colour wells and font menus.
public enum DesignPresets {
    public static let colorTokens = ["--bg", "--surface", "--text", "--muted", "--accent", "--border"]

    /// Palettes for a theme: its own colours first, then the palettes of its family.
    public static func palettes(for theme: ThemeManifest) -> [ColorPalette] {
        var own = ColorPalette(id: "original", name: localized("Original"), light: [:], dark: [:])
        for token in theme.tokens where colorTokens.contains(token.name) {
            own.light[token.name] = token.light
            own.dark[token.name] = token.dark ?? token.light
        }
        let family = themeFamilies[theme.id] ?? "clean"
        return [own] + (paletteData[family] ?? []).map { entry in
            func split(_ text: String) -> [String: String] {
                Dictionary(uniqueKeysWithValues: zip(colorTokens, text.split(separator: " ").map(String.init)))
            }
            return ColorPalette(id: entry.id, name: entry.name, light: split(entry.light), dark: split(entry.dark))
        }
    }

    public static let fontStacks: [FontStack] = [
        FontStack(id: "system", name: localized("System sans-serif"),
                  value: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", Inter, Roboto, sans-serif"),
        FontStack(id: "charter", name: localized("Charter serif"),
                  value: "Charter, \"Iowan Old Style\", \"Palatino Linotype\", Georgia, serif"),
        FontStack(id: "georgia", name: "Georgia", value: "Georgia, \"Times New Roman\", serif"),
        FontStack(id: "display", name: localized("Display serif"), value: "ui-serif, \"New York\", \"Iowan Old Style\", Georgia, serif"),
        FontStack(id: "palatino", name: "Palatino", value: "Palatino, \"Palatino Linotype\", \"Book Antiqua\", Georgia, serif"),
        FontStack(id: "avenir", name: "Avenir", value: "Avenir, \"Avenir Next\", Montserrat, \"Segoe UI\", sans-serif"),
        FontStack(id: "gill", name: "Gill Sans", value: "\"Gill Sans\", \"Gill Sans MT\", Calibri, sans-serif"),
        FontStack(id: "optima", name: "Optima", value: "Optima, Candara, \"Noto Sans\", sans-serif"),
        FontStack(id: "futura", name: "Futura", value: "Futura, \"Century Gothic\", \"Trebuchet MS\", sans-serif"),
        FontStack(id: "rounded", name: localized("Rounded"),
                  value: "ui-rounded, \"SF Pro Rounded\", \"Hiragino Maru Gothic ProN\", sans-serif"),
        FontStack(id: "mono", name: localized("Monospace"), value: "ui-monospace, \"SF Mono\", Menlo, Consolas, monospace"),
    ]

    public static func stack(_ id: String) -> FontStack { fontStacks.first { $0.id == id }! }

    public static let fontPairings: [FontPairing] = [
        FontPairing(id: "classic", name: localized("Classic serif"), heading: stack("charter"), body: stack("charter")),
        FontPairing(id: "modern", name: localized("Modern sans"), heading: stack("system"), body: stack("system")),
        FontPairing(id: "editorial", name: localized("Editorial"), heading: stack("display"), body: stack("system")),
        FontPairing(id: "humanist", name: localized("Humanist"), heading: stack("gill"), body: stack("charter")),
        FontPairing(id: "bookish", name: localized("Old style"), heading: stack("palatino"), body: stack("palatino")),
        FontPairing(id: "geometric", name: localized("Geometric"), heading: stack("futura"), body: stack("avenir")),
        FontPairing(id: "rounded", name: localized("Rounded"), heading: stack("rounded"), body: stack("system")),
        FontPairing(id: "mono", name: localized("Mono"), heading: stack("mono"), body: stack("mono")),
    ]

    /// The named stack a token value is, if any (spacing and quote style do not matter).
    public static func fontStack(matching value: String?) -> FontStack? {
        fontStacks.first { sameStack($0.value, value) }
    }

    static func sameStack(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        func normalize(_ s: String) -> String {
            s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "\"").lowercased()
        }
        return normalize(a) == normalize(b)
    }

    /// WCAG contrast ratio between two hex colours, 1 to 21.
    public static func contrast(_ a: String, _ b: String) -> Double? {
        guard let la = DesignTokens.luminance(a), let lb = DesignTokens.luminance(b) else { return nil }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

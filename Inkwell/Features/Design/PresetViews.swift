import AppKit
import InkwellKit
import SwiftUI

/// One-click colour palettes for the site's theme, each shown as its light and dark colours.
struct PaletteGrid: View {
    var design: DesignModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(design.palettes) { palette in
                let current = design.isCurrent(palette)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        PaletteSwatch(palette: palette, dark: false)
                        if design.secondScheme == .dark { PaletteSwatch(palette: palette, dark: true) }
                    }
                    .frame(height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(current ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                            lineWidth: current ? 2 : 0.5))
                    Text(palette.name).font(.caption).foregroundStyle(current ? .primary : .secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
                .choosable(palette.name, selected: current) { design.apply(palette) }
                .help(String(localized: "Use the \(palette.name) colours"))
            }
        }
        .padding(.vertical, 2)
    }
}

/// A palette in miniature: its background with lines of text, secondary text and accent.
struct PaletteSwatch: View {
    var palette: ColorPalette
    var dark: Bool

    func color(_ token: String) -> Color { Color(hex: palette.value(token, dark: dark) ?? "#888888") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(color("--text")).frame(width: 26, height: 4)
            Capsule().fill(color("--muted")).frame(width: 34, height: 3)
            HStack(spacing: 3) {
                Circle().fill(color("--accent")).frame(width: 9, height: 9)
                RoundedRectangle(cornerRadius: 2).fill(color("--surface")).frame(width: 14, height: 8)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color("--border"), lineWidth: 1))
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(color("--bg"))
    }
}

/// One-click font pairings, each shown in its own heading and body fonts.
struct FontPairingGrid: View {
    var design: DesignModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(DesignPresets.fontPairings) { pairing in
                let current = design.isCurrent(pairing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Aa").font(.stack(pairing.heading.value, size: 22, weight: .semibold))
                    Text(pairing.name).font(.stack(pairing.body.value, size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(current ? Color.accentColor : Color(nsColor: .separatorColor),
                                                                        lineWidth: current ? 2 : 0.5))
                .contentShape(Rectangle())
                .choosable(pairing.name, selected: current) { design.apply(pairing) }
                .help(String(localized: "Headings in \(pairing.heading.name), text in \(pairing.body.name)"))
            }
        }
        .padding(.vertical, 2)
    }
}

/// A theme option that is a picture in the site (such as the portfolio's profile picture).
struct ImageOptionRow: View {
    var design: DesignModel
    var option: ThemeManifest.OptionSpec

    var path: String { design.string("inkwell.\(option.key)") }

    var file: URL? {
        guard !path.isEmpty else { return nil }
        let url = design.root.appending(path: String(path.drop { $0 == "/" }))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        LabeledContent(option.label) {
            HStack {
                if let file, let image = NSImage(contentsOf: file) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: 26, height: 26).clipShape(Circle())
                        .accessibilityHidden(true)
                } else {
                    Text("None").font(.caption).foregroundStyle(.secondary)
                }
                Button("Choose…", action: choose)
                if !path.isEmpty {
                    Button("Remove") { design.setRaw("inkwell.\(option.key)", nil) }
                }
            }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a picture of you or your work. A square picture works best.")
        guard panel.runModal() == .OK, let url = panel.url, let path = design.importImage(url, slug: option.key) else { return }
        design.setString("inkwell.\(option.key)", path)
    }
}

extension Font {
    /// The first font of a CSS font stack, with the system's own designs for the `ui-` names and the system font.
    static func stack(_ stack: String, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let first = stack.components(separatedBy: ",")[0].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        switch first {
        case "ui-rounded": return .system(size: size, weight: weight, design: .rounded)
        case "ui-serif": return .system(size: size, weight: weight, design: .serif)
        case "ui-monospace": return .system(size: size, weight: weight, design: .monospaced)
        case "-apple-system", "system-ui", "BlinkMacSystemFont", "ui-sans-serif": return .system(size: size, weight: weight)
        default: return .custom(first, size: size).weight(weight)
        }
    }
}

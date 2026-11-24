import InkwellKit
import SwiftUI

struct DesignPanel: View {
    @Bindable var design: DesignModel
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(design.theme?.name ?? themeName).font(.headline)
                        Text(design.theme?.summary ?? (design.tokens == nil
                                ? "This theme has no design settings Inkwell can find. Pick one of Inkwell’s themes to edit colours and fonts here."
                                : design.tokens?.sassTemplate != nil
                                ? "Its Sass settings; your changes go in \(design.tokens?.lightFile ?? "assets/main.scss")."
                                : "Settings found in \(design.tokens?.lightFile ?? "your stylesheet")."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Change Theme…") { model.showThemeGallery = true }
                }
            } header: {
                Text("Theme")
            }

            ForEach(design.groups, id: \.0) { group, entries in
                Section {
                    ForEach(entries) { entry in
                        TokenRow(design: design, entry: entry)
                    }
                } header: {
                    Text(group)
                } footer: {
                    if group == "Colours", design.secondScheme == nil, design.tokens?.supportsColorSchemes == true {
                        HStack {
                            Text(design.defaultIsDark ? "Your site is dark for every reader." : "Readers in dark mode see these colours too.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(design.defaultIsDark ? "Add Light Mode" : "Add Dark Mode") { design.addSecondPalette() }
                                .controlSize(.small)
                                .help(design.defaultIsDark ? "Add colours for readers whose system is in light mode"
                                    : "Add colours for readers whose system is in dark mode")
                        }
                    }
                }
            }

            if let theme = design.theme {
                Section("Options") {
                    ForEach(theme.options, id: \.key) { option in
                        OptionRow(design: design, option: option)
                    }
                }
            }

            Section {
                Button("Review and Publish Design Changes…") { model.showChanges = true }
                    .disabled(model.pendingChanges == 0)
            } footer: {
                Text("Changes are saved to your site’s files as you make them and go live when you publish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Design")
        .sheet(isPresented: $model.showThemeGallery) { ThemeGallery(design: design) }
    }
}

extension DesignPanel {
    var themeName: String {
        if let reference = model.site.flatMap({ ThemeReference.of($0.config) }) { return reference.repository.capitalized + " theme" }
        return "Your own theme"
    }
}

struct TokenRow: View {
    var design: DesignModel
    var entry: DesignTokens.Entry

    var body: some View {
        switch entry.kind {
        case .color:
            LabeledContent(entry.label) {
                HStack(spacing: 14) {
                    switch design.secondScheme {
                    case .dark?:
                        colorWell(entry.light, scheme: .light, help: "Light")
                        colorWell(entry.dark ?? entry.light, scheme: .dark, help: "Dark")
                    case .lightMode?:
                        colorWell(entry.light, scheme: .light, help: "Dark")
                        colorWell(entry.lightMode ?? entry.light, scheme: .lightMode, help: "Light")
                    default:
                        colorWell(entry.light, scheme: .light, help: "Colour")
                    }
                }
            }
        case .font:
            FontRow(design: design, entry: entry)
        case .length, .number:
            LengthRow(design: design, entry: entry)
        case .other:
            LabeledContent(entry.label) {
                CommitField(value: entry.light ?? "") { design.setToken(entry.name, $0, scheme: .light) }
                    .frame(width: 200)
            }
        }
    }

    @ViewBuilder
    func colorWell(_ value: String?, scheme: ColorSchemeKind, help: String) -> some View {
        if let value, value.hasPrefix("#") {
            VStack(spacing: 2) {
                ColorPicker(help, selection: Binding(get: { Color(hex: value) }, set: { design.scheduleToken(entry.name, $0.hexString, scheme: scheme) }),
                            supportsOpacity: false)
                    .labelsHidden()
                Text(help).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .help("\(help): \(value)")
        } else {
            CommitField(value: value ?? "") { design.setToken(entry.name, $0, scheme: scheme) }
                .frame(width: 110)
                .help(help)
        }
    }
}

struct FontRow: View {
    var design: DesignModel
    var entry: DesignTokens.Entry

    static let stacks: [(String, String)] = [
        ("System sans-serif", "-apple-system, BlinkMacSystemFont, \"Segoe UI\", Inter, Roboto, sans-serif"),
        ("Charter serif", "Charter, \"Iowan Old Style\", \"Palatino Linotype\", Georgia, serif"),
        ("Georgia", "Georgia, \"Times New Roman\", serif"),
        ("Avenir", "Avenir, \"Avenir Next\", Montserrat, \"Segoe UI\", sans-serif"),
        ("Gill Sans", "\"Gill Sans\", \"Gill Sans MT\", Calibri, sans-serif"),
        ("Rounded", "ui-rounded, \"SF Pro Rounded\", \"Hiragino Maru Gothic ProN\", sans-serif"),
        ("Monospace", "ui-monospace, \"SF Mono\", Menlo, Consolas, monospace"),
    ]

    var current: String { entry.light ?? "" }
    var match: String? { Self.stacks.first { normalize($0.1) == normalize(current) }?.1 }

    func normalize(_ s: String) -> String { s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "\"").lowercased() }

    var body: some View {
        LabeledContent(entry.label) {
            VStack(alignment: .trailing, spacing: 6) {
                let choice = Binding(get: { match ?? "custom" }, set: { (value: String) in
                    if value != "custom" { design.setToken(entry.name, value, scheme: .light) }
                })
                Picker(entry.label, selection: choice) {
                    ForEach(Self.stacks, id: \.1) { name, stack in
                        Text(name).font(.custom(stack.components(separatedBy: ",")[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), size: 13))
                            .tag(stack)
                    }
                    Text("Custom").tag("custom")
                }
                .labelsHidden()
                .fixedSize()
                if match == nil {
                    CommitField(value: current) { design.setToken(entry.name, $0, scheme: .light) }
                        .frame(width: 180)
                        .font(.caption.monospaced())
                }
            }
        }
    }
}

struct LengthRow: View {
    var design: DesignModel
    var entry: DesignTokens.Entry

    var parsed: (Double, String)? {
        guard let value = entry.light?.trimmingCharacters(in: .whitespaces),
              let match = value.range(of: #"^-?[\d.]+"#, options: .regularExpression), let number = Double(value[match]) else { return nil }
        return (number, String(value[match.upperBound...]))
    }

    /// A range around the current value, so 4px corners and 800px widths both get a useful slider.
    var range: ClosedRange<Double> {
        guard let (value, unit) = parsed else { return 0 ... 100 }
        switch unit {
        case "": return value <= 3 ? 1 ... 2.5 : 0 ... max(value * 2, 10)
        case "%": return 0 ... 100
        default: return 0 ... max(value * 2.5, value + 10)
        }
    }

    var step: Double { parsed.map { $0.1 == "" && $0.0 <= 3 } == true ? 0.05 : 1 }

    var body: some View {
        LabeledContent(entry.label) {
            if let (number, unit) = parsed {
                HStack {
                    Slider(value: Binding(get: { number }, set: { value in
                        let text = step < 1 ? String(format: "%.2f", value) : String(Int(value.rounded()))
                        design.scheduleToken(entry.name, text + unit, scheme: .light)
                    }), in: range, step: step)
                        .frame(width: 120)
                    Text(entry.light ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                }
            } else {
                CommitField(value: entry.light ?? "") { design.setToken(entry.name, $0, scheme: .light) }.frame(width: 150)
            }
        }
    }
}

struct OptionRow: View {
    var design: DesignModel
    var option: ThemeManifest.OptionSpec

    func label(for value: String) -> String {
        switch (option.key, value) {
        case ("home_style", "list"): "List of titles"
        case ("home_style", "cards"): "Cards with pictures"
        case ("home_style", "chain"): "Full posts, one after another"
        case ("appearance", "auto"): "Follow the reader’s system"
        case ("appearance", "light"): "Always light"
        case ("appearance", "dark"): "Always dark"
        case ("date_format", _): LiquidDate.format(Date(), value)
        default: value
        }
    }

    var body: some View {
        switch option.kind {
        case "bool":
            Toggle(option.label, isOn: Binding(get: {
                if case let .flag(b)? = design.option(option.key) { return b }
                return false
            }, set: { design.setOption(option.key, .flag($0)) }))
        default:
            Picker(option.label, selection: Binding(get: {
                if case let .text(s)? = design.option(option.key) { return s }
                return option.values?.first ?? ""
            }, set: { design.setOption(option.key, .text($0)) })) {
                ForEach(option.values ?? [], id: \.self) { value in
                    Text(label(for: value)).tag(value)
                }
            }
        }
    }
}

/// A text field that saves when Return is pressed or focus leaves, not on every keystroke.
struct CommitField: View {
    var placeholder = ""
    var value: String
    var commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: placeholder.isEmpty ? nil : Text(placeholder))
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onSubmit { if text != value { commit(text) } }
            .onChange(of: focused) { if !focused, text != value { commit(text) } }
    }
}

// MARK: Theme gallery

struct ThemeGallery: View {
    var design: DesignModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: ThemeManifest?
    @State private var plan: AdoptionPlan?
    @State private var expanded: String?
    let themes = ThemeManifest.bundled()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plan == nil ? "Choose a theme" : plan?.title ?? "").font(.title2.weight(.semibold))
            if let plan {
                review(plan)
            } else {
                Text("Themes change how every page looks. Your posts and pages stay exactly as they are.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(themes) { theme in
                        ThemeCard(theme: theme, selected: theme.id == (chosen?.id ?? design.theme?.id))
                            .onTapGesture { chosen = theme }
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Continue") {
                        if let chosen { plan = design.plan(for: chosen) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen == nil || chosen?.id == design.theme?.id)
                }
            }
        }
        .padding(24)
        .frame(width: 720)
    }

    func review(_ plan: AdoptionPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(design.isInkwellTheme
                ? "Inkwell updates these files. Nothing goes live until you publish."
                : "Your current layouts with the same names are replaced; anything else in your site is left alone. Nothing goes live until you publish.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.changes) { change in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(change.kind).font(.caption.weight(.semibold))
                                    .foregroundStyle(change.oldText == nil ? .green : .orange)
                                    .frame(width: 54, alignment: .leading)
                                Text(change.path).font(.callout.monospaced())
                                Spacer()
                                Button(expanded == change.path ? "Hide" : "Show") {
                                    expanded = expanded == change.path ? nil : change.path
                                }
                                .buttonStyle(.link)
                            }
                            Text(change.reason).font(.caption).foregroundStyle(.secondary).padding(.leading, 62)
                            if expanded == change.path {
                                Text(change.newText ?? "")
                                    .font(.caption.monospaced())
                                    .lineLimit(40)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 340)
            HStack {
                Button("Back") { self.plan = nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Theme") {
                    design.apply(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: Preview while designing

struct DesignPreview: View {
    var design: DesignModel
    @Bindable var model: AppModel
    @State private var resources: SiteResources?
    @State private var token = 0
    @State private var rebuildTask: Task<Void, Never>?

    var choices: [(String, String)] {
        var list = design.previewChoices
        if !list.contains(where: { $0.1 == design.previewPage }) { list.insert((design.previewPage, design.previewPage), at: 0) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Page", selection: Binding(get: { design.previewPage }, set: { design.previewPage = $0 })) {
                    ForEach(choices, id: \.1) { title, url in Text(title).tag(url) }
                }
                .frame(maxWidth: 260)
                Picker("Width", selection: $model.previewWidth) {
                    Label("Desktop", systemImage: "desktopcomputer").tag(AppModel.PreviewWidth.desktop)
                    Label("Phone", systemImage: "iphone").tag(AppModel.PreviewWidth.phone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Appearance", selection: $model.previewAppearance) {
                    Image(systemName: "circle.lefthalf.filled").help("Follow this Mac").tag(AppModel.PreviewAppearance.system)
                    Image(systemName: "sun.max").help("Light mode").tag(AppModel.PreviewAppearance.light)
                    Image(systemName: "moon").help("Dark mode").tag(AppModel.PreviewAppearance.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let status = model.themeStatus {
                    Label(status, systemImage: "arrow.down.circle").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            GeometryReader { geo in
                HStack {
                    Spacer(minLength: 0)
                    if let resources {
                        SitePreview(address: design.previewPage, root: design.root, baseurl: model.site?.config.baseurl ?? "",
                                    resources: resources, reloadToken: token, appearance: model.previewAppearance,
                                    onNavigate: { path in if design.previewPage != path { design.previewPage = path } })
                            .frame(width: model.previewWidth == .phone ? min(390, geo.size.width) : geo.size.width)
                            .clipShape(RoundedRectangle(cornerRadius: model.previewWidth == .phone ? 18 : 0))
                            .padding(.vertical, model.previewWidth == .phone ? 12 : 0)
                    } else {
                        ProgressView()
                    }
                    Spacer(minLength: 0)
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .onAppear(perform: rebuild)
        .onChange(of: design.revision) { rebuild() }
        .onChange(of: model.themeRoot) { rebuild() }
    }

    func rebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            resources = design.makeResources()
            token += 1
        }
    }
}

extension Color {
    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

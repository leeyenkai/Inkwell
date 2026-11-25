import InkwellKit
import SwiftUI

extension AppModel {
    /// The site's menu is written into its pages (or an include) rather than read from `_data/navigation.yml`.
    var usesHTMLMenu: Bool {
        guard let site else { return false }
        if site.kind == .handBuilt { return true }
        return site.kind == .website && design?.hasNavigationFile == false && site.documents.contains(where: \.isHTMLPage)
    }
}

/// The menu of a hand-built site, read from one page and changed on every page whose menu leads to the same places
/// (SPEC §4.12, W4 step 2). Only the items that change are rewritten.
struct HTMLMenuEditor: View {
    var model: AppModel
    @State private var sourcePath: String?
    @State private var menu: HTMLMenu?
    @State private var entries: [HTMLMenu.Entry] = []
    @State private var same: [AppModel.MenuSource] = []
    @State private var different: [AppModel.MenuSource] = []
    @State private var selection: Int?

    var sources: [AppModel.MenuSource] { model.menuSources }
    var source: AppModel.MenuSource? { sources.first { $0.path == sourcePath } }

    var body: some View {
        Form {
            Section {
                Picker("Menu on", selection: $sourcePath) {
                    ForEach(sources, id: \.path) { source in
                        Text(verbatim: "\(source.title) (\(source.path))").tag(Optional(source.path))
                    }
                }
            } footer: {
                if menu != nil {
                    Text(same.isEmpty ? "Changes are made on this page only. No other page has the same menu."
                        : "Changes are made on this page and on \(same.count) other pages with the same menu.")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(same.map(\.path).joined(separator: ", "))
                }
            }
            if menu == nil {
                Section {
                    Text("This page has no menu Inkwell can edit: no <nav> with links, or one with submenus. Edit it in the page’s source.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section {
                    List(selection: $selection) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            row(index, entry).tag(index)
                        }
                        .onMove { from, to in
                            entries.move(fromOffsets: from, toOffset: to)
                            save()
                        }
                    }
                    .frame(minHeight: 220)
                } header: {
                    Text("Menu")
                } footer: {
                    Text("Drag to reorder. A link whose words hold other tags, such as an icon, keeps its words; change them in the source.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Add") {
                    Menu("Add a Page") {
                        ForEach(addable, id: \.address) { item in
                            Button {
                                entries.append(HTMLMenu.Entry(title: item.title, address: item.address))
                                save()
                            } label: {
                                Text(verbatim: "\(item.title) (\(item.address))")
                            }
                        }
                    }
                    .disabled(addable.isEmpty)
                    Button("Add a Link…") {
                        entries.append(HTMLMenu.Entry(title: String(localized: "Link"), address: "https://"))
                        save()
                    }
                }
                if !different.isEmpty {
                    Section {
                        Text("\(different.count) pages have a different menu and are left alone.")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(different.map(\.path).joined(separator: ", "))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Navigation")
        .onAppear {
            if sourcePath == nil { sourcePath = (sources.first { $0.path == "index.html" } ?? sources.first)?.path }
            load()
        }
        .onChange(of: sourcePath) { load() }
    }

    func row(_ index: Int, _ entry: HTMLMenu.Entry) -> some View {
        let editable = entry.source.flatMap { menu?.items[$0].titleEditable } ?? true
        return HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            if editable {
                CommitField(placeholder: String(localized: "Title"), value: entry.title) { entries[index].title = $0; save() }
                    .frame(width: 130)
            } else {
                Text(entry.title).lineLimit(1).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    .help("The words of this link hold other tags; change them in the source.")
            }
            CommitField(placeholder: String(localized: "about.html"), value: entry.address) { entries[index].address = $0; save() }
                .frame(minWidth: 150, maxWidth: .infinity)
            Button {
                entries.remove(at: index)
                save()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from the menu")
        }
    }

    /// The site's pages that are not in the menu yet, with addresses written from this page.
    var addable: [(title: String, address: String)] {
        guard let source, let site = model.site else { return [] }
        let present = Set((menu?.targets(onPage: source.linksFrom) ?? []))
        return site.documents.filter(\.editsAsHTML).sorted { $0.relativePath < $1.relativePath }.compactMap { doc in
            let address = SitePath.relative(to: doc.relativePath, from: source.linksFrom)
            let target = HTMLMenu.target(address, from: source.linksFrom)
            return present.contains(target) ? nil : (doc.title, address)
        }
    }

    func load() {
        model.editor?.saveNow()
        guard let source, let text = model.currentText(of: source.path), let found = HTMLMenu.find(in: text) else {
            menu = nil
            entries = []
            same = []
            different = []
            return
        }
        menu = found
        entries = found.entries
        (same, different) = model.menuMatches(for: source, menu: found)
    }

    func save() {
        guard let source, let menu else { return }
        model.applyMenu(entries, from: menu, on: source, and: same)
        load()
    }
}

/// Moving a hand-built site to Jekyll (SPEC §4.12, W4 step 3): what would change, for the person to agree to first.
struct MoveToJekyllSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: JekyllAdoption.Plan?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move to Jekyll").font(.title2.weight(.semibold))
            Text("""
                GitHub would build this site with Jekyll instead of serving its files as they are. A header, menu or footer that \
                several pages copy moves into one file, so a change to it reaches every page. The HTML pages look the same as before.
                """)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let plan {
                if plan.isWorthDoing {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.shared, id: \.path) { file in
                            bullet("square.on.square", "The \(file.part.title) of \(file.pages.count) pages moves to \(file.path).")
                        }
                        let changed = plan.changedPages.count
                        bullet("doc.text",
                               "\(changed) pages start with a few lines Jekyll reads (layout: null), so it builds them as they are.")
                        if plan.removals.contains(".nojekyll") {
                            bullet("minus.circle", "The .nojekyll file is removed.")
                        }
                        if !plan.keptNames.isEmpty {
                            bullet("eye", "_config.yml lists files Jekyll would otherwise leave out: \(plan.keptNames.joined(separator: ", ")).")
                        }
                        if !plan.notKept.isEmpty {
                            let names = plan.notKept.joined(separator: ", ")
                            bullet("exclamationmark.triangle",
                                   "Jekyll stops serving \(names) unless you add them to the include list in _config.yml yourself.")
                        }
                        if !plan.markdownShown.isEmpty {
                            let names = plan.markdownShown.joined(separator: ", ")
                            bullet("exclamationmark.triangle", "These Markdown files become web pages instead of plain text: \(names).")
                        }
                        if !plan.leftAlone.isEmpty {
                            let count = plan.leftAlone.count
                            bullet("hand.raised",
                                   "\(count) pages contain text Jekyll would read as its own tags, so they are left exactly as they are.")
                        }
                    }
                    .font(.callout)
                    Text("Nothing is published yet. You review every change, then publish them together.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("No header, menu or footer is the same on two pages, so there is nothing to share. The site stays as it is.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move to Jekyll") {
                    if let plan { model.adoptJekyll(plan) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan?.isWorthDoing != true)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { plan = model.jekyllAdoptionPlan() }
    }

    func bullet(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol).foregroundStyle(Color.accentColor) }
    }
}

/// The kind of site Inkwell treats this one as, for when it guessed wrong (SPEC §4.12).
struct SiteKindPicker: View {
    var model: AppModel

    var body: some View {
        Picker("Treat as", selection: Binding(get: { model.chosenKind }, set: { model.chooseKind($0) })) {
            if let detected = model.site?.detectedKind {
                Text("As Found (\(detected.title))").tag(SiteKind?.none)
            }
            Divider()
            ForEach(SiteKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(Optional(kind))
                    // GitHub serves these files as they are: a Jekyll kind would write front matter readers then see.
                    .disabled(!kind.servesFilesAsIs && model.site?.filesServedAsIs == true)
            }
        }
        .help(model.site?.filesServedAsIs == true
            ? String(localized: "GitHub serves this site's files as they are, so it can only be treated as a website of plain files.")
            : String(localized: "If Inkwell guessed wrong, choose what this site is."))
    }
}

extension SiteKind {
    var title: String {
        switch self {
        case .blog: String(localized: "Blog")
        case .website: String(localized: "Website on Jekyll")
        case .handBuilt: String(localized: "Hand-built website")
        case .generated: String(localized: "Built by another program")
        }
    }
}

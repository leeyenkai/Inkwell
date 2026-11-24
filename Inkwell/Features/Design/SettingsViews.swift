import InkwellKit
import SwiftUI
import UniformTypeIdentifiers

struct NavigationEditor: View {
    var design: DesignModel
    var model: AppModel
    @State private var entries: [NavigationEntry] = []
    @State private var selection: Int?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            CommitField(placeholder: String(localized: "Title"), value: entry.title) { entries[index].title = $0; save() }
                                .frame(width: 160)
                            CommitField(placeholder: String(localized: "/address"), value: entry.url) { entries[index].url = $0; save() }
                            Button {
                                entries.remove(at: index)
                                save()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove from the menu")
                        }
                        .tag(index)
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
                Text("Drag to reorder. The menu appears at the top of every page, in this order.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add") {
                Menu("Add a Page or Section") {
                    ForEach(addable, id: \.url) { item in
                        Button(item.title) {
                            entries.append(item)
                            save()
                        }
                    }
                }
                Button("Add a Link…") {
                    entries.append(NavigationEntry(title: "Link", url: "https://"))
                    save()
                }
            }
            if !design.hasNavigationFile {
                Section {
                    Text("This site has no menu file yet. Saving here creates _data/navigation.yml; your theme’s layout has to read it (Inkwell’s themes do).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Navigation")
        .onAppear { entries = design.navigation.entries }
        .onChange(of: design.revision) { entries = design.navigation.entries }
    }

    /// Sections and pages that are not in the menu yet.
    var addable: [NavigationEntry] {
        guard let site = model.site else { return [] }
        let present = Set(entries.map(\.url))
        var items: [NavigationEntry] = []
        for section in site.sections {
            switch section.kind {
            case let .collection(name):
                let url = "/\(name)"
                if !present.contains(url) { items.append(NavigationEntry(title: section.label, url: url)) }
            case .page, .pages:
                for doc in site.documents(in: section.id) {
                    let url = doc.url.hasSuffix(".html") ? String(doc.url.dropLast(5)) : doc.url
                    if !present.contains(url), !present.contains(doc.url) { items.append(NavigationEntry(title: doc.title, url: url)) }
                }
            }
        }
        return items
    }

    func save() {
        design.saveNavigation(entries)
    }
}

struct SiteSettingsView: View {
    var design: DesignModel
    var model: AppModel
    @State private var faviconText = ""

    var body: some View {
        Form {
            Section("Site") {
                field("Title", "title")
                field("Description", "description",
                      prompt: String(localized: "One sentence about the site, for search results and link previews"))
                field("Author", "author")
                field("Language", "lang", prompt: "en")
                Picker("Time zone", selection: Binding(get: { design.string("timezone").isEmpty ? TimeZone.current.identifier : design.string("timezone") },
                                                       set: { design.setRaw("timezone", $0) })) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
            }

            if design.isInkwellTheme {
                Section("Look") {
                    field("Footer", "inkwell.footer", prompt: String(localized: "Shown after the copyright line"))
                    LabeledContent("Share image") {
                        HStack {
                            let image = design.string("inkwell.social_image")
                            Text(image.isEmpty ? String(localized: "None") : image)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Button("Choose…") { chooseShareImage() }
                        }
                    }
                    LabeledContent("Favicon") {
                        HStack {
                            if let url = favicon {
                                Image(nsImage: NSImage(contentsOf: url) ?? NSImage()).resizable().frame(width: 22, height: 22)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            TextField("", text: $faviconText, prompt: Text("A letter or emoji")).labelsHidden().frame(width: 130).textFieldStyle(.roundedBorder)
                            Button("Make") { makeFavicon() }.disabled(faviconText.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }

            Section("Address") {
                LabeledContent("Site address") { Text(design.string("url") + design.string("baseurl")).font(.callout.monospaced()).textSelection(.enabled) }
                if let backend = model.backend as? GitHubBackend, let client = backend.client {
                    CustomDomainSection(owner: backend.copy.ref.owner, repository: backend.copy.ref.name, client: client, model: model)
                } else {
                    Text("Custom domains are set on GitHub for sites opened from a local folder.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    var favicon: URL? {
        let path = design.string("inkwell.favicon")
        guard !path.isEmpty else { return nil }
        let url = design.root.appending(path: String(path.drop { $0 == "/" }))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func field(_ label: LocalizedStringKey, _ path: String, prompt: String = "") -> some View {
        LabeledContent(label) {
            CommitField(placeholder: prompt, value: design.string(path)) { design.setString(path, $0) }
                .frame(minWidth: 260)
        }
    }

    func chooseShareImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose the picture shown when your site is shared. A wide image (1200 × 630) works best.")
        guard panel.runModal() == .OK, let url = panel.url, let path = design.importImage(url, slug: "share") else { return }
        design.setString("inkwell.social_image", path)
    }

    func makeFavicon() {
        let accent = design.token("--accent")?.light.map(Color.init(hex:)).map(NSColor.init) ?? .systemIndigo
        guard let path = design.makeFavicon(text: String(faviconText.trimmingCharacters(in: .whitespaces).prefix(2)), background: accent) else { return }
        design.setString("inkwell.favicon", path)
    }
}

/// Points a domain you own at the site, through GitHub's Pages settings.
struct CustomDomainSection: View {
    var owner: String
    var repository: String
    var client: GitHubClient
    var model: AppModel
    @State private var pages: GitHubPages?
    @State private var domain = ""
    @State private var busy = false
    @State private var message: String?

    var isApex: Bool { domain.split(separator: ".").count == 2 }

    var body: some View {
        Group {
            LabeledContent("Custom domain") {
                HStack {
                    TextField("", text: $domain, prompt: Text("blog.example.com")).labelsHidden().textFieldStyle(.roundedBorder).frame(width: 200)
                    if pages?.cname != nil, domain.isEmpty || domain == pages?.cname {
                        Button("Remove") { Task { await setDomain(nil) } }.disabled(busy)
                    }
                    Button("Use") { Task { await setDomain(domain) } }
                        .disabled(busy || domain.isEmpty || domain == pages?.cname)
                }
            }
            if let cname = pages?.cname, !cname.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("At your domain registrar, add:").font(.caption.weight(.semibold))
                    if cname.split(separator: ".").count == 2 {
                        Text("A records for \(cname): 185.199.108.153, 185.199.109.153, 185.199.110.153, 185.199.111.153")
                    } else {
                        Text("A CNAME record for \(cname) pointing to \(owner.lowercased()).github.io")
                    }
                    Text("DNS changes can take up to a day. HTTPS can be turned on once GitHub has checked the domain.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .textSelection(.enabled)
                Toggle("Enforce HTTPS", isOn: Binding(get: { pages?.https_enforced ?? false }, set: { value in Task { await setHTTPS(value) } }))
                    .disabled(busy)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .task { await load() }
    }

    func load() async {
        pages = try? await client.pages(owner, repository)
        domain = pages?.cname ?? ""
    }

    func setDomain(_ value: String?) async {
        busy = true
        message = nil
        do {
            try await client.setCustomDomain(owner, repository, domain: value?.trimmingCharacters(in: .whitespaces).lowercased())
            await load()
            await model.sync()
        } catch {
            message = error.localizedDescription
        }
        busy = false
    }

    func setHTTPS(_ enforced: Bool) async {
        busy = true
        message = nil
        do {
            try await client.setHTTPSEnforced(owner, repository, enforced)
            await load()
        } catch {
            message = String(localized: "GitHub could not change HTTPS yet: \(error.localizedDescription)")
        }
        busy = false
    }
}

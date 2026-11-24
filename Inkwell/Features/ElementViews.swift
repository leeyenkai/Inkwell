import InkwellKit
import MapKit
import SwiftUI

/// Insert › Element: every page element with what it is for.
struct ElementPicker: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let columns = [GridItem(.adaptive(minimum: 220), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert an element").font(.title2.weight(.semibold))
            Text("Elements are written into the page as plain text that GitHub Pages builds as it is. Edit one later with its Edit button.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(PageElement.allCases) { kind in
                        Button {
                            dismiss()
                            DispatchQueue.main.async { model.insertElement(kind) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: kind.symbol).font(.title3).frame(width: 28).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title).font(.headline)
                                    Text(kind.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(kind.title). \(kind.summary)"))
                    }
                }
            }
            .frame(height: 380)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 640)
    }
}

/// The settings of one element. Items (pictures, places, entries, cards, links) are edited as rows here; the
/// element's other text stays in the editor.
struct ElementEditorSheet: View {
    var model: AppModel
    var edit: AppModel.ElementEdit
    @Environment(\.dismiss) private var dismiss
    @State private var attributes: [String: String] = [:]
    @State private var pictures: [PageElements.Picture] = []
    @State private var places: [PageElements.Place] = []
    @State private var entries: [PageElements.TimelineItem] = []
    @State private var cards: [PageElements.Card] = []
    @State private var links: [PageElements.LinkItem] = []
    @State private var summary = ""
    @State private var columns = 2
    @State private var itemsReadable = true
    @State private var loaded = false

    var kind: PageElement { edit.span.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(kind.title, systemImage: kind.symbol).font(.title2.weight(.semibold))
            Text(kind.summary).foregroundStyle(.secondary)
            Form { form }
                .formStyle(.grouped)
                .frame(minHeight: 160, maxHeight: 520)
            HStack {
                if !itemsReadable {
                    Label("The list inside was changed by hand. Edit it in the text.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    model.elementEdit = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Done") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onAppear(perform: load)
    }

    @ViewBuilder var form: some View {
        switch kind {
        case .gallery:
            Section {
                Picker("Columns", selection: binding("columns", default: "3")) {
                    ForEach(2 ... 5, id: \.self) { Text("\($0)").tag(String($0)) }
                }
                Picker("Layout", selection: binding("style", default: "")) {
                    Text("Even grid").tag("")
                    Text("Masonry (keeps each picture’s shape)").tag("masonry")
                }
            }
            if itemsReadable { PicturesEditor(model: model, pictures: $pictures) }
        case .slideshow:
            Section {
                Picker("Moves on by itself", selection: binding("autoplay", default: "")) {
                    Text("No").tag("")
                    Text("Every 3 seconds").tag("3")
                    Text("Every 5 seconds").tag("5")
                    Text("Every 8 seconds").tag("8")
                }
            }
            if itemsReadable { PicturesEditor(model: model, pictures: $pictures) }
        case .map:
            if itemsReadable { PlacesEditor(places: $places) }
            Section {
                Picker("Zoom for one place", selection: binding("zoom", default: "")) {
                    Text("City").tag("")
                    Text("Country").tag("6")
                    Text("Region").tag("9")
                    Text("Street").tag("16")
                }
                Text("Maps use OpenStreetMap. Without a connection, readers see the list of places.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .timeline:
            if itemsReadable {
                Section("Entries") {
                    ForEach($entries) { $entry in
                        HStack {
                            TextField("When", text: $entry.date).frame(width: 110).labelsHidden()
                            TextField("What happened", text: $entry.text).labelsHidden()
                            RowButtons(items: $entries, item: entry)
                        }
                    }
                    Button("Add Entry", systemImage: "plus") { entries.append(.init(date: "", text: "")) }
                }
            }
        case .callout:
            Picker("Kind", selection: binding("tone", default: "note")) {
                Text("Note").tag("note")
                Text("Tip").tag("tip")
                Text("Warning").tag("warning")
                Text("Important").tag("important")
            }
            .pickerStyle(.segmented)
        case .columns:
            Picker("Columns", selection: $columns) {
                Text("2").tag(2)
                Text("3").tag(3)
                Text("4").tag(4)
            }
            .pickerStyle(.segmented)
            Text("Columns sit side by side on wide screens and stack on phones. Columns with text are never removed here.")
                .font(.caption).foregroundStyle(.secondary)
        case .toggle:
            TextField("Heading", text: $summary, prompt: Text("A question or heading"))
            Text("The text under the heading in the editor is what opens.").font(.caption).foregroundStyle(.secondary)
        case .tabs:
            Text("Each ### heading inside the element starts a tab. Add one here, or type a ### heading in the text.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Add Tab", systemImage: "plus") {
                let title = String(localized: "New tab")
                summary = summary.isEmpty ? title : summary
                attributes["_addTab"] = "1"
            }
        case .button:
            TextField("Label", text: binding("text", default: ""))
            LinkField(model: model, link: binding("href", default: ""))
            Picker("Style", selection: binding("style", default: "solid")) {
                Text("Filled").tag("solid")
                Text("Outline").tag("outline")
            }
            .pickerStyle(.segmented)
        case .cards:
            if itemsReadable { CardsEditor(model: model, cards: $cards) }
        case .hero:
            ImageField(model: model, title: String(localized: "Background picture"), path: binding("image", default: ""))
            Text("The title and line of text are in the editor. Without a picture, the banner uses the theme’s panel colour.")
                .font(.caption).foregroundStyle(.secondary)
        case .recent:
            Picker("Section", selection: binding("collection", default: model.elementCollections.first ?? "posts")) {
                ForEach(model.elementCollections, id: \.self) { Text(model.site?.section($0)?.label ?? $0.capitalized).tag($0) }
            }
            Picker("How many", selection: binding("limit", default: "5")) {
                ForEach(["3", "5", "10", "20"], id: \.self) { Text($0).tag($0) }
            }
            Picker("Show as", selection: binding("style", default: "")) {
                Text("List").tag("")
                Text("Cards with pictures").tag("cards")
            }
        case .archive:
            Picker("Section", selection: binding("collection", default: model.elementCollections.first ?? "posts")) {
                ForEach(model.elementCollections, id: \.self) { Text(model.site?.section($0)?.label ?? $0.capitalized).tag($0) }
            }
        case .contents:
            Text("The table of contents lists this page’s headings. It has no settings.").foregroundStyle(.secondary)
        case .social:
            if itemsReadable {
                Section("Links") {
                    ForEach($links) { $link in
                        HStack {
                            TextField("Name", text: $link.title, prompt: Text("Email")).frame(width: 140).labelsHidden()
                            TextField("Address", text: $link.url, prompt: Text("https://")).labelsHidden()
                            RowButtons(items: $links, item: link)
                        }
                    }
                    Button("Add Link", systemImage: "plus") { links.append(.init(title: "", url: "https://")) }
                }
            }
        }
    }

    func binding(_ key: String, default value: String) -> Binding<String> {
        Binding(get: { attributes[key] ?? value }, set: { attributes[key] = $0 })
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        attributes = edit.span.attributes
        if kind == .button { attributes["href"] = PageElements.plainPath(attributes["href"] ?? "") }
        let inner = edit.inner
        switch kind {
        case .gallery, .slideshow:
            if let items = PageElements.pictures(inner) { pictures = items } else { itemsReadable = inner.isEmpty }
        case .map:
            if let items = PageElements.places(inner) { places = items } else { itemsReadable = inner.isEmpty }
        case .timeline:
            if let items = PageElements.timeline(inner) { entries = items } else { itemsReadable = inner.isEmpty }
        case .cards:
            if let items = PageElements.cards(inner) { cards = items } else { itemsReadable = inner.isEmpty }
        case .social:
            if let items = PageElements.links(inner) { links = items } else { itemsReadable = inner.isEmpty }
        case .toggle:
            summary = PageElements.summary(inner)
        case .columns:
            columns = max(2, PageElements.columnCount(inner))
        default:
            break
        }
    }

    func finish() {
        var attrs = attributes
        var inner: String?
        switch kind {
        case .gallery, .slideshow:
            if itemsReadable { inner = PageElements.picturesMarkdown(pictures.filter { !$0.path.isEmpty }) }
        case .map:
            if itemsReadable { inner = PageElements.placesMarkdown(places) }
        case .timeline:
            if itemsReadable { inner = PageElements.timelineMarkdown(entries.filter { !$0.date.isEmpty || !$0.text.isEmpty }) }
        case .cards:
            if itemsReadable { inner = PageElements.cardsMarkdown(cards.filter { !$0.title.isEmpty }) }
        case .social:
            if itemsReadable { inner = PageElements.linksMarkdown(links.filter { !$0.title.isEmpty && !$0.url.isEmpty }) }
        case .toggle:
            attrs["summary"] = summary
        case .columns:
            inner = PageElements.columns(edit.inner, count: columns)
        case .tabs:
            if attrs.removeValue(forKey: "_addTab") != nil {
                let tab = "### \(String(localized: "New tab"))\n\(String(localized: "Text for this tab."))"
                inner = edit.inner + (edit.inner.isEmpty ? "" : "\n\n") + tab
            }
        default:
            break
        }
        model.finishElementEdit(attributes: attrs, inner: inner)
        dismiss()
    }
}

/// Up, down and remove for a row in an item list.
struct RowButtons<Item: Identifiable & Equatable>: View {
    @Binding var items: [Item]
    var item: Item

    var body: some View {
        let index = items.firstIndex { $0.id == item.id } ?? 0
        HStack(spacing: 2) {
            Button("Move Up", systemImage: "chevron.up") { items.swapAt(index, index - 1) }.disabled(index == 0)
            Button("Move Down", systemImage: "chevron.down") { items.swapAt(index, index + 1) }.disabled(index >= items.count - 1)
            Button("Remove", systemImage: "minus.circle") { items.removeAll { $0.id == item.id } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

struct PicturesEditor: View {
    var model: AppModel
    @Binding var pictures: [PageElements.Picture]
    @State private var importing = false

    var body: some View {
        Section("Pictures") {
            ForEach($pictures) { $picture in
                HStack(alignment: .top, spacing: 10) {
                    Thumbnail(model: model, path: picture.path)
                    VStack(spacing: 6) {
                        TextField("Alt text", text: $picture.alt, prompt: Text("What the picture shows")).labelsHidden()
                        TextField("Caption", text: $picture.caption, prompt: Text("Caption (optional)")).labelsHidden()
                    }
                    RowButtons(items: $pictures, item: picture)
                }
            }
            HStack {
                Button("Add Pictures…", systemImage: "plus") { choose() }
                if importing { ProgressView().controlSize(.small) }
            }
            if pictures.contains(where: { $0.alt.trimmingCharacters(in: .whitespaces).isEmpty }) {
                Label("Pictures without alt text are silent for people using screen readers.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose pictures. They are resized, cleaned of location data and copied into the site.")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        importing = true
        Task {
            let paths = await model.importPictures(urls)
            pictures += paths.map { PageElements.Picture(path: $0, alt: "") }
            importing = false
        }
    }
}

struct Thumbnail: View {
    var model: AppModel
    var path: String

    var body: some View {
        Group {
            if let url = model.fileURL(forSitePath: path), let image = Thumbnails.shared.image(for: url, size: 120) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .background(Color(nsColor: .quaternaryLabelColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

struct ImageField: View {
    var model: AppModel
    var title: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                if !path.isEmpty { Thumbnail(model: model, path: path) }
                Button(path.isEmpty ? String(localized: "Choose…") : String(localized: "Change…")) { choose() }
                if !path.isEmpty { Button("Remove") { path = "" } }
            }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { if let first = await model.importPictures([url]).first { path = first } }
    }
}

/// A link: typed, or picked from the site's posts and pages.
struct LinkField: View {
    var model: AppModel
    @Binding var link: String

    var body: some View {
        LabeledContent("Link") {
            HStack {
                TextField("Link", text: $link, prompt: Text("https:// or /about/")).labelsHidden()
                Menu("Pages and Posts") {
                    ForEach(model.linkTargets.prefix(80), id: \.url) { target in
                        Button(target.title) { link = target.url }
                    }
                }
                .fixedSize()
            }
        }
    }
}

struct CardsEditor: View {
    var model: AppModel
    @Binding var cards: [PageElements.Card]

    var body: some View {
        Section("Cards") {
            ForEach($cards) { $card in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Title", text: $card.title, prompt: Text("Title")).labelsHidden()
                        RowButtons(items: $cards, item: card)
                    }
                    TextField("Text", text: $card.text, prompt: Text("A sentence about it")).labelsHidden()
                    LinkField(model: model, link: $card.link)
                    ImageField(model: model, title: String(localized: "Picture"), path: $card.image)
                }
                .padding(.vertical, 4)
            }
            Button("Add Card", systemImage: "plus") { cards.append(.init(title: "", link: "", text: "")) }
        }
    }
}

/// Places found with Apple Maps search, written as coordinates so the site needs no account or key.
struct PlacesEditor: View {
    @Binding var places: [PageElements.Place]
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        Section("Places") {
            if !places.isEmpty {
                Map {
                    ForEach(places) { place in
                        Marker(place.name, coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ForEach($places) { $place in
                HStack {
                    TextField("Name", text: $place.name).labelsHidden()
                    Text(String(format: "%.3f, %.3f", place.latitude, place.longitude)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    RowButtons(items: $places, item: place)
                }
            }
            HStack {
                TextField("Find a place", text: $query, prompt: Text("Find a place to add")).labelsHidden()
                    .onSubmit(search)
                Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if searching { ProgressView().controlSize(.small) }
            }
            ForEach(results, id: \.self) { item in
                Button {
                    let c = item.location.coordinate
                    places.append(.init(name: item.name ?? query, latitude: c.latitude, longitude: c.longitude))
                    results = []
                    query = ""
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "")
                        if let address = item.address?.shortAddress { Text(address).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    func search() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        searching = true
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            results = Array((response?.mapItems ?? []).prefix(5))
            searching = false
        }
    }
}

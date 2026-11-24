import InkwellKit
import SwiftUI

struct PhotoGrid: View {
    @Bindable var model: AppModel

    var body: some View {
        let photos = model.photos
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(photos) { photo in
                    PhotoTile(model: model, photo: photo, selected: model.selectedPhotoID == photo.id)
                        .onTapGesture { model.selectedPhotoID = photo.id }
                }
            }
            .padding(10)
        }
        .overlay {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label("No photos yet", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Add photos from your Mac. Each gets a caption, and they appear newest first.")
                } actions: {
                    Button("Add Photos…") { choosePhotos() }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add Photos…") { choosePhotos() }
                Spacer()
                Text("\(photos.count) photo\(photos.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Photos")
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose photos. They are resized, turned upright and cleaned of location data."
        if panel.runModal() == .OK { model.importPhotos(panel.urls) }
    }
}

struct PhotoTile: View {
    var model: AppModel
    var photo: PhotoEntry
    var selected: Bool

    var body: some View {
        SquareThumbnail(url: model.fileURL(forSitePath: photo.image)).overlay(alignment: .topTrailing) {
            HStack(spacing: 3) {
                if photo.hidden { Image(systemName: "eye.slash.fill") }
                if model.status(of: photo.doc) != .published, !photo.hidden { Image(systemName: "circle.fill").foregroundStyle(.orange) }
            }
            .font(.caption2)
            .padding(4)
            .foregroundStyle(.white)
            .shadow(radius: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
        .opacity(photo.hidden ? 0.5 : 1)
        .accessibilityLabel(photo.caption.isEmpty ? "Photo" : photo.caption)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A square crop of a picture that never grows past its grid cell.
struct SquareThumbnail: View {
    var url: URL?

    var body: some View {
        Color(nsColor: .quaternaryLabelColor)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url, let image = Thumbnails.shared.image(for: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
    }
}

struct PhotoDetail: View {
    var model: AppModel
    var photo: PhotoEntry

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let url = model.fileURL(forSitePath: photo.image), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().padding(20)
                }
            }
            Form {
                LabeledContent("Caption") {
                    CommitField(placeholder: "What it shows, or a line about it", value: photo.caption) { model.updatePhoto(photo, key: "caption", value: $0) }
                }
                LabeledContent("Alt text") {
                    CommitField(placeholder: "For people who can’t see it", value: photo.alt) { model.updatePhoto(photo, key: "alt", value: $0) }
                }
                LabeledContent("Place") {
                    CommitField(placeholder: "Optional; never taken from the photo", value: photo.location) {
                        model.updatePhoto(photo, key: "location", value: $0)
                    }
                }
                DatePicker("Date", selection: Binding(get: { photo.doc.date ?? Date() }, set: { date in
                    model.updatePhoto(photo, key: "date", value: YAMLFormat.date(date, timeZone: model.site?.config.timeZone ?? .current))
                }), displayedComponents: .date)
                Toggle("Hide from the photo stream", isOn: Binding(get: { photo.hidden }, set: {
                    model.updatePhoto(photo, key: "hidden", value: $0 ? "true" : nil)
                }))
                HStack {
                    Button("Delete Photo…", role: .destructive) { model.deletePhoto(photo) }
                    Spacer()
                    if model.pendingChanges > 0 {
                        Button("Publish Changes…") { model.showChanges = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 300)
        }
    }
}

/// One photo at a time after import: caption, alt text and place, Return for the next.
struct CaptionSheet: View {
    @Bindable var model: AppModel
    @State private var index = 0
    @State private var photos: [AppModel.PendingPhoto] = []
    @FocusState private var captionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if photos.indices.contains(index) {
                HStack {
                    Text("Add captions").font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(index + 1) of \(photos.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                if let image = Thumbnails.shared.image(for: photos[index].image.fileURL, size: 900) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 320).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                TextField("Caption", text: $photos[index].caption, prompt: Text("Caption (Return for the next photo)"))
                    .textFieldStyle(.roundedBorder)
                    .focused($captionFocused)
                    .onSubmit(next)
                TextField("Alt text", text: $photos[index].alt, prompt: Text("Alt text: what it shows, for people who can’t see it"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(next)
                HStack {
                    TextField("Place", text: $photos[index].location, prompt: Text("Place (optional)"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(next)
                    DatePicker("Date", selection: $photos[index].date, displayedComponents: .date).labelsHidden()
                }
                HStack {
                    Button("Cancel") { model.cancelPendingPhotos() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if index > 0 { Button("Back") { index -= 1 } }
                    Button(index == photos.count - 1 ? "Add \(photos.count) Photo\(photos.count == 1 ? "" : "s")" : "Next", action: next)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            photos = model.pendingPhotos ?? []
            captionFocused = true
        }
    }

    func next() {
        if index < photos.count - 1 {
            index += 1
            captionFocused = true
        } else {
            model.savePendingPhotos(photos)
        }
    }
}

struct PhotoSetupSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: [(edit: ContentEdit, reason: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Photos").font(.title2.weight(.semibold))
            Text("Each photo becomes a small file with its caption, and the photos page lists them newest first. Nothing goes live until you publish.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(plan.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline) {
                    Text(step.edit.path).font(.callout.monospaced()).frame(width: 220, alignment: .leading)
                    Text(step.reason).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set Up Photos") {
                    model.applyPhotoSetup(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { plan = model.setUpPhotos() }
    }
}

struct GallerySheet: View {
    @Bindable var model: AppModel

    var body: some View {
        if let gallery = model.pendingGallery {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a gallery of \(gallery.images.count) pictures").font(.title2.weight(.semibold))
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(gallery.images.indices, id: \.self) { i in
                            HStack {
                                if let image = Thumbnails.shared.image(for: gallery.images[i].fileURL) {
                                    Image(nsImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                TextField("Alt text", text: Binding(get: { model.pendingGallery?.alts[i] ?? "" }, set: { model.pendingGallery?.alts[i] = $0 }),
                                          prompt: Text("Alt text: what it shows"))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelGallery() }.keyboardShortcut(.cancelAction)
                    Button("Insert Gallery") { if let g = model.pendingGallery { model.insertGallery(g) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 520)
        }
    }
}

// MARK: Media library

struct MediaGrid: View {
    @Bindable var model: AppModel
    @State private var items: [MediaLibrary.Item] = []
    @State private var unusedOnly = false
    @State private var loading = true

    var shown: [MediaLibrary.Item] { unusedOnly ? items.filter(\.usedBy.isEmpty) : items }

    var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(items.reduce(0) { $0 + $1.bytes }), countStyle: .file)
        return "\(items.count) image\(items.count == 1 ? "" : "s") · \(size)"
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(shown) { item in
                    VStack(spacing: 3) {
                        SquareThumbnail(url: model.site?.root.appending(path: item.path))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.selectedMedia == item.path ? Color.accentColor : .clear, lineWidth: 3))
                        Text(item.usedBy.isEmpty ? "Unused" : "\(item.usedBy.count) use\(item.usedBy.count == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(item.usedBy.isEmpty ? .orange : .secondary)
                    }
                    .onTapGesture { model.selectedMedia = item.path }
                }
            }
            .padding(10)
        }
        .overlay { if loading { ProgressView() } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("Unused only", isOn: $unusedOnly).toggleStyle(.checkbox)
                Spacer()
                let unused = items.filter(\.usedBy.isEmpty)
                Button("Delete \(unused.count) Unused…") { deleteUnused(unused) }.disabled(unused.isEmpty)
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Media")
        .navigationSubtitle(subtitle)
        .task(id: model.mediaRevision) { await load() }
    }

    func load() async {
        guard let root = model.site?.root else { return }
        items = await Task.detached { MediaLibrary.scan(siteRoot: root) }.value
        model.mediaItems = items
        loading = false
    }

    func deleteUnused(_ unused: [MediaLibrary.Item]) {
        let alert = NSAlert()
        alert.messageText = "Delete \(unused.count) unused image\(unused.count == 1 ? "" : "s")?"
        alert.informativeText = "No post, page or stylesheet links to them. They leave the site when you next publish; GitHub keeps their history."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let root = model.site?.root else { return }
        for item in unused { try? FileManager.default.removeItem(at: root.appending(path: item.path)) }
        model.selectedMedia = nil
        model.mediaRevision += 1
        model.refreshChanges()
    }
}

struct MediaDetail: View {
    var model: AppModel
    var item: MediaLibrary.Item

    var url: URL? { model.site?.root.appending(path: item.path) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let url, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().padding(20)
                }
            }
            Form {
                LabeledContent("File") { Text(item.path).font(.callout.monospaced()).textSelection(.enabled) }
                LabeledContent("Size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file) + dimensions)
                        .foregroundStyle(item.bytes > 1_000_000 ? .orange : .primary)
                }
                LabeledContent("Used in") {
                    VStack(alignment: .trailing) {
                        if item.usedBy.isEmpty { Text("Nothing links to it").foregroundStyle(.orange) }
                        ForEach(item.usedBy, id: \.self) { path in
                            Button(path) {
                                if let doc = model.site?.documents.first(where: { $0.relativePath == path }) {
                                    model.sidebarSelection = .section(doc.sectionID)
                                    if doc.sectionID == PhotoStream.collection { model.selectedPhotoID = doc.id } else { model.select(doc.id) }
                                }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                HStack {
                    Button("Replace…") { replace() }
                        .help("Choose another picture to use in its place; links to it keep working")
                    Spacer()
                    Button("Delete…", role: .destructive) { delete() }
                }
            }
            .formStyle(.grouped)
            .frame(height: 260)
        }
    }

    var dimensions: String {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return "" }
        return " · \(w) × \(h)"
    }

    func replace() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let source = panel.url, let url else { return }
        do {
            _ = try ImageImport.app.replace(url, with: source)
            Thumbnails.shared.forget(url)
            model.mediaRevision += 1
            model.refreshChanges()
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    func delete() {
        let alert = NSAlert()
        alert.messageText = "Delete \((item.path as NSString).lastPathComponent)?"
        let places = "\(item.usedBy.count) place\(item.usedBy.count == 1 ? "" : "s")"
        alert.informativeText = item.usedBy.isEmpty ? "Nothing links to it." : "It is used in \(places), which will show a broken image."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let url else { return }
        try? FileManager.default.removeItem(at: url)
        model.selectedMedia = nil
        model.mediaRevision += 1
        model.refreshChanges()
    }
}

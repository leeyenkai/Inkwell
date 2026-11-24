import InkwellKit
import SwiftUI

struct PublishSheet: View {
    @Bindable var session: PublishSession
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.heading)
                .font(.title2.weight(.semibold))
            if session.phase == .ready {
                checklist
            } else {
                progress
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    var checklist: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(session.checks) { item in
                    Label {
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        icon(item.level)
                    }
                }
            }
            if session.addScheduleWorkflow != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Publish it on time", isOn: Binding(get: { session.addScheduleWorkflow == true },
                                                               set: { session.addScheduleWorkflow = $0 }))
                    Text("GitHub Pages only rebuilds when something changes. This adds a small hourly workflow to the site that "
                        + "rebuilds it when a scheduled post comes due. Without it, the post appears the next time you publish anything.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            if let url = session.displayURL {
                LabeledContent("Address") {
                    Text(url).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            LabeledContent("Description") {
                TextField("", text: $session.message).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Files") {
                Text(session.paths.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(session.actionTitle) {
                    Task { await session.run() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(session.kind == .delete ? .red : .accentColor)
                .disabled(session.hasErrors || session.message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .publishing:
                step("Sending to GitHub…", busy: true)
            case let .building(state):
                step("Saved on GitHub", done: true)
                switch state {
                case .waiting, .building: step("GitHub Pages is building the site…", busy: true)
                case let .failed(reason): step("The Pages build failed (\(reason)). Open the repository’s Actions tab on GitHub for the details.", failed: true)
                case let .unknown(reason): step("Could not follow the build: \(reason) The change is on GitHub.", failed: true)
                case .live: step("Live", done: true)
                }
            case .live:
                step("Saved on GitHub", done: true)
                step(session.kind == .delete || session.kind == .unpublish ? "Removed from the live site" : "Live on the site", done: true)
            case .pushed:
                step("Committed and pushed", done: true)
            case .committedOnly:
                step("Committed in the folder. It has no GitHub remote to push to.", done: true)
            case let .pushFailed(message):
                step("Committed here, but not pushed: \(message)", failed: true)
            case let .conflict(paths):
                step("Changed on GitHub too: \(paths.joined(separator: ", ")). Choose which version to keep, then publish again.", failed: true)
            case let .failed(message):
                step(message, failed: true)
            case .ready:
                EmptyView()
            }
            HStack {
                Spacer()
                if case .pushFailed = session.phase {
                    Button("Push Again") { Task { await session.retryPush() } }
                }
                if case .conflict = session.phase {
                    Button("Resolve…") {
                        dismiss()
                        model.showConflicts = true
                    }
                }
                if session.phase == .live, let url = session.liveURL, session.kind == .publish || session.kind == .update {
                    Button("Open Post") { NSWorkspace.shared.open(url) }
                }
                Button(isBusy ? "Hide" : "Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    var isBusy: Bool {
        switch session.phase {
        case .publishing: true
        case let .building(state): !state.isFinished
        default: false
        }
    }

    func step(_ text: String, busy: Bool = false, done _: Bool = false, failed: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? .orange : .green)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    func icon(_ level: CheckItem.Level) -> some View {
        switch level {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}

/// Every unpublished file in the site, to publish together (design changes, pages, images, several posts).
struct ChangesSheet: View {
    var model: AppModel
    @State private var included: Set<String> = []
    @State private var message = "Update site"
    @Environment(\.dismiss) private var dismiss

    var sorted: [(String, ChangeKind)] { model.changes.sorted { $0.key < $1.key } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unpublished changes").font(.title2.weight(.semibold))
            if sorted.isEmpty {
                Text("Everything on this Mac is already on your site.").foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(sorted, id: \.0) { path, kind in
                        Toggle(isOn: Binding(get: { included.contains(path) }, set: { if $0 { included.insert(path) } else { included.remove(path) } })) {
                            HStack {
                                Text(label(kind)).font(.caption.weight(.semibold)).foregroundStyle(color(kind)).frame(width: 62, alignment: .leading)
                                Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 320)
                LabeledContent("Description") {
                    TextField("", text: $message).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                if !sorted.isEmpty {
                    Button(included.count == sorted.count ? "Select None" : "Select All") {
                        included = included.count == sorted.count ? [] : Set(sorted.map(\.0))
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Publish \(included.count)") { model.publishAll(paths: included.sorted(), message: message) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(included.isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { included = Set(model.changes.keys) }
    }

    func label(_ kind: ChangeKind) -> String {
        switch kind {
        case .added: "New"
        case .modified: "Changed"
        case .deleted: "Removed"
        }
    }

    func color(_ kind: ChangeKind) -> Color {
        switch kind {
        case .added: .green
        case .modified: .accentColor
        case .deleted: .red
        }
    }
}

/// Files changed both here and on GitHub since the last sync.
struct ConflictSheet: View {
    var model: AppModel
    @State private var comparing: String?
    @State private var theirs = ""
    @State private var mine = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Changed in two places").font(.title2.weight(.semibold))
            Text("These files were changed on GitHub and on this Mac since they were last in step. Choose which version to keep.")
                .foregroundStyle(.secondary)
            if model.conflicts.isEmpty {
                Label("Nothing left to resolve.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            ForEach(model.conflicts, id: \.self) { path in
                HStack {
                    Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Compare") { compare(path) }
                    Button("Use GitHub’s") { resolve(path, keepMine: false) }
                    Button("Keep Mine") { resolve(path, keepMine: true) }
                }
            }
            if let comparing {
                Divider()
                Text(comparing).font(.caption.monospaced()).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    version("This Mac", mine)
                    version("GitHub", theirs)
                }
                .frame(height: 260)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: comparing == nil ? 600 : 820)
    }

    func version(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ScrollView {
                Text(text).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    func compare(_ path: String) {
        guard let backend = model.backend else { return }
        comparing = path
        mine = (try? String(contentsOf: backend.siteRoot.appending(path: path), encoding: .utf8)) ?? "(removed here)"
        Task { theirs = (try? await backend.remoteVersion(of: path)) ?? "(removed on GitHub)" }
    }

    func resolve(_ path: String, keepMine: Bool) {
        guard let backend = model.backend else { return }
        Task {
            do {
                try await backend.resolve(path: path, keepMine: keepMine)
            } catch {
                model.errorMessage = error.localizedDescription
            }
            if comparing == path { comparing = nil }
            model.editor?.reloadIfChangedOnDisk()
            model.reloadSite()
        }
    }
}

struct ImageSheet: View {
    @Bindable var model: AppModel
    @FocusState private var altFocused: Bool

    var body: some View {
        if let pending = model.pendingImage {
            VStack(alignment: .leading, spacing: 14) {
                Text("Add Image").font(.title2.weight(.semibold))
                HStack(alignment: .top, spacing: 16) {
                    if let image = NSImage(contentsOf: pending.image.fileURL) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 150, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pending.image.sitePath).font(.callout.monospaced())
                        Text(summary(pending.image)).font(.caption).foregroundStyle(.secondary)
                        if pending.image.removedLocation {
                            Label("Location removed", systemImage: "location.slash").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                TextField("Alt text: what the image shows, for people who can’t see it",
                          text: Binding(get: { model.pendingImage?.alt ?? "" }, set: { model.pendingImage?.alt = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($altFocused)
                TextField("Caption (optional)", text: Binding(get: { model.pendingImage?.caption ?? "" }, set: { model.pendingImage?.caption = $0 }))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelPendingImage() }
                        .keyboardShortcut(.cancelAction)
                    Button("Insert") { model.insertPendingImage() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 480)
            .onAppear { altFocused = true }
        }
    }

    func summary(_ image: ImportedImage) -> String {
        let before = ByteCountFormatter.string(fromByteCount: Int64(image.originalBytes), countStyle: .file)
        let after = ByteCountFormatter.string(fromByteCount: Int64(image.finalBytes), countStyle: .file)
        return "\(image.pixelWidth) × \(image.pixelHeight) · \(before) → \(after)"
    }
}

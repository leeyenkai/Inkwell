import InkwellKit
import SwiftUI

struct PublishSheet: View {
    @Bindable var session: PublishSession
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session.isUpdate ? "Update “\(title)”" : "Publish “\(title)”")
                .font(.title2.weight(.semibold))
            switch session.phase {
            case .ready:
                checklist
            default:
                progress
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    var title: String {
        let t = FrontMatterDocument(text: session.text).value("title")?.string ?? ""
        return t.isEmpty ? "Untitled" : t
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
            Divider()
            LabeledContent("Address") {
                Text(session.displayURL).font(.callout.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Commit message") {
                TextField("", text: $session.message).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Files") {
                Text(session.paths.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(session.isUpdate ? "Update" : "Publish") {
                    Task { await session.publish() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(session.hasErrors || session.message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .publishing:
                step("Committing and pushing…", busy: true)
            case let .building(state):
                step("Pushed to GitHub", done: true)
                switch state {
                case .waiting, .building: step("GitHub Pages is building the site…", busy: true)
                case let .failed(reason): step("The Pages build failed (\(reason)). Open the repository’s Actions tab for the log.", failed: true)
                case let .unknown(reason): step("Could not read the build status: \(reason)", failed: true)
                case .live: step("Live", done: true)
                }
            case .live:
                step("Pushed to GitHub", done: true)
                step("Live on the site", done: true)
            case .pushed:
                step("Committed and pushed", done: true)
            case .committedOnly:
                step("Committed in the site folder. It has no remote to push to.", done: true)
            case let .failed(message):
                step(message, failed: true)
            case .ready:
                EmptyView()
            }
            HStack {
                Spacer()
                if session.phase == .live, let url = session.liveURL {
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
                Image(systemName: failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? .red : .green)
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

import InkwellKit
import SwiftUI

struct EditorView: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorDocument
    @FocusState private var titleFocused: Bool
    @State private var format = EditorFormatState()
    @AppStorage("ShowFormatBar") private var showFormatBar = true

    var body: some View {
        VStack(spacing: 0) {
            if showFormatBar, editor.loadError == nil {
                FormatBar(model: model, format: format)
                Divider()
            }
            if let error = editor.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.orange.opacity(0.1))
            }
            if editor.diskConflict != nil {
                HStack {
                    Label("This post changed outside Inkwell while you were editing it.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Use the Other Version") { editor.resolveDiskConflict(keepMine: false) }
                    Button("Keep Mine") { editor.resolveDiskConflict(keepMine: true) }
                }
                .padding(10)
                .background(.orange.opacity(0.1))
            }
            if !model.showSource {
                header
            }
            MarkdownEditor(
                text: model.showSource
                    ? Binding(get: { editor.fullText }, set: { editor.setFullText($0) })
                    : Binding(get: { editor.body }, set: { editor.body = $0 }),
                revision: editor.revision &+ (model.showSource ? 1_000_000 : 0),
                sourceMode: model.showSource,
                model: model,
                format: format
            )
            .id("\(ObjectIdentifier(editor).hashValue)" + (model.showSource ? "-source" : ""))
            .disabled(editor.loadError != nil)
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: editor.focusTitle, initial: true) {
            if editor.focusTitle {
                titleFocused = true
                editor.focusTitle = false
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editor.isCollectionPost {
                TextField("Title", text: Binding(get: { editor.title }, set: { editor.title = $0 }), axis: .vertical)
                    .font(.system(size: 28, weight: .bold))
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .accessibilityLabel("Title")
            } else {
                Text(editor.document.title).font(.system(size: 28, weight: .bold))
            }
            PropertiesView(model: model, editor: editor)
            SharingView(model: model, editor: editor)
            Divider().padding(.top, 2)
        }
        .padding(.top, 22)
        .padding(.horizontal, 28)
        .frame(maxWidth: InkwellTextView.columnWidth + 56)
        .frame(maxWidth: .infinity)
    }

    var footer: some View {
        HStack(spacing: 14) {
            if format.selectedCharacters > 0 {
                Text("^[\(format.selectedWords) words](inflect: true), ^[\(format.selectedCharacters) characters](inflect: true) selected")
            } else {
                Text("\(editor.wordCount) words · \(editor.readingMinutes) min read")
            }
            if let issue = editor.issues.first {
                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                    .lineLimit(1)
            }
            Spacer()
            Text(editor.document.relativePath)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Toggle(isOn: $model.showSource) {
                Text("Source")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show the raw file (⇧⌘E)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct PropertiesView: View {
    @Bindable var model: AppModel
    @Bindable var editor: EditorDocument

    var body: some View {
        DisclosureGroup(isExpanded: $model.showProperties) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(editor.fields.filter { $0.key != "title" }) { field in
                    GridRow {
                        Text(field.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        fieldEditor(field)
                    }
                }
                ForEach(editor.otherKeys, id: \.self) { key in
                    GridRow {
                        Text(key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(editor.frontMatter.rawValue(key) ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("URL").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        Text(editor.displayURL).font(.callout.monospaced()).textSelection(.enabled)
                        if editor.document.origin == .localDraft {
                            Text("follows the title").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(.top, 8)
            .padding(.leading, 4)
            // A page with few properties stays at the left edge, lined up with the rest of the form.
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Properties").font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func fieldEditor(_ field: FieldSpec) -> some View {
        let issue = editor.issues.first { $0.field == field.key }
        HStack(spacing: 8) {
            switch field.kind {
            case .date:
                if let date = editor.date(field.key) {
                    let timed = editor.hasTime(field.key)
                    DatePicker("", selection: Binding(get: { date }, set: { editor.setDate(field.key, $0) }),
                               displayedComponents: timed ? [.date, .hourAndMinute] : .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .environment(\.timeZone, editor.timeZone)
                        .fixedSize()
                    Button {
                        editor.setDate(field.key, date, withTime: !timed)
                    } label: {
                        Image(systemName: timed ? "clock.badge.xmark" : "clock")
                    }
                    .buttonStyle(.borderless)
                    .help(timed
                        ? String(localized: "Remove the time of day")
                        : String(localized: "Add a time of day, for a post scheduled to go live at a set hour"))
                    if date > Date(), !editor.publishesFutureNow {
                        Text("Scheduled").font(.caption).foregroundStyle(Color.accentColor)
                    }
                } else {
                    // Committed on Return or leaving the field: a date read while it is still being typed (2026-11-2)
                    // would turn the field into a date picker holding the wrong day.
                    CommitField(placeholder: "YYYY-MM-DD", value: editor.string(field.key)) { editor.frontMatterSetRaw(field.key, $0) }
                        .frame(width: 140)
                }
            case .toggle:
                Toggle("", isOn: Binding(get: { editor.bool(field.key, default: field.defaultBool ?? true) }, set: { editor.setBool(field.key, $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            case .tags:
                VStack(alignment: .leading, spacing: 4) {
                    let tagText = Binding(get: { editor.tags(field.key).joined(separator: ", ") }, set: { editor.setTags(field.key, $0) })
                    TextField("comma, separated", text: tagText)
                        .textFieldStyle(.roundedBorder)
                    let current = Set(editor.tags(field.key))
                    let suggestions = model.allTags.map(\.name).filter { !current.contains($0) }.prefix(8)
                    if !suggestions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(suggestions), id: \.self) { tag in
                                Button(tag) { editor.setTags(field.key, (editor.tags(field.key) + [tag]).joined(separator: ", ")) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                            }
                        }
                    }
                }
            case .text:
                TextField(field.isUniversal ? "" : String(localized: "Optional"),
                          text: Binding(get: { editor.string(field.key) }, set: { editor.setString(field.key, $0) }))
                    .textFieldStyle(.roundedBorder)
            }
            if let issue {
                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                    .help(issue.message)
            }
        }
    }
}

extension EditorDocument {
    /// Keeps whatever was typed into a date field that does not hold a date yet, so it can be fixed in place. A date is
    /// read in the site's time zone, the one it is written in.
    func frontMatterSetRaw(_ key: String, _ text: String) {
        if let date = SiteDate.parse(text, timeZone: timeZone), text.count >= 8 {
            setDate(key, date)
        } else {
            setString(key, text)
        }
    }
}

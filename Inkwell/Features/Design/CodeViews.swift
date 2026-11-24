import InkwellKit
import SwiftUI

struct CodeFile: Identifiable, Hashable {
    /// Site-relative path.
    var path: String
    var inTheme: Bool
    var id: String { (inTheme ? "theme:" : "site:") + path }
    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
}

extension DesignModel {
    static let codeExtensions: Set = ["html", "htm", "liquid", "css", "scss", "sass", "js", "yml", "yaml", "json", "xml", "txt"]

    /// Design files in the site, grouped for the file list.
    func codeFiles(themeRoot: URL?) -> [(String, [CodeFile])] {
        func list(_ root: URL, _ folder: String, inTheme: Bool, recursive: Bool = true) -> [CodeFile] {
            let base = root.appending(path: folder, directoryHint: .isDirectory)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
            else { return [] }
            var files: [CodeFile] = []
            let rootPath = root.standardizedFileURL.path
            for case let url as URL in enumerator where Self.codeExtensions.contains(url.pathExtension.lowercased()) {
                files.append(CodeFile(path: String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1)), inTheme: inTheme))
            }
            return files.sorted { $0.path < $1.path }
        }
        var groups: [(String, [CodeFile])] = [
            (String(localized: "Layouts"), list(root, "_layouts", inTheme: false)),
            (String(localized: "Includes"), list(root, "_includes", inTheme: false)),
            (String(localized: "Styles and scripts"), list(root, "_sass", inTheme: false) + list(root, "assets", inTheme: false)),
            (String(localized: "Settings and data"), (FileManager.default.fileExists(atPath: root.appending(path: "_config.yml").path)
                    ? [CodeFile(path: "_config.yml", inTheme: false)] : []) + list(root, "_data", inTheme: false)),
        ]
        if let themeRoot {
            let own = Set(groups.flatMap(\.1).map(\.path))
            let themeFiles = (list(themeRoot, "_layouts", inTheme: true) + list(themeRoot, "_includes", inTheme: true)
                + list(themeRoot, "_sass", inTheme: true) + list(themeRoot, "assets", inTheme: true)).filter { !own.contains($0.path) }
            groups.append((String(localized: "Theme files (read-only)"), themeFiles))
        }
        return groups.filter { !$0.1.isEmpty }
    }

    func readCode(_ file: CodeFile, themeRoot: URL?) -> String? {
        let base = file.inTheme ? themeRoot : root
        return base.flatMap { try? String(contentsOf: $0.appending(path: file.path), encoding: .utf8) }
    }

    func saveCode(_ file: CodeFile, _ text: String) {
        guard !file.inTheme, read(file.path) != text else { return }
        write(file.path, text)
        if file.path == "_config.yml" || file.path.hasPrefix("_data/") || file.path.hasPrefix("assets/css/inkwell") {
            reload()
        } else {
            bump()
        }
    }

    /// Copies a theme file into the site at the same path, where it overrides the theme's copy.
    func copyIntoSite(_ file: CodeFile, themeRoot: URL?) -> CodeFile? {
        guard file.inTheme, let text = readCode(file, themeRoot: themeRoot) else { return nil }
        write(file.path, text)
        bump()
        return CodeFile(path: file.path, inTheme: false)
    }
}

struct CodeFileList: View {
    var design: DesignModel
    @Bindable var model: AppModel
    @State private var showNewFile = false
    @State private var newPath = "_includes/"

    var body: some View {
        let groups = design.codeFiles(themeRoot: model.themeRoot)
        List(selection: $model.codeFile) {
            ForEach(groups, id: \.0) { title, files in
                Section(title) {
                    ForEach(files) { file in
                        Label {
                            HStack {
                                Text(file.path).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if !file.inTheme, model.changes[file.path] != nil {
                                    Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor).help("Not published yet")
                                }
                            }
                        } icon: {
                            Image(systemName: icon(file.ext)).foregroundStyle(file.inTheme ? .tertiary : .secondary)
                        }
                        .tag(file)
                    }
                }
            }
        }
        .navigationTitle("Code")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("New File…") { showNewFile = true }
                Spacer()
            }
            .padding(10)
        }
        .alert("New file", isPresented: $showNewFile) {
            TextField("_includes/footer-extra.html", text: $newPath)
            Button("Create") {
                let path = newPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                guard !path.isEmpty, !path.contains(".."), design.read(path) == nil else { return }
                design.write(path, "")
                model.codeFile = CodeFile(path: path, inTheme: false)
                model.refreshChanges()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A path in the site, such as _includes/analytics.html or assets/js/site.js.")
        }
    }

    func icon(_ ext: String) -> String {
        switch ext {
        case "css", "scss", "sass": "paintbrush"
        case "yml", "yaml", "json": "slider.horizontal.3"
        case "js": "curlybraces"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct CodeEditorPane: View {
    var design: DesignModel
    @Bindable var model: AppModel
    var file: CodeFile
    @State private var text = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(file.path).font(.callout.monospaced())
                if file.inTheme {
                    Text("Theme file").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy into Site to Edit") {
                        if let copy = design.copyIntoSite(file, themeRoot: model.themeRoot) { model.codeFile = copy }
                        model.refreshChanges()
                    }
                } else {
                    Spacer()
                    if model.changes[file.path] != nil {
                        Button("Revert to Published…") { revert() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            HSplitView {
                CodeEditor(text: Binding(get: { text }, set: { text = $0; scheduleSave() }), fileExtension: file.ext, editable: !file.inTheme,
                           identity: file.id)
                    .frame(minWidth: 320)
                DesignPreview(design: design, model: model)
                    .frame(minWidth: 320)
            }
        }
        .onAppear(perform: load)
        .onChange(of: file) {
            saveNow()
            load()
        }
        .onDisappear(perform: saveNow)
    }

    func load() {
        text = design.readCode(file, themeRoot: model.themeRoot) ?? ""
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard !file.inTheme, design.read(file.path) != nil || !text.isEmpty else { return }
        design.saveCode(file, text)
    }

    func revert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Revert \(file.name) to the published version?")
        alert.informativeText = model.changes[file.path] == .added
            ? String(localized: "The file is new, so it is removed.")
            : String(localized: "Your unpublished changes to it are discarded.")
        alert.addButton(withTitle: String(localized: "Revert"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn, let backend = model.backend else { return }
        saveTask?.cancel()
        let path = file.path
        Task {
            do {
                try await backend.discard(path: path)
            } catch {
                model.errorMessage = error.localizedDescription
            }
            design.reload()
            if design.read(path) == nil { model.codeFile = nil } else { load() }
            model.refreshChanges()
        }
    }
}

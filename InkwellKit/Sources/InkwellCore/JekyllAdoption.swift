import Foundation

/// Moving a hand-built site to Jekyll, an optional step the person asks for (SPEC §4.12, W4 step 3). A header, menu or
/// footer that several pages copy becomes one file in `_includes`, so it is changed in one place; the pages that use it
/// get front matter with `layout: null`, so they come out exactly as before; and `.nojekyll` is removed. Every change is
/// planned first and shown for review, and nothing is written until the person agrees.
public enum JekyllAdoption {
    public struct SharedFile: Sendable, Equatable {
        public var path: String
        public var part: SharedParts.Part
        public var pages: [String]
    }

    public struct Plan: Sendable, Equatable {
        /// The new text of each file that is written, by site path.
        public var writes: [String: String] = [:]
        /// Files removed: `.nojekyll`.
        public var removals: [String] = []
        /// Each shared part that moves into `_includes`, and the pages that use it.
        public var shared: [SharedFile] = []
        /// Pages left exactly as they are, because they contain `{{` or `{%`, which Jekyll would read as its own tags.
        public var leftAlone: [String] = []
        /// Names Jekyll would stop serving (they start with `_` or `.`), kept by `include:` in `_config.yml`.
        public var keptNames: [String] = []
        /// Names Jekyll would stop serving that could not be added to an `include:` list written in a form Inkwell does
        /// not edit; the person adds them, or they stop being served.
        public var notKept: [String] = []
        /// Markdown files GitHub serves as plain text today and would turn into web pages after the move.
        public var markdownShown: [String] = []

        public var changedPages: [String] { writes.keys.filter { !$0.hasPrefix("_") }.sorted() }
        public var isWorthDoing: Bool { !shared.isEmpty }
    }

    /// Front matter that makes Jekyll read a page (for its includes) without wrapping it in a layout.
    public static let frontMatter = "---\nlayout: null\n---\n"

    /// The plan for the site at `root`, given the text of its HTML pages by site path.
    public static func plan(root: URL, pages: [String: String]) -> Plan {
        var plan = Plan()
        let liquid = Set(pages.filter { $0.value.contains("{{") || $0.value.contains("{%") }.keys)
        plan.leftAlone = liquid.sorted()
        var texts = pages.filter { !liquid.contains($0.key) }

        let existingIncludes = Set((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "_includes").path)) ?? [])
        var usedNames = existingIncludes
        for part in SharedParts.Part.allCases {
            var copies: [String: [String]] = [:]
            for (path, text) in texts {
                if let block = SharedParts.blocks(in: text)[part] { copies[block, default: []].append(path) }
            }
            let shared = copies.filter { $0.value.count >= 2 }.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            for (block, paths) in shared {
                let stem = part == .nav ? "menu" : part.rawValue
                var name = "\(stem).html", n = 2
                while usedNames.contains(name) {
                    name = "\(stem)-\(n).html"
                    n += 1
                }
                let tag = "{% include \(name) %}"
                var using: [String] = []
                for path in paths.sorted() {
                    guard let text = texts[path], let updated = SharedParts.applying(block, tag, to: text) else { continue }
                    texts[path] = updated
                    using.append(path)
                }
                guard using.count >= 2 else {
                    // Undo a lone replacement: one page gains nothing from an include.
                    for path in using { texts[path] = texts[path]?.replacingOccurrences(of: tag, with: block) }
                    continue
                }
                usedNames.insert(name)
                plan.writes["_includes/\(name)"] = block
                plan.shared.append(SharedFile(path: "_includes/\(name)", part: part, pages: using))
            }
        }
        for (path, text) in texts where text != pages[path] {
            plan.writes[path] = frontMatter + text
        }
        guard plan.isWorthDoing else { return Plan(leftAlone: plan.leftAlone) }

        if FileManager.default.fileExists(atPath: root.appending(path: ".nojekyll").path) { plan.removals.append(".nojekyll") }
        plan.markdownShown = markdownFiles(in: root)
        let hidden = hiddenNames(in: root)
        if !hidden.isEmpty {
            let config = try? String(contentsOf: root.appending(path: "_config.yml"), encoding: .utf8)
            if let merged = including(hidden, in: config ?? "") {
                if merged != config { plan.writes["_config.yml"] = merged }
                plan.keptNames = hidden
            } else {
                plan.notKept = hidden
            }
        }
        return plan
    }

    /// `config` with `names` in its `include:` list: a new block list, one more item in a block list, or more names in a
    /// one-line flow list. Nil for other forms, which are left to the person.
    static func including(_ names: [String], in config: String) -> String? {
        var lines = config.components(separatedBy: "\n")
        func quoted(_ name: String) -> String { "\"\(name)\"" }
        func unquoted(_ item: Substring) -> String { item.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r'\"")) }
        guard let index = lines.firstIndex(where: { $0.range(of: #"^include\s*:"#, options: .regularExpression) != nil }) else {
            var text = config
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            return text + "include:\n" + names.map { "  - \(quoted($0))\n" }.joined()
        }
        let line = lines[index]
        let value = line[line.index(after: line.firstIndex(of: ":")!)...].trimmingCharacters(in: .whitespaces)
        let ending = line.hasSuffix("\r") ? "\r" : ""
        if value.isEmpty || value.hasPrefix("#") {
            // A block list: items follow, indented.
            var last = index
            var indent = "  "
            var present = Set<String>()
            for i in (index + 1) ..< lines.count {
                let item = lines[i]
                let trimmed = item.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                // YAML allows a list's items at the key's own indentation ("include:" then "- a") as well as deeper.
                guard trimmed.hasPrefix("- ") || trimmed == "-" else { break }
                indent = String(item.prefix { $0 == " " || $0 == "\t" })
                present.insert(unquoted(trimmed.dropFirst()))
                last = i
            }
            let added = names.filter { !present.contains($0) }.map { "\(indent)- \(quoted($0))\(ending)" }
            lines.insert(contentsOf: added, at: last + 1)
            return lines.joined(separator: "\n")
        }
        guard let match = value.range(of: #"^\[([^\]\[]*)\]\s*(#.*)?$"#, options: .regularExpression), match.lowerBound == value.startIndex,
              let open = value.firstIndex(of: "["), let close = value.firstIndex(of: "]") else { return nil }
        let items = value[value.index(after: open) ..< close].split(separator: ",").map(unquoted).filter { !$0.isEmpty }
        let all = value[value.index(after: open) ..< close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } + names.filter { !items.contains($0) }.map(quoted)
        let comment = value[value.index(after: close)...].trimmingCharacters(in: .whitespaces)
        lines[index] = "include: [\(all.joined(separator: ", "))]" + (comment.isEmpty ? "" : " " + comment) + ending
        return lines.joined(separator: "\n")
    }

    /// Markdown files without front matter that GitHub Pages would turn into pages once Jekyll builds the site. Files
    /// it leaves alone (README, LICENSE and the like) are not listed.
    static func markdownFiles(in root: URL) -> [String] {
        let kept: Set = ["readme", "license", "licence", "copying", "code_of_conduct", "contributing", "issue_template",
                         "pull_request_template"]
        var found: [String] = []
        func scan(_ folder: URL, prefix: String, depth: Int) {
            for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                let name = item.lastPathComponent
                guard !name.hasPrefix("_"), !name.hasPrefix("."), name != "node_modules" else { continue }
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if depth < 6 { scan(item, prefix: prefix + name + "/", depth: depth + 1) }
                } else if ["md", "markdown"].contains(item.pathExtension.lowercased()),
                          !kept.contains((name as NSString).deletingPathExtension.lowercased()) {
                    found.append(prefix + name)
                }
            }
        }
        scan(root, prefix: "", depth: 0)
        return found.sorted()
    }

    /// Files and folders the site serves today whose names Jekyll skips: those starting with `_` or `.`, at any depth.
    static func hiddenNames(in root: URL) -> [String] {
        let tools: Set = [".git", ".github", ".gitignore", ".gitattributes", ".nojekyll", ".DS_Store", "_includes", "_config.yml",
                          ".editorconfig", ".vscode", ".idea"]
        var names = Set<String>()
        func scan(_ folder: URL, depth: Int) {
            for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                let name = item.lastPathComponent
                if tools.contains(name) || name == "node_modules" { continue }
                if name.hasPrefix("_") || name.hasPrefix(".") {
                    names.insert(name)
                } else if depth < 6, (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    scan(item, depth: depth + 1)
                }
            }
        }
        scan(root, depth: 0)
        return names.sorted()
    }
}

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
        plan.keptNames = hiddenNames(in: root)
        if !plan.keptNames.isEmpty {
            let configURL = root.appending(path: "_config.yml")
            let lines = "include:\n" + plan.keptNames.map { "  - \"\($0)\"\n" }.joined()
            if let config = try? String(contentsOf: configURL, encoding: .utf8) {
                if config.range(of: #"(?m)^include\s*:"#, options: .regularExpression) == nil {
                    plan.writes["_config.yml"] = config + (config.hasSuffix("\n") || config.isEmpty ? "" : "\n") + lines
                }
            } else {
                plan.writes["_config.yml"] = lines
            }
        }
        return plan
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

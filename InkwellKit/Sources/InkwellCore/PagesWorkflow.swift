import Foundation

/// How a repository's GitHub Actions workflows build its Pages site, read from `.github/workflows` (SPEC §4.12): with
/// Jekyll, by uploading the files as they are, or with another site generator whose source Inkwell does not edit.
///
/// Locking an editable site as read only is worse than missing a generated one, so the reading is conservative: only
/// the job that uploads or publishes the site counts, and a job that uploads the site's own folder serves its files as
/// they are, whatever else it builds.
public enum PagesWorkflow {
    public enum Build: String, Sendable, Equatable {
        case jekyll
        case filesAsIs
        case otherGenerator
    }

    /// Steps that hand a folder to GitHub Pages, with the setting that names the folder and its default.
    static let publishers: [(step: String, folderKey: String?, defaultFolder: String)] = [
        ("upload-pages-artifact", "path", "_site"),
        ("peaceiris/actions-gh-pages", "publish_dir", "public"),
        ("jamesives/github-pages-deploy-action", "folder", ""),
        ("crazy-max/ghaction-github-pages", "build_dir", ""),
        ("gh-pages -d", nil, ""),
    ]
    static let jekyll = ["jekyll-build-pages", "jekyll build", "bundle exec jekyll"]
    /// Build steps of other generators, and the usual ways of running a project's own build.
    static let builders = [
        "hugo", "astro", "next build", "next export", "gatsby", "eleventy", "@11ty", "mkdocs", "sphinx", "docusaurus", "vitepress",
        "vuepress", "vite build", "zola", "mdbook", "quarto", "hexo", "pelican", "nuxt", "sveltekit", "svelte-kit", "gridsome",
        "npm run build", "npm run generate", "yarn build", "yarn run build", "yarn generate", "pnpm build", "pnpm run build",
        "bun run build", "flutter build web", "trunk build", "wasm-pack", "make html", "docfx", "doxygen", "typedoc", "jsdoc",
    ]

    /// The build of the workflows that publish to Pages, or nil when none does (or none can be read with confidence).
    /// `siteFolder` is the site's folder in the repository ("" for the root, or "docs"). Jekyll wins, so a site Inkwell
    /// can edit is never locked by mistake; then the files served as they are; then another generator.
    public static func build(workflows: [String], siteFolder: String = "") -> Build? {
        let found = workflows.flatMap { jobs(in: $0) }.compactMap { classify(job: $0, siteFolder: siteFolder) }
        return [.jekyll, .filesAsIs, .otherGenerator].first(where: found.contains)
    }

    /// One job's verdict, or nil when it publishes nothing (or a folder that is not this site's).
    static func classify(job: String, siteFolder: String) -> Build? {
        if job.contains("mkdocs gh-deploy") { return .otherGenerator }
        guard let publisher = publishers.first(where: { job.contains($0.step) }) else { return nil }
        if jekyll.contains(where: job.contains) { return .jekyll }
        let folder = normalized(publishedFolder(in: job, publisher: publisher))
        let site = normalized(siteFolder)
        // The site's own folder (or the whole repository) goes up as it is.
        if folder == site || folder.isEmpty { return .filesAsIs }
        return builders.contains(where: job.contains) ? .otherGenerator : nil
    }

    static func publishedFolder(in job: String, publisher: (step: String, folderKey: String?, defaultFolder: String)) -> String {
        guard let start = job.range(of: publisher.step) else { return publisher.defaultFolder }
        // Only this step's settings: up to the next step of the job.
        var after = String(job[start.upperBound...])
        if let next = after.range(of: #"\n\s*-\s"#, options: .regularExpression) { after = String(after[..<next.lowerBound]) }
        if publisher.step == "gh-pages -d" {
            return after.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        }
        guard let key = publisher.folderKey,
              let match = after.range(of: #"\b\#(key)\s*:\s*['"]?([^'"\s,}#]*)"#, options: .regularExpression) else {
            return publisher.defaultFolder
        }
        // The value is what follows the key, up to a quote, a space, a comma or a closing brace.
        let text = String(after[match])
        guard let colon = text.firstIndex(of: ":") else { return publisher.defaultFolder }
        return text[text.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
    }

    static func normalized(_ folder: String) -> String {
        var folder = folder.trimmingCharacters(in: .whitespaces)
        while folder.hasPrefix("./") { folder.removeFirst(2) }
        if folder == "." { folder = "" }
        while folder.hasSuffix("/") { folder.removeLast() }
        if folder.hasPrefix("${{") { return "?" }
        return folder.lowercased()
    }

    /// The text of each job in a workflow, comments removed and lower-cased; the whole file when it has no `jobs:`.
    static func jobs(in workflow: String) -> [String] {
        let lines = workflow.lowercased().components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#") ? "" : line
        }
        guard let jobsLine = lines.firstIndex(where: { $0.hasPrefix("jobs:") }) else { return [lines.joined(separator: "\n")] }
        var result: [String] = []
        var current: [String] = []
        var jobIndent: Int?
        for line in lines[(jobsLine + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 { break }
            if jobIndent == nil { jobIndent = indent }
            if indent == jobIndent, trimmed.hasSuffix(":") {
                if !current.isEmpty { result.append(current.joined(separator: "\n")) }
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    /// The workflows of the repository holding a site at `siteRoot`: its own `.github/workflows`, or the repository's
    /// when the site is in its `docs/` folder. A site whose own folder holds a hand-written home page is never read as
    /// another generator's source.
    public static func build(siteRoot: URL) -> Build? {
        func texts(_ folder: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        var found: [Build] = []
        if let own = build(workflows: texts(siteRoot.appending(path: ".github/workflows")), siteFolder: "") { found.append(own) }
        if siteRoot.lastPathComponent == "docs",
           let repo = build(workflows: texts(siteRoot.deletingLastPathComponent().appending(path: ".github/workflows")), siteFolder: "docs") {
            found.append(repo)
        }
        guard let build = [.jekyll, .filesAsIs, .otherGenerator].first(where: found.contains) else { return nil }
        if build == .otherGenerator, FileManager.default.fileExists(atPath: siteRoot.appending(path: "index.html").path) { return nil }
        return build
    }
}

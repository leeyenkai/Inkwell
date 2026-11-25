import Foundation

/// How a repository's GitHub Actions workflows build its Pages site, read from `.github/workflows` (SPEC §4.12): with
/// Jekyll, by uploading the files as they are, or with another site generator whose source Inkwell does not edit.
public enum PagesWorkflow {
    public enum Build: String, Sendable, Equatable {
        case jekyll
        case filesAsIs
        case otherGenerator
    }

    /// Steps that put a site on GitHub Pages.
    static let deploys = ["actions/deploy-pages", "upload-pages-artifact", "peaceiris/actions-gh-pages", "jamesives/github-pages-deploy-action",
                          "mkdocs gh-deploy", "gh-pages -d", "crazy-max/ghaction-github-pages"]
    static let jekyll = ["jekyll-build-pages", "jekyll build", "bundle exec jekyll"]
    /// Build steps of other generators, and the usual ways of running a project's own build.
    static let builders = [
        "hugo", "astro", "next build", "next export", "gatsby", "eleventy", "@11ty", "mkdocs", "sphinx", "docusaurus", "vitepress",
        "vuepress", "vite build", "zola", "mdbook", "quarto", "hexo", "pelican", "nuxt", "sveltekit", "svelte-kit", "gridsome",
        "npm run build", "npm run generate", "yarn build", "yarn run build", "yarn generate", "pnpm build", "pnpm run build",
        "bun run build", "flutter build web", "trunk build", "wasm-pack", "make html", "docfx", "doxygen", "typedoc", "jsdoc",
    ]

    /// The build of the workflows that deploy to Pages, or nil when none does. Jekyll wins, so a site Inkwell can edit
    /// is never locked by mistake; then another generator, then an upload of the files as they are.
    public static func build(workflows: [String]) -> Build? {
        var found: [Build] = []
        for text in workflows {
            let lower = text.lowercased()
            guard deploys.contains(where: lower.contains) else { continue }
            let steps = lower.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            // A Jekyll build that also runs a script (for its stylesheets, say) is still a Jekyll site.
            if jekyll.contains(where: steps.contains) {
                found.append(.jekyll)
            } else if builders.contains(where: steps.contains) {
                found.append(.otherGenerator)
            } else {
                found.append(.filesAsIs)
            }
        }
        return [.jekyll, .otherGenerator, .filesAsIs].first(where: found.contains)
    }

    /// The workflows of the repository holding a site at `siteRoot`: its own `.github/workflows`, or the repository's
    /// when the site is in its `docs/` folder.
    public static func build(siteRoot: URL) -> Build? {
        var folders = [siteRoot.appending(path: ".github/workflows")]
        if siteRoot.lastPathComponent == "docs" { folders.append(siteRoot.deletingLastPathComponent().appending(path: ".github/workflows")) }
        let texts = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        return build(workflows: texts)
    }
}

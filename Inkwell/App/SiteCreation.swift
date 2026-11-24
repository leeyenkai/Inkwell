import Foundation
import InkwellKit

extension AppModel {
    /// Creates a new public repository with a starter site in the chosen theme, publishes it and turns on Pages.
    func createSite(name: String, title: String, theme: ThemeManifest) async {
        guard let client = account.client, let login = account.user?.login else { return }
        loadError = nil
        do {
            opening = String(localized: "Creating \(name) on GitHub…")
            let repo = try await client.createRepository(name: name, description: "\(title). Made with Inkwell.", isPrivate: false)
            let branch = repo.default_branch ?? "main"
            opening = String(localized: "Waiting for GitHub…")
            var ready = false
            for _ in 0 ..< 15 where !ready {
                ready = (try? await client.branchHead(login, name, branch: branch)) != nil
                if !ready { try await Task.sleep(for: .seconds(1)) }
            }
            let ref = SiteRef(owner: login, name: name, branch: branch)
            let copy = WorkingCopy(ref: ref, container: GitHubBackend.container)
            try await copy.download(client: client) { [weak self] message in await MainActor.run { self?.opening = message } }

            opening = String(localized: "Setting up \(theme.name)…")
            let isUserSite = name.lowercased() == "\(login.lowercased()).github.io"
            try writeStarterSite(at: copy.siteRoot, title: title, login: login, baseurl: isUserSite ? "" : "/\(name)")
            try ThemeApplier.plan(theme: theme, siteRoot: copy.siteRoot).apply(to: copy.siteRoot)

            opening = String(localized: "Publishing…")
            let paths = try await copy.changes().keys.sorted()
            _ = try await copy.publish(paths: paths, message: "Create site with Inkwell", client: client)
            opening = String(localized: "Turning on GitHub Pages…")
            var pagesOn = false
            for attempt in 0 ..< 3 where !pagesOn {
                do {
                    _ = try await client.enablePages(login, name, branch: branch)
                    pagesOn = true
                } catch GitHubError.http(status: 409, _) {
                    pagesOn = true
                } catch {
                    if attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
                }
            }
            pagesURL = URL(string: isUserSite ? "https://\(login).github.io/" : "https://\(login).github.io/\(name)/")
            await attach(GitHubBackend(copy: copy, client: client))
            showSitePicker = false
            await account.loadRepositories()
            if !pagesOn {
                errorMessage = String(localized: """
                    The site was created, but GitHub Pages could not be turned on. Turn it on in the repository’s settings on GitHub \
                    (Pages, deploy from the \(branch) branch).
                    """)
            }
        } catch {
            loadError = String(localized: "The site could not be created: \(error.localizedDescription)")
        }
        opening = nil
    }

    private func writeStarterSite(at root: URL, title: String, login: String, baseurl: String) throws {
        let today = Date()
        let files: [String: String] = [
            "_config.yml": """
            title: \(YAMLFormat.quoted(title))
            description: \(YAMLFormat.quoted("Notes and writing by \(login)."))
            author: \(YAMLFormat.quoted(account.user?.name ?? login))
            url: "https://\(login).github.io"
            baseurl: "\(baseurl)"
            timezone: \(TimeZone.current.identifier)
            permalink: pretty
            markdown: kramdown

            exclude:
              - README.md

            """,
            "index.md": "---\nlayout: home\ntitle: Home\n---\n\nHello. This is my new site. I write about the things I am working on and thinking about.\n",
            "about.md": "---\nlayout: page\ntitle: About\n---\n\nA few words about who you are and what this site is for.\n",
            "_posts/\(YAMLFormat.date(today))-hello-world.md": """
            ---
            title: "Hello, world"
            date: \(YAMLFormat.date(today))
            ---

            This is the first post on my new site. Edit it, or write a new one with ⌘N, then publish.

            """,
            "README.md": "# \(title)\n\nPublished with GitHub Pages and written with Inkwell.\n",
            ".gitignore": "_site/\n.jekyll-cache/\n.sass-cache/\n.DS_Store\n",
        ]
        for (path, text) in files {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        }
    }
}

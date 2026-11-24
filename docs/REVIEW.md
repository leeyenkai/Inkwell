# Review of the Inkwell proposal (v0.1)

*24 Nov 2026. Reviewed against the site the proposal grew out of, `leeyenkai.github.io` (Jekyll on GitHub Pages). The revised proposal is [SPEC.md](SPEC.md).*

## Summary

The proposal is sound. The problem it names is real and shows up in the site's own history: of 28 commits, four are "published estonia draft again" and three are "romney". The core principles hold up: the repo is the source of truth, Markdown stays clean, drafts stay private and git is hidden. The main changes are the platform (a native Mac app, not Tauri), a more honest plan for the instant preview, and an MVP small enough to build. Each change below gives the evidence from the site and what was done about it.

## What the proposal gets right

- **Source-preserving editing.** Editing the raw Markdown and only styling it is the right call. The site's posts use quirks a rich-text editor would rewrite: `\-` escapes, `>*…*` quotes without a space, blank lines between separate quotes (`_sidenotes/2026-03-28-romney.md`) and Liquid inside image links. The MVP opens and saves every file byte for byte (tested).
- **Inferred properties.** The fields really do vary within a section. Notes have `title`, `date` and `published: true`, and only one of the two has `byline`. Inference gives new notes `title`, `date` and `published`, with `byline` as optional, which is what a person would do by hand.
- **Local drafts.** The repo is public and the README already warns that `published: false` files are visible on GitHub. Keeping drafts outside the repo until publish is the only real fix.
- **Photos as a collection.** `photos.md` is an empty block of hand-written HTML with a comment explaining the format. "Set up Photos" with one file per photo is a good first adoption step.
- **Section inference from navigation.** `_data/navigation.yml` lists exactly the five sections in order, so the sidebar can follow it with no config file.

## Changes

### 1. Platform: native Mac app, not Tauri

*Issue.* The proposal picks Tauri 2 for cross-platform reach, with CodeMirror, libgit2, libvips and SQLite. The product is a Mac app, though, and its main comparison is Apple Notes.

*Change.* Swift 6 and SwiftUI on macOS 26, built the same way as MediaPull: no third-party Swift packages, a local `InkwellKit` package that also builds for iOS, and a Liquid Glass `.icon`. Each piece maps to a system framework:

| Proposal | Now |
|---|---|
| CodeMirror 6 live-preview editor | TextKit 2 `NSTextView` over the raw Markdown, styled with attributes only |
| Preview webview | `WKWebView` with a scheme handler that serves the site's own files |
| libvips | ImageIO (HEIC/RAW decode, resize, orientation, metadata removal) |
| libgit2 | The person's own `git`, run with `Process`, so existing credentials work |
| SQLite + FTS5 | Not needed yet: personal sites have dozens of posts, and search reads the files |
| Windows / Linux / Android / web | Dropped. iOS stays cheap through the shared package |

### 2. The instant preview needs its own Liquid and kramdown

*Issue.* Swift has no Liquid library and no kramdown. The proposal's "~95% fidelity" figure has nothing behind it.

*Evidence.* The site's templates use `{% seo %}`, `for … reversed`, `assign`, `contains`, `sort: 'date'`, `where_exp`, `concat`, `prepend` and the `date`, `date_to_xmlschema`, `relative_url`, `strip_html` and `truncatewords` filters. Its posts use footnotes, smart quotes, `####` inside quotes and `***` rules.

*Change.* `InkwellTemplate` implements the Liquid subset Jekyll themes use and reports tags it does not run, and the preview marks itself "Approximate" when there are any. `InkwellMarkdown` follows kramdown with GitHub Pages' GFM input: auto heading ids, footnotes with kramdown's markup, typographic quotes and dashes, tables, task lists and pass-through HTML blocks. Both are tested against the site's own layouts. Fidelity claims should come from diffing against real builds, which is in the roadmap.

### 3. Exact preview costs more than stated

*Issue.* The Mac's system Ruby is 2.6.10, which is too old for the current `github-pages` gem, so "Exact" means shipping a portable Ruby (tens of MB), not just downloading a gem.

*Change.* Exact preview stays in v1.0 as a lazy download. The open question about moving sites to an Actions build matters more now, because that build would also run in the preview.

### 4. Build status needs no sign-in

*Issue.* The proposal watches the Pages build through an authenticated GitHub App.

*Change.* GitHub Pages builds now run as the `pages-build-deployment` workflow. For a public repo, `GET /repos/{owner}/{repo}/actions/runs?head_sha=…` works without a token. The MVP publishes with the person's existing git credentials and watches that endpoint. Device-flow sign-in moves to v1.0, where creating repos and private sites need it.

### 5. Corrections from the real site

- **Feed.** The site already has a hand-written `feed.xml` (Atom, covering notes, sidenotes and travel). Site health must detect it and not suggest `jekyll-feed`, which would produce a second feed.
- **`published: true` is explicit.** Every post sets it. Inference keeps writing it for new posts, and the editor never drops it.
- **`published: false` means a public draft.** The publish checklist warns that the file will be public even though the page is hidden.
- **URLs come from filenames.** `permalink: /:collection/:title/` makes the URL slug the filename slug (`2026-06-20-morality.md` → `/notes/morality/`), not the title. A draft's filename follows its title until it is published, and after that it stays put so the URL never changes by accident.
- **The site is dark only.** `style.css` defines `--bg-color` and friends with no light variant, which suits the Design panel's "add light mode" offer.
- **Travel is empty**, and its index uses `post.excerpt | strip_html | truncatewords: 30`, so excerpts must render.
- **`_site/` is gitignored.** It exists locally and can be stale, and the preview must never read from it.

### 6. Scope realism

*Issue.* The 8–10 week MVP includes inline image rendering, hidden syntax markers, a slash menu, scheduled posts and the full formatting table.

*Change.* The MVP dims syntax markers rather than hiding them, as Bear does. That is the riskiest part of a TextKit editor, and dimming keeps the text exact while still reading cleanly. Images show as a styled line in the editor, with the picture itself in the preview. The slash menu, inline images and scheduling move to v1.0. What was built is listed under "Implementation status" in the spec.

### 7. Gaps the proposal did not cover

- **A dirty working copy.** If the clone has unrelated uncommitted changes, publish must not sweep them in. Inkwell commits only the paths it names (`git commit --only`), stashes other changes while it rebases on remote changes, and the self-test checks this.
- **Liquid chips.** "Chips that can't be edited by accident" needs a rule. A chip can be selected and deleted whole, but not edited from inside, except in Source view.
- **Testing without touching the real site.** Automated tests use a synthetic fixture site. Manual runs use `scripts/make-sample-site.sh`, a fresh clone whose `origin` is a local bare repo, and the publish self-test refuses to run against a GitHub remote.
- **Accessibility.** Status dots need labels as well as colour (done), and the title, text and preview have accessibility labels.
- **Undo.** Every formatting command is one undo step, and a publish can be reverted by a new commit (v1.0 version history).

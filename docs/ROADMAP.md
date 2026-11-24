# Inkwell roadmap to 1.0

*Approved 24 Nov 2026. The audit, the feature brainstorm and the milestone plan. [SPEC.md](SPEC.md) is updated as each milestone lands.*


## Context

Inkwell (repo `leeyenkai/Inkwell`, `~/Desktop/Github+MiscDocs/Inkwell`) is a working MVP: a SwiftUI Mac app plus the `InkwellKit` package, which together open a local Jekyll clone, edit Markdown with live styling, preview through the site's layouts, and publish with the system `git`. It only works on a developer's Mac. It needs git, a local clone and a folder the app can reach (which triggered a Desktop privacy prompt), and it has no sign-in, no site design, and no way to rename, delete or unpublish.

Goal: someone downloads Inkwell, signs in with GitHub, picks or creates their Pages site, and does everything in the app: design the site, write, edit, manage media and publish.

Decisions made with the user:
- **Sync through the GitHub API.** Inkwell signs in with GitHub and keeps its own copy of the site in its container, so users need no git, Terminal or local clone. The current git mode stays as "Advanced: use a local folder".
- **Unsigned distribution for now** (ad-hoc signed DMG on GitHub Releases). Notarization can come later without code changes.
- **Themes and a design panel** for 1.0: bundled Inkwell themes plus editing of existing themes, with a code editor as the escape hatch. No drag-and-drop page builder.
- **The icon is redone properly as Liquid Glass** (Icon Composer layers), and the user picks from rendered options.

This plan becomes `docs/ROADMAP.md`, and the relevant parts are folded into `docs/SPEC.md` (v0.3) as each milestone lands.

---

## Progress (24 Nov 2026)

- **M0 Icon: done.** The ink-roller Liquid Glass icon (four groups, the most Xcode allows), checked in every appearance with `ictool`.
- **M1 Foundation: mostly done.**
  - Done: sign-in with a personal token, with device flow ready for an OAuth client ID; site picker; Pages-aware download into Application Support; one-commit publishing through the GitHub API; pull with conflicts (Keep mine / Use GitHub’s / Compare); "Unpublished changes" sheet; delete, unpublish and discard; build status through the signed-in account; "New site" (creates the repository, applies a theme, publishes, turns on Pages); local-folder mode hardened (timeouts, rebase abort, push again).
  - Audit fixes done: CRLF/BOM, wrapped YAML, permalink styles and `_posts`, time zone, Pages section, repo-keyed drafts, `site.baseurl` images and preview, IME guard, undo across Liquid chips, stable editor identity, disk reload with conflict banner, no saving after a failed load, no ghost drafts, preview, search and image import off the main thread.
  - Verified live against the private throwaway `leeyenkai/inkwell-publish-test`: seeding a site with a binary file, an edit made on GitHub being picked up during a publish, a real conflict resolved with Keep mine, and deletion. A fresh download matches exactly. This run found and fixed a stale-branch-head bug (HTTP caching of the ref).
  - Left: the OAuth App client ID (from the user). Incremental restyling for long posts landed in M4. App Sandbox is deferred: the local-folder mode needs the user’s own git configuration and credential helpers, which the sandbox blocks. GitHub mode keeps everything in Application Support and is sandbox-ready.
- **M2 Content: done.**
  - Content: rename or move a post (one change; the old address keeps working through `redirect_from`, and links in other posts are rewritten), duplicate into a draft, new pages (optionally added to the menu), a Tags list with rename, merge and remove across every post, and version history from GitHub with a diff and "Restore This Version".
  - Editor: Markdown markers hidden off the line being edited; lists, checklists and quotes continue on Return, Tab nests them; a slash menu; `[[` links to other posts; rich-text paste becomes Markdown; YouTube and Vimeo embeds.
  - Inline images: a picture on a line of its own shows under that line, scaled to the column and at most 320 points high. The space is paragraph spacing, so the file is unchanged.
  - Tables: Format > Table… (⇧⌘T), the slash menu, the right-click menu or the Edit Table button beside the table under the cursor open a grid. You can type in cells, add, move and delete rows and columns, and set each column's alignment. The table goes back as aligned Markdown in one undo step, and tables show in a monospaced face so the columns stay lined up.
  - Photos: a photo stream with one small file per photo in `_photos/`, listed newest first by a Liquid loop on the photos page. "Set Up Photos" reviews the change and moves hand-written photos out of the old page. Grid, caption, alt text, place, date, hide and delete; "Add Photos…" imports a batch (dated from the camera) and asks for captions one at a time.
  - Media: several pictures dropped into a post become a gallery after alt text for each. The Media library shows every image, where it is used and its size, filters unused ones, replaces a picture in place (every link keeps working) and deletes.
  - Scheduled posts: a future date shows as Scheduled and the publish button reads Schedule. The date can carry a time of day. An optional hourly workflow (`.github/workflows/inkwell-scheduled.yml`, added in the same commit) asks GitHub Pages to rebuild when a post comes due; `future: true` is respected. The due-check was tested locally with a date shim; the workflow itself has not yet run on GitHub, and sites built by their own Actions workflow need that workflow to run on a schedule instead.
  - Checked by `--selftest-content` (move and publish, history, duplicate, page, tags, photo setup and import, the rendered photos page, the media library, a scheduled post with its workflow in one commit, an inline image, and a table edit undone in one step). The self-test also found and fixed a race in local-folder mode: a background `git status` could hold the index lock during a publish.
- **M5 Release: built, waiting on a public release location and testers.**
  - Version 0.9.0. `scripts/make-dmg.sh` builds the Release app (ad-hoc signed, hardened runtime), checks the signature and the bundled dart-sass (which is Developer ID signed and notarized by its makers), and packs a disk image with an Applications link and first-launch notes, plus its SHA-256. Steps: [RELEASING.md](RELEASING.md).
  - Update check: Inkwell › Check for Updates… and a daily check (Settings › General) read the latest release of `InkwellReleasesRepository` (Info.plist, now `leeyenkai/Inkwell`) and offer the disk image. A private repository answers 404, shown as "no updates", so releases need a public repository.
  - Privacy: [PRIVACY.md](PRIVACY.md) and a Privacy topic in Help. README: download and the Open Anyway step.
  - Bug bash on first-use paths, all fixed:
    - Two crashes: `remote_theme: ""`, and `{{-}}` in a post.
    - A copy whose `state.json` could not be read was deleted on the next open; it is now kept beside the new download, and state from older builds still reads.
    - Tokens now ask for `repo` (GitHub needs it to read Pages settings). A failed Pages lookup is an error instead of a silent guess of the branch and folder; opening a repository without Pages says so; the live address survives a relaunch.
    - "New Site" no longer fails after the repository exists when Pages cannot be turned on; it says to turn Pages on.
    - The publish sheet no longer spins when no Pages build starts.
    - A fresh download is checked against GitHub's file list and any differing file is fetched on its own; repositories too large for one tree answer are refused.
    - Sites without `_config.yml` (GitHub Pages builds them) open; a site with no collections gets a Posts section for its first post.
    - Draft filenames use the site's time zone, so they match the `date:`; photo folders use the Gregorian year.
    - The scheduled-post workflow is offered only for sites at the repository root (workflows do not run from `/docs`).
    - Organisation repositories appear in the site picker.
  - Left: the OAuth App client ID (device-flow sign-in), a public release location, notarization (later), and a beta with a few people.
- **M4 Health & polish: done.**
  - Site health: a Health item with a problem count. It checks properties, duplicate addresses, empty or placeholder posts, internal links and images, alt text, large images and files, the Pages size budget, SEO tags, description, share image, feed, sitemap, favicon, 404 page, committed `_site` and `.DS_Store`, and `.gitignore`. Safe fixes are one click and become unpublished changes; hand-written feeds, sitemaps and head tags count, so nothing is added twice. "Check Links" asks linked sites whether pages are still there (only 404, 410 or a vanished domain counts). Comments and code blocks are skipped.
  - Per post: description, share image and a link-preview card under Properties; the publish checklist adds same-address files, images over 1 MB and long titles.
  - Settings window (General, Editor, Images, Account), Help window with guides and a shortcut list, a summary the first time a site opens, and Help › Copy Diagnostics with an error log in `~/Library/Logs/Inkwell` (messages only, never tokens).
  - Performance on a generated site of 600 posts and 300 images: load 0.2 s, health 0.3 s, media library 0.14 s (was 35 s), preview 0.45 s. Typing restyles only the edited paragraphs in long posts (debug build: 46 to 3 ms a keystroke at 15k characters, 452 to 14 ms at 150k), checked against a full restyle by the self-test.
  - Accessibility: tiles in the photo, media and theme grids are keyboard-choosable buttons with names; icon-only controls have spoken labels. Not yet checked with VoiceOver by a person.
  - Localisation-ready: every string a person reads comes from a string catalog, the app's `Inkwell/Resources/Localizable.xcstrings` and one per InkwellKit module (`localized(...)`, looked up in that module's bundle). Counts are whole sentences with plural forms in the catalog, including English's own singulars; theme labels go through a `Themes` table. `scripts/sync-strings.sh` refreshes the catalogs from the compiler's extracted strings. A run with `-NSSurroundLocalizedStrings YES` showed no unwrapped app text. Site content stays in English: commit messages, starter files, the 404 page and "Copy of" titles. Token labels made from a stylesheet's variable names are shown as they are. No translations yet.
- **M3 Site design: done.**
  - Engine: `InkwellDesign`, see [DESIGN-ENGINE.md](DESIGN-ENGINE.md).
  - UI: the Design section in the sidebar.
    - *Theme & Style:* the theme gallery with file-by-file review; colours (default plus a dark-mode or light-mode palette; "Add Dark Mode" or "Add Light Mode" starts from an inverted copy); fonts, sizes, width and radius; theme options.
    - *Sass themes:* for themes like minima, `$variables` are edited as overrides in the site's `assets/main.scss`.
    - *Navigation:* the menu editor.
    - *Settings:* site details, footer, share image, favicon, and a custom domain with HTTPS.
    - *Code:* layouts, includes, styles and data, with highlighting, live preview, theme files that can be copied in to override them, and "Revert to Published".
  - Preview:
    - The whole site can be browsed: links work, pages render through the theme, and it can show light or dark mode.
    - Gem themes (all GitHub Pages themes) and `remote_theme` are downloaded once and used for layouts, includes and Sass.
    - SCSS compiles with the bundled dart-sass 1.108.2 (pinned, SHA-256 checked, `scripts/fetch-engines.sh`).
    - GitHub Pages' default layouts (jekyll-default-layout) are applied.
  - Checked by `--selftest-design` and a live test that downloads and renders the real minima theme.

---

## Part 1: Audit of the MVP

(Filled in from the independent code audit and my own notes. Severity: **B** blocker for 1.0, **M** major, **m** minor.)

**Blocks normal users**
- **B** Needs `git` (`InkwellPublish/Git.swift` looks only in /opt/homebrew, /usr/local, /usr/bin; on a Mac without the command line tools, `/usr/bin/git` is a shim that pops an install dialog) and an existing local clone. No sign-in, clone or site creation.
- **B** Reads the user's folders directly. A site on the Desktop or in Documents triggers the privacy prompt, which blocked the main thread during the README run (`Launch.start` read a file synchronously on the main actor).
- **B** Build-status polling is unauthenticated: 60 requests an hour, but `PagesStatus.watch` polls every 5 s for up to 10 min (120 requests). It stops working halfway through a build.
- **B** Publish failure path: if `push` fails after the local commit, the draft file is kept *and* the post is committed locally, so the next publish fails with "already exists" (`PublishSession.publish`).

**Correctness / data safety**
- **M** `InkwellTextView.restyle()` resets every attribute on each keystroke, including while an input method has marked text, which can break CJK/accent input. It also restyles the whole document, so long posts slow down.
- **M** The Liquid chip guard in `shouldChangeText` can also block undo/redo that touches a chip, and paste over a selection that half-covers one.
- **M** A draft's file is renamed on every save while the title changes. Its id is path-based, so selection and the list jump about (`EditorDocument.renameDraftIfNeeded` / `AppModel.draftRenamed`).
- **M** Published-post edits are written straight into the working tree, with no version kept in the app. There is no revert, and no protection if the file changes on disk (no file presenter).
- **M** `PreviewBuilder` builds the site object once per load: index pages don't reflect edits, and rendering runs on the main actor.
- **M** Search reads every file from disk on every keystroke, on the main actor.
- **M** Permalinks ignore the `timezone:` config and permalink styles (`pretty`, `date`), so `_posts` URLs are wrong.
- **m** Only the first of several dropped images is imported. Pages have no editable title or properties. The Photos section just opens the raw `photos.md`.
- **m** The YAML subset has no anchors or multi-line flow, and the kramdown renderer has no IAL attributes, definition lists, abbreviations or syntax highlighting.

**From the independent audit (not already listed above)**
- **B** A conflict during `pull --rebase --autostash` leaves the repo mid-rebase, possibly with conflict markers, because there is no `rebase --abort` (`Git.swift:146`). Every later publish fails.
- **B** Unpushed local commits are invisible: `AppModel.status` can't show "committed, not pushed", and there is no Push/Retry action.
- **B** You can't delete, unpublish or rename published posts, or discard unpublished edits.
- **M** Cleanup after a failed commit never runs, because `git add --all` has already staged the file, so the `.untracked` check never matches (`PublishSession.swift:163`). A missing `user.email` leaves the draft staged.
- **M** Nothing watches files on disk. `EditorDocument` saves its in-memory copy over changes made outside the app, including ones the rebase just pulled in. A failed read opens an empty editor that then saves over the file.
- **M** Edits made while the publish sheet is open are written back to the deleted draft path (`adoptPublished` → `select` → `saveNow`), which recreates it as a ghost draft.
- **M** A CRLF closing `---\r` or a leading BOM isn't recognised as front matter, so the first edit adds a second block (`FrontMatter.swift:15`). A plain value that wraps onto the next line stops `YAML.parseMap`, and the keys after it vanish.
- **M** The editor is keyed on `document.id`, so a draft rename rebuilds the text view and loses selection, undo and IME state (`EditorView.swift:22`).
- **M** The default `_posts` permalink is wrong, so URLs, the link check and "Open Post" are wrong on minima-style blogs. Built-in permalink styles and `:categories` aren't expanded.
- **M** Images written with `{{ site.baseurl }}` or as relative paths aren't committed, and there is no warning.
- **M** Sites served from `/docs` mix up repo-root and site-root paths, so edits are never detected.
- **M** Build status: any non-200 counts as finished (404 on private repos, 403 at the rate limit), and the build match is case-sensitive and falls back to `runs.first`.
- **M** Preview: gem and `remote_theme` themes aren't loaded, SCSS isn't compiled, `baseurl` isn't stripped (project sites 404), `site.posts` is empty and sorted oldest first, and the `post_url`, `link` and `highlight` tags are missing.
- **M** Pages appear only if they are in the navigation, collections without `output` are hidden, and `_drafts` is ignored. On a minima site that leaves only Posts.
- **M** Drafts are keyed by the clone's path, so moving the folder hides them.
- **M** Performance: opening the site renders every post on the main thread; each autosave runs `git status` and a full `git log`; each selection re-reads the section to infer fields; HEIC/RAW import runs on the main thread; the scheme handler reads files on the main thread.
- **m** Git commands have no timeout, so a passphrase prompt hangs the publish. `git log` without `-z` mangles non-ASCII paths. Unused imported images are never cleaned up. Photos dragged from the Photos app (file promises) aren't handled.

**What holds up:** byte-preserving front matter edits, the kramdown/Liquid core, image metadata stripping, and committing only named paths. These are tested and reusable as they are.

**Consequence for the plan:** most of the git-path bugs disappear with the API sync engine (M1). The rest go on M1's bug list: file watching and reload, CRLF/BOM, wrapped YAML values, IME guard, stable editor identity, `_posts` permalinks, `baseurl` in preview, `/docs` sites, and moving heavy work off the main thread.

---

## Part 2: Feature brainstorm

Grouped by area. ★ = in 1.0, ☆ = 1.x / later, ✗ = considered and rejected (reason given).

**Account & onboarding**
- ★ Sign in with GitHub (device flow, token in Keychain), sign out, switch account
- ★ Site picker: repos with Pages, `*.github.io` first; shows Pages status, domain, last build
- ★ "Create a new site" wizard: name → theme → about text → creates `<login>.github.io`, enables Pages, first publish
- ★ Site summary on first open (sections, posts, images, health issues) + optional adoption steps
- ★ Multiple sites, recent sites, per-site window
- ☆ Import: Medium / Substack / WordPress export, Apple Notes, Markdown folder, Ghost
- ✗ Email/password accounts (no server; GitHub is the account)

**Writing**
- ★ Hide Markdown markers off the current line (TextKit 2 fragment rendering), keep exact source
- ★ Inline images in the editor (attachment views over the image line, source unchanged)
- ★ Slash menu (`/` → heading, quote, list, table, image, divider, footnote, embed, code, aside, math)
- ★ Tables with a grid editor; code blocks with language picker and highlighting; embeds (YouTube/Vimeo/links → site include or iframe)
- ★ Smart typing: auto-pair `**`, list continuation on Return, indent/outdent lists, paste-as-Markdown from rich text (HTML → Markdown converter)
- ★ Focus mode, typewriter scrolling, outline pane, word goals, reading time
- ★ Internal links: `[[` picker → real URL; backlinks; rename updates links
- ★ Find & replace across the site
- ☆ Grammar/style hints (system), "copy as rich text", read-aloud
- ☆ AI assist (title ideas, alt text from image via on-device Vision, summary for meta description). Alt text suggestion via Vision ★ (on-device, no server)
- ✗ Real-time collaboration (no server; git history is the collaboration model)

**Content management**
- ★ Rename (title/slug with optional redirect), duplicate, delete (to Trash/commit), unpublish (back to draft), move between sections
- ★ Pages: create/edit/delete standalone pages (About, Now, Contact) with page templates
- ★ Bulk actions in the list; sort/filter by status, tag, date; pin posts
- ★ Tags/categories with autocomplete and a tag manager (rename/merge across posts)
- ★ Scheduled posts: `date` in the future + bundled Actions workflow that publishes on time
- ★ Version history per post from commits (via API), diff, restore as a new commit
- ★ Drafts sync across the user's Macs via a private `<site>-drafts` repo (opt-in) ; ☆ iCloud
- ☆ Series / collections of posts, "Now" page helper, link-blog post type

**Media**
- ★ Multiple images at once, galleries (grid include), widths (inline/wide/full) when the theme supports them
- ★ Media library: grid of all site media, where-used, unused files, replace image everywhere, delete unused
- ★ Alt-text checker; on-device alt-text suggestion
- ★ Storage meter (repo and Pages limits), warnings > 25 MB, video → embed suggestion
- ★ Photos section (spec §4.5): one file per photo, grid/stream views, batch import with caption screen, albums, reorder; "Set up Photos" adoption for hand-HTML photo pages like `photos.md`
- ☆ Import from Photos library picker (PhotosUI), responsive image sizes, external storage (S3/R2)

**Site design (all in-app)**
- ★ Theme gallery: 4–6 bundled Inkwell themes (Essayist, Notebook, Photo journal, Minimal, Magazine) written in plain CSS with design tokens (CSS custom properties) so every option is editable; apply to a new or existing site as a reviewable change
- ★ Design panel: colours (light + dark palettes), fonts (system stacks + bundled/hosted web fonts), sizes and spacing scale, content width, header style, homepage layout (list, cards, chain, photo grid), post layout options (byline, date format, reading time, footnotes style)
- ★ Navigation editor (reorder, rename, add page/section/link) writing `_data/navigation.yml` (adopts hard-coded navs via adoption diff)
- ★ Site settings form for `_config.yml`: title, description, author, avatar, social links, language, timezone, permalink style, date format, footer text, email obfuscation
- ★ Favicon & social card generator (from emoji, letter or image; writes favicon.svg/png, apple-touch-icon, `og:image`)
- ★ Custom domain wizard: writes `CNAME`, shows DNS records, sets cname + enforces HTTPS via Pages API, checks DNS
- ★ Code editor (layouts, includes, CSS/SCSS, config) with syntax highlighting, live preview, revert to published
- ★ Existing themes: detect CSS variables and expose them (as for leeyenkai.github.io); support `theme:`/`remote_theme:` by fetching theme files for preview; compile SCSS (bundled `dart-sass` binary, pinned + SHA-256 like MediaPull's engines)
- ★ Light/dark: offer to add `prefers-color-scheme` to a dark-only site (adoption diff)
- ☆ Comments (giscus), analytics (GoatCounter/Plausible snippet), newsletter (RSS-to-email link), search page (lunr)
- ✗ Drag-and-drop page builder (breaks "plain files", huge scope — user agreed)

**Preview**
- ★ Whole-site preview browser (navigate the site locally, drafts badged), device sizes, light/dark
- ★ Fidelity: SCSS, theme files, `include` with params, `jekyll-seo-tag` output, `site.posts`/`_posts`, pagination basics, kramdown IAL/attributes, syntax highlighting (Rouge-compatible classes)
- ★ "Approximate" badge listing unsupported tags; fidelity golden tests against real GitHub Pages output of the bundled themes
- ☆ Exact preview (bundled Ruby + `github-pages`), or move sites to an Actions build so a bundled Jekyll matches exactly

**Publishing & sync**
- ★ Publish/update via Git Data API: one atomic commit (post + images + changed design files), message editable
- ★ "Publish all changes" review sheet (grouped: posts, pages, design, media) with per-item include/exclude
- ★ Pull remote changes automatically (on open, on focus, every few minutes); non-overlapping changes merge silently; overlapping → Keep mine / Keep theirs / Compare (3-way text merge for Markdown)
- ★ Build status with authenticated API (no rate-limit problem), plain-language build errors with the failing file/line and a "fix" jump
- ★ Offline mode: everything works offline; publish queues until online
- ★ Undo a publish (revert commit)
- ☆ Pull-request mode for teams; branch previews via Actions + a preview subdomain

**Health & quality**
- ★ Site health panel (spec §4.11) with one-click fixes, respecting existing feed/sitemap
- ★ Pre-publish checks: broken links/images, missing alt text, oversized images, front matter, duplicate URLs, GPS data
- ★ SEO panel per post: title length, description, social preview card mock
- ☆ External link checker (weekly), accessibility contrast checker for theme colours

**App quality**
- ★ First-run walkthrough; empty states; Help menu with guides; keyboard shortcut sheet
- ★ Settings: account, default section, image max size/quality, metadata stripping, smart quotes, editor font/size, autosave
- ★ Update check against GitHub Releases (manual download for unsigned builds)
- ★ Crash/error log viewer + "Copy diagnostics"; no telemetry
- ★ Accessibility (VoiceOver labels, keyboard-only flows, Dynamic Type-like font scaling), localisation-ready strings
- ☆ iOS/iPadOS capture app sharing InkwellKit

---

## Part 3: 1.0 plan

### Architecture changes

1. **GitHub client** — new `InkwellGitHub` module (URLSession only):
   - `DeviceFlowAuth` (OAuth device flow: `POST /login/device/code`, poll `/login/oauth/access_token`), token in Keychain (`TokenStore`), scopes `public_repo workflow` (ask for `repo` only when the user picks a private repo).
   - **Prerequisite for the user:** register an OAuth App named Inkwell on GitHub (device flow enabled) and give me its client ID. No client secret is needed for device flow. Until then a "Use a personal access token" field is the fallback.
   - `GitHubAPI`: repos, branches, contents, trees/blobs/commits/refs, compare, Pages (`GET/POST/PUT /repos/{o}/{r}/pages`, builds, health check), Actions runs, user repos create, rate-limit aware with ETags.
2. **Sync engine** — new `InkwellSync` module replacing `Git` as the default:
   - Working copy in `~/Library/Containers/…/Application Support/Inkwell/Sites/<owner>/<repo>/` (no Desktop access, sandbox-friendly). Initial download via tarball endpoint, extracted with `/usr/bin/tar`.
   - `SyncState` (`.inkwell-state.json` beside the copy): base commit SHA, base tree, per-path git blob SHA (computed locally with SHA-1 of `blob <len>\0` + bytes via CryptoKit `Insecure.SHA1`).
   - `ChangeSet`: local vs base (added/modified/deleted). Drives list status (✎), publish sheets and conflict detection.
   - `Publisher`: blobs → tree (base_tree) → commit → `PATCH refs/heads/<branch>` (no force). On non-fast-forward: `compare` base…head, auto-rebase when paths don't overlap, otherwise conflict sheet.
   - `Puller`: polls branch head with ETag; downloads changed files; applies where not locally modified.
   - `LocalGitBackend`: today's `InkwellPublish/Git.swift` behind the same `SiteBackend` protocol (advanced mode).
3. **Site model** — `SiteLoader` keeps working on the working copy; add `_posts` support, `timezone`, permalink styles (`pretty`, `date`, `ordinal`, `none`), collections without nav, pages anywhere, theme resolution (`theme:`/`remote_theme:` → cached theme files), `.inkwell.yml` overrides.
4. **Sandbox + entitlements**: App Sandbox, outgoing network, user-selected read-only files (image import), app-scope bookmarks for advanced local-folder mode. Ad-hoc signing; `scripts/make-dmg.sh` builds an unsigned DMG with a "first launch" note.
5. **Preview** — `PreviewBuilder` gains theme file lookup chain (site → theme cache), SCSS via bundled `dart-sass` (Process; pinned + checksummed by `scripts/fetch-engines.sh`), incremental site object updates when posts change, rendering off the main actor (make `PreviewBuilder` an actor), `SitePreviewServer` scheme handler serving whole-site navigation.
6. **Design system** — new `InkwellDesign` module: `ThemeManifest` (bundled themes as resources: layouts, includes, CSS with tokens, `theme.json` describing tokens/options), `TokenEditor` (reads/writes CSS custom properties in a `:root{}` block, line-preserving like front matter), `ConfigEditor` (line-preserving `_config.yml` edits reusing `FrontMatterDocument`-style span editing), `NavigationEditor`, `AdoptionPlan` (proposed changes with diffs).

### Milestones (each ends with tests green, self-test extended, screenshots refreshed)

- **M0 Icon: concept C "Ink roller" (chosen by the user after the mockups).** Rebuild `Inkwell/Resources/AppIcon.icon` as a proper Icon Composer document in MediaPull's format (`icon.json` + SVG layers):
  - Background: an indigo gradient fill, with light and dark specializations as in MediaPull.
  - Groups, back to front:
    1. **Page**: a tilted frosted white sheet with two short grey text bars.
    2. **Ink band**: a cyan→violet band across the page, a little translucent so it reads as ink on paper.
    3. **Roller**: a glass cylinder with a violet ink core and a light handle arm.
    4. **Grip**: the warm `#FFD98A→#FF8A5C` handle, MediaPull's warm accent.
  - Shapes are flat with no painted shadows or highlights, since the system adds specular, refraction and shadow per group. Strokes stay at least 40 units thick on the 1024 grid, and the main shapes sit in the centre safe area.
  - Translucency, shadow and specular are set per group in `icon.json`. Dark, clear and tinted appearances are checked.
  - Render with `ictool Inkwell/Resources/AppIcon.icon --export-image --platform macOS --rendition {Default,Dark,ClearLight,ClearDark,TintedLight,TintedDark} --width 1024 --height 1024 --scale 1` into a contact sheet, plus 16/32/64 px.
  - **Show the contact sheet to the user and iterate before anything else lands.** Then update `docs/images/icon.png` from the Default render and refresh the README.
- **M1 Foundation: sign in, sync, publish without git.** `InkwellGitHub`, `InkwellSync`, onboarding (welcome → sign in → pick/create site → download → summary), sandbox, Pages status/settings, publish via API, pull + conflicts, offline queue, advanced local-folder mode (with `rebase --abort` on conflict, git timeouts, and Push/Retry for unpushed commits). Fixes from the audit: file watching and reload (`NSFilePresenter`) with no blind overwrites; CRLF/BOM front matter; wrapped YAML values; IME `hasMarkedText` guard and incremental restyle; a stable editor identity across draft renames (key on a draft UUID kept in DraftStore metadata, not the path); `_posts` and built-in permalink styles; `baseurl` in the preview; sites served from `/docs` (site root ≠ repo root); `{{ site.baseurl }}` and relative image paths; drafts keyed by `owner/repo`; preview, search, import and site loading moved off the main actor; delete/unpublish/rename/discard edits (pulled forward from M2 because they block real use).
- **M2 Content complete.** Rename/delete/unpublish/duplicate/move, pages CRUD, tags manager, version history + restore, scheduled posts, multi-image/galleries, media library, Photos section, editor upgrades (hidden markers, inline images, slash menu, tables, smart typing, paste-as-Markdown, internal links), site-wide search index.
- **M3 Site design.** Theme gallery + apply, design panel (tokens, fonts, layout options, light/dark), navigation editor, settings form, favicon/social card, custom domain wizard, code editor, existing-theme support (tokens, SCSS, remote themes), whole-site preview, "Create a new site" wizard using the themes.
- **M4 Health & polish.** Site health + SEO + pre-publish checks, settings window, walkthrough, help, diagnostics, accessibility pass, performance pass (hundreds of posts/images), localisation-ready strings.
- **M5 Release.** Release build, DMG, update checker (needs a public releases location — the repo is private), README/website, privacy note, beta with a few users, bug bash.

### Critical files

- New: `InkwellKit/Sources/InkwellGitHub/*`, `InkwellSync/*`, `InkwellDesign/*`; `Inkwell/Features/Onboarding/*`, `Design/*`, `Media/*`, `History/*`, `Settings/*`; `Inkwell/Resources/Themes/*`; `scripts/fetch-engines.sh`, `make-dmg.sh`; `Config/Inkwell.entitlements`.
- Changed: `AppModel.swift` (split into `SiteSession` per window + `AccountModel`), `PublishSession.swift` (backend-agnostic), `EditorDocument.swift`, `InkwellTextView.swift`, `PreviewBuilder.swift` (actor, theme chain), `SiteLoader`/`Permalink` (`InkwellCore/Site.swift`), `DraftStore.swift`, `Inkwell.xcodeproj` (entitlements, resources), docs.
- Reused as-is: `FrontMatterDocument` span editing (pattern for config/CSS token editing), `Formatting`, `MarkdownScanner`, `MarkdownRenderer`, `LiquidTemplate`, `ImageImport`, `Validation`, `SchemaInference`, `PagesStatus` (with a token).

### Risks / open items

- OAuth App registration and its client ID come from the user. Without it only the token fallback works.
- Unsigned builds: macOS makes users approve the app in System Settings → Privacy & Security on first launch, and Keychain may ask again after each update (the signature changes). The README must walk users through it. Notarization removes both later.
- Releases from a private repo are not downloadable by the public. Updates need the repo (or a separate releases repo) to be public.
- Preview fidelity for arbitrary third-party themes stays approximate. Bundled themes are tested to match GitHub Pages output.
- Scope: M1–M3 are large. Each milestone is shippable on its own, and M1 alone already makes the app usable by others.

---

## Verification

- `swift test` per module: device-flow parsing (recorded fixtures), blob SHA vs `git hash-object`, tree/commit building, rebase/conflict cases, tarball extraction, token/CSS/config span edits (byte-identical round trips), theme application diffs, Liquid/SCSS fidelity golden files.
- No live GitHub in automated tests: `URLProtocol` stub replaying recorded responses.
- Manual end-to-end per milestone against a **throwaway test repo** (e.g. `leeyenkai/inkwell-test.github.io` or a fresh project repo with Pages), never `leeyenkai.github.io`, unless the user asks: sign in → pick site → edit → publish → wait for live → pull a change made on github.com → conflict case.
- Self-tests extended (`--selftest-publish` against a stub server; `--selftest-design` applying a theme to the sample site and rendering every page).
- README screenshots regenerated with `scripts/readme/screenshots.sh`; icon renders with `ictool`.

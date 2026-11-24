# Inkwell: a notes-style editor for GitHub Pages sites

*Specification v0.2 (24 Nov 2026), revised from the v0.1 proposal after the review in [REVIEW.md](REVIEW.md). "Inkwell" is a working name.*

## Implementation status

[ROADMAP.md](ROADMAP.md) has the milestone plan and current progress. Working today:

- **Accounts and sites.** Sign in with GitHub (personal token now; device flow once an OAuth App client ID is set in `Info.plist` as `InkwellGitHubClientID`). Pick a repository; Inkwell downloads it into Application Support, building from the Pages source folder and branch. Create a new site from one of four themes. Advanced: open a local git clone.
- **Writing.** Sections from the navigation, collections, `_posts` and other pages; the live-styled Markdown editor and formatting commands; Properties with validation; images with metadata removed; the instant preview through the site's own layouts.
- **Publishing.** One commit per publish through the GitHub API, with exactly the post and its images. Update, delete, unpublish to drafts, discard changes, "publish all changes", automatic pulls with conflict resolution, and Pages build status.
- **Content.** Rename or move with redirects and link rewriting, duplicate, new pages, tags (rename, merge, remove), version history with restore, and scheduled posts (with an optional hourly rebuild workflow).
- **Editor.** Markers hidden off the current line, smart lists, a slash menu, `[[` post links, rich-text paste as Markdown, embeds, pictures shown inline, and a grid editor for tables.
- **Photos and media.** A photo stream with one file per photo and a caption screen for batch imports; galleries in posts; a media library with where-used, unused, replace and delete.
- **Health and polish.** Site health with one-click fixes and an on-request external link check; description, share image and link preview per post; a Settings window, Help with guides and shortcuts, a first-open site summary, and Copy Diagnostics. All text comes from string catalogs, ready for translation.
- **Release.** Version 0.9.0 as an ad-hoc signed disk image (`scripts/make-dmg.sh`), an update check against GitHub releases, and a privacy note.
- **Design.** Four bundled themes with a reviewable switch; colours (light and dark), fonts and layout for Inkwell themes and hand-made stylesheets; theme options; navigation; site settings, favicon, share image and custom domain; and a live preview of any page.

Verified by 110 package tests (including a fake GitHub server for sync and performance bounds on a 600-post site) and the publish, content and design self-tests. A read-only live test passed against the real `leeyenkai/leeyenkai.github.io` (download, no false changes, pull). A live write test passed against a private throwaway repository: publish, pull during publish, conflict, delete. Not yet checked by a person: typing with input methods, drag and drop from Photos, the scheduled-post workflow running on GitHub.

---

## 1. The problem

GitHub Pages is free, fast and permanent, and you own your content. Writing for it, though, feels like programming:

- Posts are Markdown files with YAML front matter that you type by hand. One misplaced quote breaks a title or drops a date, and nothing warns you.
- To add an image you copy the file into `assets/images/` by hand, then type out a path, often wrapped in Liquid (`{{ '/assets/images/x.jpg' | relative_url }}`).
- Adding a section ("Travel", "Photos") means touching 3–4 files: the config, the layout's nav, an index page and a folder.
- A real local preview needs Ruby/Jekyll installed, so most people push to see their changes. Their commit history fills up with "published draft again" ×3.
- On free accounts the repo is public, so a committed draft is a published draft.
- Photo pages turn into hand-written HTML blocks.

The result is that people write less. Writing a post should take as little effort as Apple Notes, and publishing it should take one click.

## 2. Product vision

> **Write like it's Apple Notes. Organise like it's Obsidian. Publish like it's Instagram. And your site stays plain files in your own GitHub repo.**

Principles:

1. **Your repo is the source of truth.** Inkwell reads and writes the files your site generator already uses. If you uninstall it, the site works exactly as before, with no lock-in and no proprietary format.
2. **Zero-config first.** The app infers sections, fields and conventions from the existing site. A config file is optional.
3. **Markdown stays clean.** Inkwell writes Markdown that looks hand-written, and opening and saving a file never rewrites lines you didn't touch.
4. **Git is hidden by default.** Users see *Draft → Preview → Publish*. Commits, pushes and branches happen behind those buttons, and power users can still see them. Publishing commits only the files it names, never other work in the folder.
5. **Drafts are private by default.** They are not committed to a public repo until you publish them.
6. **Safe by construction.** Inkwell validates front matter, checks links, catches path conflicts and strips GPS data from photos before anything goes live.

### Target users

- **Primary:** people with a personal GitHub Pages site (Jekyll first, then Hugo or plain HTML) who write essays, short notes and photo posts on a Mac, and who are comfortable enough to have set the site up but don't want to live in a text editor.
- **Secondary:** non-technical people who want a free personal site. Inkwell can create one from a template, so they never need to learn what Jekyll is.

## 3. Landscape (why build this)

| Tool | What it does well | Gap |
|---|---|---|
| Obsidian + git plugin | Great editor and live preview | Doesn't know about your site: no front matter UI, sections, image paths, site preview or Pages status |
| Decap CMS / TinaCMS | Git-based CMS | Web forms feel like admin panels; they need config files and an auth backend, and have no offline support |
| Pages CMS | Clean web UI over a GitHub repo | Config-driven and form-centric; no real preview or photo stream |
| VS Code + Front Matter extension | Powerful | It's still a code editor |
| Publii | Desktop static-site CMS | Uses its own generator, so it can't adopt an existing Pages repo |
| Notion / Apple Notes | Joyful writing | No path to your own site |

**Inkwell's position:** a local-first Mac app that adopts *any* existing GitHub Pages repo, edits it with a notes-app feel, previews it accurately and publishes it with one click. A first-class photo stream comes built in.

---

## 4. Core experience

### 4.1 Main window

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   yenkai.github.io ▾          🔍 Search          👁 Preview   Publish ▸│
├───────────────┬─────────────────────────┬──────────────────────────────────┤
│ SITE          │ Notes            ＋ New │  A politics of morality          │
│  🏠 About     │ ─────────────────────── │  ────────────────────────────    │
│  📝 Notes   3 │ ● A politics of mora…   │  ▸ Properties                    │
│  💬 Sidenotes │   Published · Jun 20    │    Byline   [               ]    │
│  ✈️ Travel  0 │ ○ What about Estonia?   │    Date     Jun 20, 2026         │
│  📷 Photos 24 │   Published · Dec 1     │    Tags     ethics, politics     │
│               │ ◐ Untitled draft        │                                  │
│ DRAFTS     2  │   Draft · edited 2h ago │  The Guinea-worm is a horrifying │
│ SCHEDULED  1  │                         │  parasite. Its lifecycle starts  │
│               │                         │  with someone unsuspectingly…    │
│ ⚙ Site design │                         │                                  │
│ 🩺 Site health│                         │  [ image: guinea-worm.jpg ]      │
│               │                         │   Caption: Carter Center, 1988   │
│ ✓ Synced      │                         │                                  │
└───────────────┴─────────────────────────┴──────────────────────────────────┘
```

The layout is three panes like Apple Notes: **Sections → item list → editor**, with the preview as an optional fourth pane. The sidebar lists sections in the order of the site's navigation. Each list row shows a status symbol with a text label: ○ published, ◐ draft (local) or not yet pushed, ✎ published with unpublished edits, and a crossed eye for files committed with `published: false`.

### 4.2 Writing: the editor

**Approach:** a *live-preview Markdown editor* (the Obsidian / Typora model) instead of a rich-text editor that converts to Markdown afterwards. It is a TextKit 2 text view over the raw file. Styling is attributes only, so the text is never changed by display.

- Markdown syntax is styled as you type: headings grow, bold is bold, quotes are indented and grey. In the MVP the markers stay visible but dimmed. Hiding them away from the line being edited is planned for v1.0, once it is proven not to disturb selection and undo.
- Every keystroke edits the actual Markdown source, so round-trips are lossless and diffs stay minimal. A rich-text editor serialises Markdown its own way, which rewrites the whole file on save and breaks Liquid tags.
- A **Source** toggle (⇧⌘E) shows the raw file, front matter included.
- Liquid tags (`{{ … }}`, `{% … %}`) display as small inline chips. A chip can be selected and deleted whole but not edited from inside, except in Source view.

**Formatting support** (menu, keyboard shortcuts, and Markdown typed directly; the `/` slash menu comes in v1.0):

| Feature | Shortcut / trigger | Output (Jekyll + kramdown GFM) |
|---|---|---|
| Bold | ⌘B, `**` | `**text**` |
| Italic | ⌘I, `*` | `*text*` |
| Underline | ⌘U | `<u>text</u>` (Markdown has no underline, so Inkwell writes inline HTML) |
| Strikethrough | ⇧⌘X, `~~` | `~~text~~` |
| Highlight | ⇧⌘H | `<mark>text</mark>` |
| Inline code | ⌘E | `` `code` `` |
| Link | ⌘K, paste URL over a selection | `[text](url)`; pasting a URL onto selected text links it |
| Headings H1–H4 | ⌘1–4 (⌘0 for body), `#` | `## Heading` |
| Quote / pull quote | ⌘', `>` | `> …` |
| Lists, checklists | ⇧⌘L, ⌥⌘L, `-`, `1.`, `[ ]` | standard |
| Footnote | ⇧⌘F | `[^1]` with `[^1]: …` appended at the end; numeric footnotes are renumbered in reading order |
| Section break | ⇧⌘↩ or `***` | `***`, never `---`, which can be confused with front matter |
| Table | `/table` (v1.0) | GFM table with a grid editor |
| Code block | ```` ``` ```` | fenced, with language picker (v1.0) |
| Callout / aside | `/aside` (v1.0) | an HTML/IAL block styled by the site, only if the site supports it |
| Math | `/math` (v1.0) | `$$…$$`, only if the site loads MathJax/KaTeX |
| Embed | paste a YouTube/Vimeo/tweet URL (v1.0) | the site's embed include, or an iframe |

**Dialect awareness.** Inkwell detects the Markdown engine (kramdown with GFM input on GitHub Pages; Goldmark for Hugo later) and only offers formatting that engine renders. Anything else falls back to safe inline HTML.

**Writing comforts:** word count and reading time (done), spelling from the OS (done), find bar (done); focus mode, typewriter scrolling, a smart-quotes toggle, an outline pane of headings, and "copy as rich text" in v1.0.

### 4.3 Properties (front matter without YAML)

A collapsible **Properties** panel under the title works like Notion properties:

- Fields are **inferred** per section by scanning existing files. If every note has `title`, `date` and `published`, new notes get those too, and fields only some files have (`byline`) are offered as optional.
- Typed widgets: text, date picker, tags, toggle; image picker and dropdown in v1.0.
- Validation as you type. The editor flags unbalanced quotes, invalid dates, a date that doesn't match the filename, and a filename date that isn't zero-padded.
- Empty optional fields are left out of the file. A blank byline is not written as `byline: ""`.
- Unknown fields stay intact and appear under the known ones, read-only.
- Editing a field rewrites only that field's line. Setting a field to the value it already has changes nothing.

The filename and slug are generated (`2026-06-20-a-politics-of-morality.md`), always zero-padded. The URL field shows the address the post will have (`yoursite.com/notes/a-politics-of-morality/`). For a draft, the filename follows the title until publishing. After that it stays fixed, because the site builds URLs from filenames.

### 4.4 Media: images, galleries, video

Adding media works like Apple Notes: **drag, paste or pick** (⇧⌘I).

When an image arrives, Inkwell:

1. Converts HEIC/RAW to JPEG (PNG with transparency stays PNG; GIF and SVG are copied as they are).
2. Resizes it to a configurable maximum (default 2400 px long edge) and compresses it. Responsive sizes come later, when the site has an include for them.
3. **Strips GPS and camera metadata** and turns the picture upright. Keeping camera and lens info will be an opt-in setting.
4. Names the file from the post slug plus a descriptor (`morality-guinea-worm.jpg`) instead of `IMG_4821.HEIC`.
5. Puts it in `assets/images/`, the site's convention. Per-year folders and Hugo page bundles come with those adapters.
6. Inserts correct Markdown, using `relative_url` so links don't break on project sites.
7. Asks for **alt text** and an optional **caption**.

In the MVP the editor shows the image as a styled line and the preview shows the picture. Inline images in the editor, widths and **gallery** blocks come in v1.0.

**Media library** (v1.x): a grid of all site media showing which posts use each file, flagging unused files, size and dimensions, with find-and-replace for images.

**Video and large files:** GitHub rejects files over 100 MB and Pages sites are capped at about 1 GB. Inkwell warns above 25 MB, suggests YouTube/Vimeo embeds, and can push originals to optional external storage (S3/R2) while committing only a web-sized version. A **storage meter** shows how close the repo is to its limits.

### 4.5 Photos: a first-class "showcase" section

Many personal sites want an Instagram-style photo stream next to their writing. Inkwell treats it as its own section type with its own UI.

**Data model.** There is one tiny file per photo in a `_photos/` collection, or the equivalent in Hugo:

```yaml
---
image: /assets/photos/2026/tallinn-old-town.jpg
caption: "Tallinn, the morning after the first snow"
date: 2026-01-14
location: Tallinn, Estonia     # optional, typed by you, never taken from GPS
album: estonia                 # optional
---
```

The photos page is generated by a Liquid loop rather than hand-edited HTML. If a site has no photo section, or has one built from hand-written HTML (as `photos.md` is today), Inkwell offers **"Set up Photos"**. This adds the collection, a grid/stream layout snippet and the nav entry, and shows a reviewable diff before applying it. See §4.7 on adopting a site.

**UI:**
- **Grid view** shows square thumbnails like a profile page. A **stream view** shows full-width photos with captions.
- **Batch import:** drop 20 photos at once. Dates come from EXIF, and you then go through a fast caption screen (photo on top, caption field below, Return for the next photo).
- Drag to reorder (writes a `weight` field), pin to top, group into albums, hide without deleting.
- Post from your phone (see §6) in two taps: pick a photo, write a caption, publish.

### 4.6 Sections & site structure

**Sections** are the site's content groups: Jekyll collections, Hugo sections or folders of pages. Inkwell infers them from the navigation file and the config and lets you manage them:

- **New section:** pick a type (Essays/Notes, Short posts/Sidenotes, Photo stream, Pages, Links). Inkwell creates the folder and config entry, an index page from a template, and a nav item, all as one reviewable change.
- **Rename, reorder, hide** sections. Reordering the sidebar reorders the site nav.
- **Section settings:** URL pattern, default fields, the sort order and how the section index looks (list, cards, or a "chain" of full posts like a sidenotes feed).
- **Pages:** standalone pages (About, Now, Contact) edited the same way as posts (done).
- **Moving posts between sections** is one drag. Inkwell offers to add a redirect so the old URL keeps working.

### 4.7 Editing the site itself

There are three layers, from safest to most powerful:

1. **Site settings** (form UI): site title, description, author, social links, favicon, default share image, footer text and email obfuscation.
2. **Design** (visual): Inkwell reads CSS custom properties (`--bg-color`, `--accent-color` …) and shows them as colour pickers and font selectors, with a live preview of the whole site. If the site only has a dark theme, it offers to add light mode and `prefers-color-scheme` support.
3. **Code** (advanced): a built-in code editor for layouts, includes and CSS, with live preview and the ability to revert to the last published version.

**Site adoption ("Make this site Inkwell-friendly").** Some features need small structural changes, such as moving a hard-coded nav into `_data/navigation.yml` or turning a photo page into a data loop. Inkwell never makes these silently. It proposes each one as a separate change with a plain-English explanation and a before/after diff. You can accept or skip each change, and features degrade gracefully when you skip.

### 4.8 Preview

Preview works on two tiers so it's fast *and* accurate:

| Tier | How | Speed | Fidelity |
|---|---|---|---|
| **Instant** (done) | The site's real layouts and CSS, rendered by Inkwell's own Liquid subset and a kramdown-compatible Markdown renderer, shown in a web view that serves the site's files | Updates as you type, keeping the scroll position | Good for typical personal sites. Template tags it does not run are listed, and the preview says "Approximate" |
| **Exact** (v1.0) | A true build: Hugo ships as a single binary; Jekyll needs a portable Ruby (the system Ruby 2.6 is too old for `github-pages`), downloaded on first use | Seconds | Matches GitHub Pages exactly |

- Preview a single post in place (done), or **browse the whole site** in the preview pane, with drafts included and badged (v1.0).
- Width toggle: desktop / phone (done). Light / dark when the site supports both.
- **Share a draft:** generate a private, expiring preview link (optional hosted feature, §8) so a friend can read before you publish.

### 4.9 Drafts, publishing and history

**Lifecycle:** `Draft → (Scheduled) → Published → (Edited → Updated) → (Unpublished)`

- **Drafts live locally by default** in `~/Library/Application Support/Inkwell/Drafts`, never in the public repo. Syncing them between your own devices through iCloud Drive or a private "drafts" repo comes in v1.x. Teams or private repos can opt into a `_drafts/` folder or draft branch instead.
- **Publish** (⇧⌘P) shows a short checklist sheet before you confirm:
  - ✓ Properties valid · ✓ 1 new image (410 KB) · ⚠ 1 image missing alt text · ✓ No broken links · ⚠ `published` is off (the file is still public)
  - Address: `yoursite.com/notes/morality/` · Commit message: *"Publish: A politics of morality"* (editable) · the exact files that will be committed
- Publishing writes the post into the site, commits **only** the post and its new images (other uncommitted work in the folder is left alone), pulls first if the remote has moved on, pushes, and then **watches the GitHub Pages build** (`pages-build-deployment` runs, readable without sign-in for a public repo). When the post is live it offers "Open Post". If the build fails, Inkwell says so in plain language and points to the log.
- **Edits to published posts** are saved to the site folder but not committed. The list row shows ✎ until you click "Update", so one fix doesn't become three commits.
- **Scheduled posts** (v1.x): pick a date and time. Inkwell can add a small GitHub Actions workflow that rebuilds on a schedule, so posts go live without the app running. Without it, the app publishes when it's next open.
- **Unpublish** (v1.0) removes the post from the site and returns it to drafts. You can optionally leave a redirect or a "this post was removed" stub.
- **Version history** (v1.0) for every post is built from git history and shown as a timeline like Google Docs ("Jun 20 – draft", "Jun 27 – published"), with visual diff and restore. Restore creates a new commit and never rewrites history.

### 4.10 Organisation & search

- **Search** across all posts, drafts and pages (done: titles, excerpts and full text). Filters (section, status, tag, date) come in v1.0.
- **Tags** with a tag browser. Inkwell offers to generate tag pages if the site wants them.
- **Pinned** and **recent** items. **Quick switcher** (⌘O conflicts with Open Site, so ⌘P in v1.0) works like Obsidian/VS Code.
- **Internal links:** type `[[` to link to another post by title. Inkwell writes the real URL, and renaming a post updates links to it.
- **Backlinks** pane: "Referenced by 2 posts."

### 4.11 Site health (v1.0)

A background checker shows one badge in the sidebar:

- Front matter errors (unbalanced quotes, missing or invalid dates, filename/date mismatch, unpadded dates)
- Two files rendering to the same URL
- Empty or placeholder pages that are live
- Broken internal links and images, and dead external links (weekly)
- Missing alt text, oversized images, and repo/Pages size budget
- Missing SEO basics (meta description, Open Graph image, RSS feed, sitemap, favicon, 404 page), each with a one-click fix using standard plugins (`jekyll-seo-tag`, `jekyll-feed`, `jekyll-sitemap`). A hand-written feed or sitemap counts: Inkwell never adds a second one.
- Repo hygiene: committed build output (`_site/`), `.DS_Store`, and a missing `.gitignore`

---

## 5. Onboarding

1. **Open a site.** The MVP opens a folder that is already a clone of the site and publishes with the git credentials the Mac already has. v1.0 adds **Sign in with GitHub** (a GitHub App with device-flow auth, limited to the repos you pick, token in the Keychain) and clones the repo for you.
2. **Pick a site** (v1.0). Inkwell lists your repos with Pages enabled, `*.github.io` first. You can also choose **Create a new site** from a small set of templates (Essayist, Photo journal, Minimal homepage). Inkwell creates the repo, enables Pages and opens it.
3. **Inkwell reads the site.** It detects the generator, Markdown dialect, sections, front matter fields, image conventions and base URL, then shows a summary: *"Found a Jekyll site with 3 sections (Notes, Sidenotes, Travel), 6 posts, 1 image. 4 health issues."*
4. **Optional adoption** steps (§4.7), each skippable.
5. Drop into the editor with a "Write your first post" prompt.

Getting from first launch to the first published post should take **under 3 minutes**.

---

## 6. Platforms

| Phase | Platform | Purpose |
|---|---|---|
| 1 | **macOS 26+, Apple silicon** | Full experience (MVP built) |
| 2 | **iOS / iPadOS** | Capture-focused: quick sidenote, post a photo, light edits, publish. A share-sheet target turns a Kindle highlight or Safari quote into a sidenote, and a photo from Photos into a photo-stream post. Shares `InkwellKit` with the Mac app |

Windows, Linux, Android and a web client are out of scope. The value is a Mac-native writing experience, and the site itself stays editable anywhere because it is plain files.

---

## 7. Architecture

```
┌──────────────────────────── Inkwell.app (SwiftUI, AppKit where needed) ───────────────────────────┐
│  App        AppModel (site, drafts, git status, selection), EditorDocument, commands, launch flags │
│  Features   Sidebar · post list · editor + Properties · Preview (WKWebView) · Publish · Add Image │
│  Platform   InkwellTextView (TextKit 2 NSTextView, styler, paste/drop, Liquid chips)               │
├───────────────────────────────────── InkwellKit (Swift package) ─────────────────────────────────┤
│  InkwellCore      YAML subset, FrontMatterDocument (line-preserving), SiteLoader (config, nav,    │
│                   collections, pages), Permalink, Filename/Slug, SchemaInference, Validation,     │
│                   ContentChecks, DraftStore                                                       │
│  InkwellMarkdown  MarkdownScanner (style spans), MarkdownRenderer (kramdown + GFM), Formatting    │
│  InkwellTemplate  Liquid subset (tags, filters, includes), PreviewBuilder (layout chain, site     │
│                   object with data files and rendered collections)                                │
│  InkwellMedia     ImageImport (ImageIO: decode, resize, upright, strip metadata, name)            │
│  InkwellPublish   Git (the person's git via Process: status, commit --only, rebase, push),       │
│                   PagesStatus (Actions runs for the pushed commit)                                │
└───────────────────────────────────────────────────────────────────────────────────────────────────┘
          │ git push                                ▲ build status (public API)
          ▼                                         │
   github.com/<user>/<user>.github.io  ──►  GitHub Pages build  ──►  live site
```

**Key decisions:**

- **Native SwiftUI over Tauri or Electron.** The product's promise is an Apple Notes feel, and system text, image and web frameworks cover every need: TextKit for the editor, ImageIO for photos, WebKit for the preview. The shared package keeps an iOS app cheap. Same stack and rules as MediaPull: Swift 6, macOS 26, no third-party Swift packages.
- **Own Liquid and kramdown renderers.** Neither exists in Swift. Both implement what Jekyll themes and personal sites use, are tested against the site's real layouts, and say what they skipped.
- **The person's git over a git library.** Running `git` keeps credentials, SSH keys and hooks exactly as the person set them up, and a publish commits only named paths. If git is missing, Inkwell says how to install the command line tools.
- **Local clone over API-only.** A local clone gives offline writing, instant search, real preview and atomic multi-file publishes (post plus images in one commit). In the MVP the clone is the one the person already has; v1.0 can clone into Application Support.
- **Adapter pattern for generators** (v1.0). `SiteLoader`, `Permalink` and `PreviewBuilder` become the Jekyll adapter behind `detect()`, `sections()`, `schema(section)`, `pathFor(post)`, `urlFor(post)`, `mediaConvention()`, `renderPreview()` and `build()`. Then Hugo and plain HTML.
- **Optional repo config.** `.inkwell.yml` at the repo root stores only overrides, such as section labels, photo settings and image size. Jekyll ignores dotfiles by default, so the config never ends up on the site.
- **Conflict handling.** Before pushing, Inkwell fetches and rebases if the remote moved on (for example after an edit on github.com), stashing unrelated changes meanwhile. Real conflicts get a simple "Keep mine / Keep theirs / Compare" sheet (v1.0); until then the publish stops and says so.

---

## 8. Business model (if it goes beyond a personal tool)

- **Free & open source core:** the Mac app, unlimited sites, all editing and publishing features.
- **Optional paid "Plus" (~$4/mo)** for features that need a server: private draft sync without iCloud, shareable draft preview links, scheduled publishing without Actions, mobile push of build status, and external media storage.

---

## 9. Roadmap

**MVP (built):**
- macOS app, opens an existing Jekyll clone, uses the person's git
- Section inference, three-pane UI, live-styled editor with the commands in §4.2, Source view
- Properties panel with inference and validation
- Image paste/drag/pick with conversion, resize, metadata strip and auto-path
- Local drafts, one-click publish with checklist, Pages build status
- Instant preview

**v1.0:**
- Hidden syntax markers, inline images and galleries in the editor, slash menu, tables, embeds
- Sign in with GitHub, clone and create sites, new-site templates
- Photo stream section with batch import and a grid view; "Set up Photos" adoption
- Section management (create, rename, reorder) and site adoption diffs
- Exact preview (portable Ruby), whole-site preview, version history, unpublish
- Site health panel and SEO one-click fixes; Hugo and plain HTML adapters

**v1.x:**
- iOS capture app with share sheet; draft sync through iCloud
- Scheduled posts, internal links and backlinks, tag pages, media library
- Design panel (CSS variable editor), shareable draft links

**Success metrics:** time from opening the app to a published post under 60 seconds for a sidenote; zero broken builds caused by Inkwell; and for the primary user, how often they post.

---

## 10. Risks & open questions

| Risk | Mitigation |
|---|---|
| Instant preview diverges from the real build | Unsupported tags are listed and the preview says "Approximate"; Exact preview tier; diff-test Instant vs Exact on adoption |
| Arbitrary themes have hard-coded nav and layouts | Adoption diffs; features degrade gracefully; Code layer as an escape hatch |
| Markdown round-trip corrupts existing files | Source-preserving editor over raw text; byte-for-byte round-trip tests; field edits touch one line |
| A publish sweeps in unrelated work | Commit only named paths (`--only`); self-test checks the commit's file list |
| Testing damages the real site | Fixture site in tests; `make-sample-site.sh` clone with a local remote; self-test refuses GitHub remotes |
| Repo size growth from photos | Resize on import, storage meter, optional external storage |
| Users accidentally publishing drafts in public repos | Local-first drafts by default; publish is always explicit; warning for `published: false` |
| Bundling Ruby for exact Jekyll builds is heavy | Lazy download on first "Exact preview"; Hugo needs only a single binary; or move the site to an Actions build |

**Open questions**
1. Should drafts sync through iCloud, a private GitHub repo, or both?
2. Is the photo collection better as one file per photo (git-friendly, permalinks) or a single `_data/photos.yml` (simpler)? *Leaning: one file per photo.*
3. Should Inkwell manage the `github-pages` gem build or migrate sites to a GitHub Actions build, which allows modern Jekyll and any plugin? Migration could be an opt-in adoption step, and it would also make Exact preview simpler.
4. Is there demand for multi-author support, or should Inkwell stay single-author?
5. Should Inkwell clone sites into its own folder, or keep working in the clone the person already has? Working in place is simpler and is what the MVP does. A private clone avoids clashes with other tools.
6. When a published post's title changes, should Inkwell offer to rename the file (a new URL plus a redirect) or always keep the URL?

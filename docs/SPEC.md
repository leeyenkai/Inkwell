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
- **Pages and elements.** Twelve page templates and fifteen page elements (gallery, slideshow, map, timeline, callout, columns, toggle, tabs, button, cards, banner, recent posts, archive, table of contents, social links), edited in place with a form for their settings; see §4.7a.
- **Albums.** Photos in albums with their own pages, an album bar in Photos, several photos chosen at once.
- **Editor additions.** A formatting bar, a link popover that searches posts and headings, ⌘-click to follow links, clickable checklists, moving lines, find and replace, zoom.
- **Release.** Version 0.9.0 as an ad-hoc signed disk image (`scripts/make-dmg.sh`), an update check against GitHub releases, and a privacy note.
- **Design.** Six bundled themes that differ in layout, shown as real renders and tried on your own posts before a reviewable switch; palette and font presets; colours (light and dark), fonts and layout for Inkwell themes and hand-made stylesheets; theme options; navigation; site settings, favicon, share image and custom domain; and a live preview of any page.

- **Websites (§4.12), phase W1.** Inkwell tells blogs, Jekyll websites, hand-built sites and generated output apart. It lists HTML pages that have no front matter and opens them as source beside a live preview. The preview serves files as they are. A site in `docs/` opens from its repository. The sidebar suits a website. Health checks relative links and pictures, alt text and page titles, and publishing a page takes its new pictures along.
- **Websites (§4.12), phase W2.** An HTML page's title, description and share image are edited in a Properties form that rewrites only those values. Pictures dropped on a page are imported and inserted as `<img>` with alt text. New pages copy an existing page's head, header and footer.
- **Websites (§4.12), phases W3 and W4.**
  - Edit on Page makes the preview editable: click text to change it in place, click a picture to replace it, or click a link and
    choose Change Address. Only those characters change in the file.
  - When a page's header, menu or footer changes, the editor offers to make the same change on every page with an identical copy.
  - Navigation edits a hand-built site's menu (the links in a page's `<nav>`) and makes the same change on every page whose menu
    leads to the same places, even where the pages mark their own item as current or sit in other folders.
  - Site › Move to Jekyll… puts a header, menu or footer copied by several pages into `_includes`, adds `layout: null` front
    matter to the pages that use them, removes `.nojekyll` and lists hidden files in `include:`, all for review before publishing.
  - A site built by a GitHub Actions workflow with another generator opens read only; a workflow that uploads the files as they
    are counts like `.nojekyll`. The kind Inkwell found can be changed from the Site menu or the first-open summary.

Verified by 240 package tests (including a fake GitHub server for sync and performance bounds on a 600-post site) and the publish, content, design and website self-tests. A read-only live test passed against the real `leeyenkai/leeyenkai.github.io` (download, no false changes, pull). A live write test passed against a private throwaway repository: publish, pull during publish, conflict, delete. Not yet checked by a person: typing with input methods, drag and drop from Photos, the scheduled-post workflow running on GitHub.

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
- **Also primary from v1.1:** people whose Pages site is a website rather than a blog, such as a product page, project documentation or a portfolio, often written by hand in HTML (§4.12).
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
| Code block | ```` ``` ````, Monospaced style | fenced, with a language picker |
| Callout / aside | `/aside` (v1.0) | an HTML/IAL block styled by the site, only if the site supports it |
| Math | `/math` (v1.0) | `$$…$$`, only if the site loads MathJax/KaTeX |
| Embed | paste a YouTube/Vimeo/tweet URL (v1.0) | the site's embed include, or an iframe |

**Linking.** ⌘K (or the link button) opens a popover at the selection: search the site's posts and pages by title (with section and date), this post's headings (`#anchor`, using kramdown's ids), or type or paste a web or email address (`mailto:`). Return picks the top result; with nothing selected the post's title becomes the link text. Internal links are written as `[text](/section/slug/)`, the same form as `[[`. On an existing link the popover shows its target with Open, Edit and Remove Link (which keeps the text). ⌘-click or the context menu opens a link: a post of the site in the editor, anything else in the browser; hovering shows the target. Pasting an address over selected words links them; pasted on its own it stays plain text.

**Formatting bar and editing comforts.** A compact bar above the text (View › Formatting Bar, remembered) with a paragraph style menu (Title `#`, Heading `##`, Subheading `###`, Body, Monospaced as a fenced block), bold, italic, underline, strikethrough, highlight, link, lists, quote, inline code, table, image, a code-block language menu when the cursor is in a fenced block, and Insert. Buttons show the formatting at the cursor. Clicking a checklist box ticks it; ⌥⌘↑/↓ move lines; numbered lists renumber on Return, Tab and ⇧Tab; ⌘] / ⌘[ indent and outdent lists and quotes; superscript and subscript (`<sup>`, `<sub>`) and Clear Formatting are in the Format menu; Edit › Find has find and replace; View › Zoom In / Out / Actual Size (⌘+ / ⌘- / ⇧⌘0, since ⌘0 is Body Text) zoom the text for the session without changing the text size setting. With text selected, the footer shows its word and character count.

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

### 4.7a Themes and page elements (v0.4)

The user asked for Inkwell to work as a site designer, not only an editor. The earlier "no drag-and-drop page builder" decision stands in one sense: a page is still a plain Markdown file that GitHub Pages builds without Inkwell. What changes is that pages can now hold **elements**, and themes differ in structure, not only colour.

**Themes.** Six bundled themes, each with its own layouts and stylesheet over a shared base, so they differ in structure: a centred essay column (Essayist), a sidebar notebook (Notebook), full-bleed photos (Photo journal), plain monospaced text (Minimal), an editorial front page with a lead story (Magazine), and a portfolio with a hero and project cards (Studio). The gallery shows a render of each theme, made from the theme's real files. Choosing one previews it with **your own posts** before anything is written. In the design panel, palettes and font pairings are one-click presets on top of the existing colour, font and layout controls.

**Elements.** Each element is plain HTML with Markdown inside, using kramdown's `markdown="1"`, so the text stays readable and editable as Markdown. Where an element needs it, it uses a Liquid include. Every element works without JavaScript, and a small script adds the extras. The elements are:

- Gallery (grid, masonry, or an album)
- Slideshow
- Map (places written as `geo:` links)
- Timeline
- Callout
- Columns
- Toggle (`<details>`)
- Tabs
- Button
- Cards
- Recent posts
- Archive by year
- Table of contents
- Social links
- Hero banner

They come from the slash menu, the Insert menu and the toolbar. In the editor, an element's wrapper lines collapse to a labelled bar with **Edit…**, which opens a form for that element; the Markdown inside stays editable in place. Elements need a small set of site files, the **element kit**: `_includes/inkwell/*`, `assets/css/inkwell-blocks.css` and `assets/js/inkwell-blocks.js`. The kit is added the first time an element is used, and published with the post that uses it. On sites with their own theme, its stylesheet and script are added to the page head the same way Health adds tags.

**Page templates.** A new page starts from a template: Blank, About, Now, Contact, Projects, Links, Timeline, Places (map), Archive, Album index, or Slides. The Slides template uses an `inkwell-slides` layout in which each section break is a slide.

**Albums.** Photos can belong to albums (`albums:` in each photo's front matter; titles, descriptions and covers in `_data/albums.yml`). Each album has its own page under `albums/`, using an `album` layout. The photos page shows the albums, then the stream. In the app, Photos has an album list, and photos can be added to and removed from albums, with a cover and title per album. A gallery element can show an album.

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

### 4.12 Websites, not only blogs (v1.1, built)

Many GitHub Pages sites are not blogs. They are a product page, a project's documentation, a portfolio or a one-page landing site, and often hand-written HTML, CSS and JavaScript. An example is `fxgl.github.io/steamac`. It is two HTML pages, a stylesheet with 15 CSS custom properties, scripts and media, served from `/docs` of an app's code repository, with a `.nojekyll` file so GitHub copies the files as they are.

**What Inkwell does with such a site today (checked on a copy, 25 Nov 2026).**
- It shows an empty Posts section and no pages, because it only lists pages that have front matter.
- The preview says "Not found: /", because the preview has no directory index for plain files.
- Theme & Style offers "Change Theme…", which would replace a hand-made design.
- Opened as a local folder at the repository root, it finds nothing, because local mode has no way to know about `/docs`. GitHub mode already builds from the Pages source folder.

The goal is that a person who owns a site like this can open it, change its words and pictures, see the result, and publish. Nothing should be broken or rewritten on the way.

#### Kinds of site

Inkwell decides the kind of site when it opens it, and shows the kind in the site summary. The choice can be changed in Settings.

| Kind | How Inkwell recognises it | What Jekyll does | What Inkwell shows |
|---|---|---|---|
| **Blog** | Has collections or `_posts` with posts | Builds everything | As now |
| **Website on Jekyll** | Has front matter pages, but no posts | Builds pages; files without front matter are copied as they are | Pages first, posts only if added |
| **Hand-built website** | Has `.nojekyll`, or has HTML pages and no front matter anywhere | Nothing; every file is served as it is | Pages, Media, Health, Design (colours only), Code |
| **Built by another tool** | `.nojekyll` together with signs of generated output: a `generator` meta tag, hashed asset names such as `app.3f9c1a.js`, or a GitHub Actions workflow that builds the site with another generator | Nothing; the files are another program's output | Read only, with a note to edit the source instead |

HTML files without front matter on a Jekyll site are listed too. Jekyll copies them unchanged, so they are pages a person edits like any other. Markdown files without front matter, such as a README, are not listed, because GitHub serves them as plain text.

**How the last parts were built (25 Nov 2026).**
- **Link addresses.** The preview marks each link's `href`. Clicking a link shows its address with Change Address, and the new
  address replaces only that attribute's value. On a Jekyll page, text and addresses holding Liquid tags are not marked.
- **Navigation.** The menu is the links of a page's first `<nav>`, as `<li>` items or bare links. Renaming, changing an address,
  reordering, removing and adding rewrite only those items; the markup between them stays. The change reaches every page whose
  menu leads to the same places, with addresses rewritten for its folder, and a copied item loses `active` and `aria-current`.
  Menus with submenus, or links without addresses, are left to the source.
- **Moving to Jekyll.** A part is shared when two or more pages have the identical copy. Pages containing `{{` or `{%` are left
  exactly as they are, since Jekyll would read them. Whole HTML pages with front matter open as HTML source, and the preview runs
  their includes.
- **Generated sites.** `.github/workflows` (or the repository's, for a `docs/` site) decides when a workflow deploys to Pages: a
  Jekyll build keeps the site editable, another generator makes it read only, and an upload with no build step serves the files
  as they are. In GitHub mode, a branch-built site ignores its workflows.

**How W1 was built.**
- **Detection.** It uses files: `.nojekyll`, a `generator` tag, hashed script names, or the `_next`, `_astro` or `static/js` folders, and the repository's GitHub Actions workflows (see above).
- **Editing.** HTML pages open in the code editor beside a live preview, which is the first step of W2.
- **What is turned off on plain HTML sites:**
  - New Page, because its templates are Markdown.
  - Rename and Duplicate, because both write front matter.
  - "Delete Unused" in Media, because scripts can use pictures Inkwell cannot see.
  - Health's Jekyll suggestions.
- **Starting a blog.** "Start a Blog…" writes the first post as a draft. Publishing it creates `_posts/`.

#### Rules that keep a hand-built site safe

- **Byte-preserving HTML editing.** The rule for Markdown applies to HTML as well. Saving without changes gives the same bytes, and an edit replaces only the characters that changed. Inkwell never reformats, re-indents or "tidies" markup.
- **No front matter.** On a site with `.nojekyll`, Inkwell never adds front matter to a file. GitHub would serve it to readers as visible text.
- **No Liquid.** On a site with `.nojekyll`, no Liquid is written into files, and none is run in the preview.
- **No theme replacement.** No theme gallery is shown for a hand-built site, because applying a theme would replace its design.
- **Elements as plain HTML only.** Elements that rely on Jekyll includes (Recent posts, Archive) are not offered. The others are written as plain HTML, with the element kit's stylesheet and script linked from the page directly, and only after the person agrees to add those two files.
- **Repository boundaries.** In a code repository, Inkwell shows only the site folder. Publishing commits only paths inside it, as the rule for named paths already requires.

#### Phases

**W1: Recognise and show** (done 25 Nov 2026; makes the example site usable for reading and small changes)
1. **Site kind.** Detect the kind of site (table above) in `SiteLoader`, from the file tree and, in GitHub mode, the Pages build type.
2. **Local folder mode.** If the root has no site and a `docs/` folder does, use `docs/` and say so. A folder picker covers other layouts.
3. **Listing pages.** List HTML and Markdown pages that have no front matter. Each page's title comes from its `<title>`, and its description from `<meta name="description">`.
4. **Sidebar.** For websites, the sidebar shows Pages, Media, Health, Design and Code. Posts, Drafts, Tags and Photos are hidden until the site has them. An "Add a blog…" action adds a posts section as a reviewable change. It is offered only on Jekyll sites.
5. **Plain preview.** Files are served as they are. `/` and folder addresses fall back to `index.html`. Hand-built sites get no Liquid and no "Approximate" badge.
6. **Health.** Checks broken internal links and images across HTML pages, a missing `<title>`, description or share image, oversized media, and missing alt text. Fixes edit the HTML directly, under the byte-preserving rule.

**W2: Edit pages** (done 25 Nov 2026; the HTML equivalent of today's post editor)
1. **Opening a page.** An HTML page opens in a source editor with a live preview beside it. This reuses the code pane's highlighter, with undo and find.
2. **Properties.** A page's title, description and share image are edited in a Properties form. Each field rewrites only its tag's attribute or text.
3. **Pictures.** Dropping a picture onto an HTML page imports it under the same rules as posts (resized, location and camera details removed) and inserts an `<img>` with alt text.
4. **New pages.** A new page starts from an HTML template that links the site's own stylesheet. The template takes the page's shared header and footer from an existing page, so it matches the rest of the site.
5. **Publishing.** Publishing works as it does now, through review of all changes.

**W3: Edit on the page** (done 25 Nov 2026; the "feels like Notes" step for websites)
1. **Editing text in place.** Clicking text in the preview lets the person type there. Only the text of that element changes in the file.
2. **How the preview finds the source.** The preview marks each editable element with its source position. These marks exist only in the preview and are never written to the file.
3. **Pictures and links.** Clicking a picture replaces it. Clicking a link shows its address with Change Address.
4. **Content made by scripts.** Text that a script builds (a games list loaded by JavaScript, for example) is not editable in place, and the page says why.

**W4: Parts shared by every page** (done 25 Nov 2026)
1. **Editing a shared part once.** The same header, menu and footer are usually copied into every HTML page. They can be edited once and applied to every page that has an identical copy, shown as one reviewable change.
2. **Navigation.** The navigation editor works on that shared menu when the site has no `_data/navigation.yml`.
3. **Switching to Jekyll.** Turning a hand-built site into a Jekyll site, with includes for the shared parts and `.nojekyll` removed, is an optional adoption step only. It changes how GitHub builds the site, so it is never automatic.

#### Testing

- **Fixtures.** Two fixture sites in `InkwellKit/Tests`: a hand-built `.nojekyll` site in `docs/`, and a generated site with hashed assets and a `generator` tag.
- **What the tests cover.** Detection, page listing, the preview's directory index, and byte-preserving edits to text, attributes and `<img>` insertion. They also check that no front matter or Liquid is written to a `.nojekyll` site.
- **Real sites, read only.** A read-only check runs against a local copy of a real hand-built site, such as the example above. It is never published.
- **What exists for W1 to W4.**
  - `WebsiteTests` covers detection, listing, the preview and health.
  - `scripts/make-plain-site.sh` builds the fixture site in `InkwellKit/Tests/Fixtures/plain-site`.
  - `--selftest-website` edits a page on that site and publishes it. It also adds a description, drops in a picture and makes a new page. Then it edits a paragraph and a link address on the preview through its script, applies a header change to the page that shares it, adds a menu item to both pages with that menu, and moves the site to Jekyll, checking that the preview runs the shared header include.
  - `WebsiteMenuTests` covers link addresses, menus (byte-identical when unchanged, list and bare-link menus, other folders), the move to Jekyll and workflow detection.
  - The example site was checked read only, with preview snapshots.

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

**v1.1, websites (§4.12):**
- W1: recognise hand-built and generated sites, `docs/` in local folder mode, pages without front matter, a plain preview, HTML health checks
- W2: edit HTML pages with a live preview, page properties from `<title>` and `<meta>`, pictures, new pages from HTML templates
- W3: edit text and pictures on the rendered page
- W4: shared header, menu and footer edited once for every page; the menu editor for hand-built sites; the optional move to Jekyll

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
| Editing a hand-built page breaks its markup | Byte-preserving edits that replace only changed characters; no reformatting; round-trip tests on HTML fixtures |
| Inkwell edits a generated site whose source lives elsewhere | Detect generated output and open it read only, with a note to edit the source |
| Front matter or Liquid written into a `.nojekyll` site shows up as text on the live site | Neither is ever written to such a site; tests check it |
| Bundling Ruby for exact Jekyll builds is heavy | Lazy download on first "Exact preview"; Hugo needs only a single binary; or move the site to an Actions build |

**Open questions**
1. Should drafts sync through iCloud, a private GitHub repo, or both?
2. Is the photo collection better as one file per photo (git-friendly, permalinks) or a single `_data/photos.yml` (simpler)? *Leaning: one file per photo.*
3. Should Inkwell manage the `github-pages` gem build or migrate sites to a GitHub Actions build, which allows modern Jekyll and any plugin? Migration could be an opt-in adoption step, and it would also make Exact preview simpler.
4. Is there demand for multi-author support, or should Inkwell stay single-author?
5. Should Inkwell clone sites into its own folder, or keep working in the clone the person already has? Working in place is simpler and is what the MVP does. A private clone avoids clashes with other tools.
6. For hand-built websites (§4.12), how much should "edit on the page" (W3) allow: text and pictures only, or also adding and removing sections of a page? *Leaning: text, pictures and links only; structure stays in the source editor.*
7. Should Inkwell offer to move a hand-built site to Jekyll (includes for the shared parts), or only edit shared parts across pages in place? *Leaning: edit in place; moving to Jekyll is an optional adoption step.*
8. When a published post's title changes, should Inkwell offer to rename the file (a new URL plus a redirect) or always keep the URL?

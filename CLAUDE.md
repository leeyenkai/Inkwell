# Inkwell, working notes for Claude

## What this project is

A native Mac app for writing, previewing and publishing posts on a GitHub Pages site, with an Apple Notes feel. It reads and writes the site's own files, so the site works the same without it. It grew out of `~/Desktop/leeyenkai.github.io` (Jekyll, kramdown, collections `notes`/`sidenotes`/`travel`).

- Specification (source of truth): [docs/SPEC.md](docs/SPEC.md). Its "Implementation status" section says what is built.
- Why the spec differs from the first proposal: [docs/REVIEW.md](docs/REVIEW.md).

If a request conflicts with the spec, say so and update the spec before the code.

## Stack

- Swift 6, SwiftUI, AppKit where SwiftUI falls short (the text view). macOS 26 or later, Apple silicon. App target is MainActor by default.
- `InkwellKit` local package (macOS 26 and iOS 26), imported by the app as one module (`InkwellKit` re-exports the rest).
- No third-party Swift packages, the same rule as MediaPull. Ask before adding any. The one bundled engine is dart-sass
  (pinned version and SHA-256 in `scripts/fetch-engines.sh`, copied into the app by `scripts/bundle-engines.sh` in a build
  phase); run `scripts/fetch-engines.sh` once before building.
- Same formatting as MediaPull: `.swiftformat` and `.swiftlint.yml`, 140-column lines, few comments that explain why.

## Layout

```
Inkwell/                 app target (synchronized folder)
  App/                   InkwellApp (scenes, commands, launch flags, self-test), AppModel, AccountModel, Backends (GitHub / local git),
                         EditorDocument, SiteCreation, ContentActions (move, duplicate, pages, tags), PhotoActions (photos, galleries),
                         HealthActions (health, external links), Preferences (Prefs, Diagnostics)
  Features/Design/       DesignModel, DesignViews (panel, token rows, theme gallery, preview), SettingsViews (navigation, settings,
                         custom domain), CodeViews (file list, code editor pane)
  Platform/CodeTextView  CodeHighlighter and the CodeEditor text view
  Features/              ContentView (window, sidebar, list, detail, site menu), Onboarding (welcome, sign-in, site picker, new site),
                         ContentSheets (move, new page, history, tags, link picker), PhotoViews (photo grid, captions, media library), TableEditor,
                         HealthViews, SharingView (per-post SEO), SettingsWindow, HelpViews (help, shortcuts, site summary),
                         EditorView (+ Properties), PreviewView, PublishSession (publish/update/delete/unpublish/changes), Sheets
  Platform/              InkwellTextView (NSTextView, MarkdownStyler, MarkdownEditor representable)
  Resources/             AppIcon.icon (Liquid Glass: icon.json + SVG layers), Assets.xcassets (accent colour)
InkwellKit/Sources/
  InkwellGitHub          GitHubClient (REST, Git Data API, Pages, Actions), DeviceFlow, TokenStore (keychain), BuildWatcher
  InkwellSync            WorkingCopy (download, blob-SHA changes, one-commit publish, pull, conflicts, discard), SiteRef
  InkwellDesign          CSSTokenDocument, ConfigDocument, NavigationDocument, ThemeManifest + Themes/, ThemeApplier, DesignTokens
  InkwellCore            YAML subset, FrontMatterDocument, SiteLoader, Permalink, Filename, Slug, SchemaInference, Validation, ContentChecks, DraftStore,
                         ContentTools (MovePlanner, ConfigEditing, TagIndex, TextDiff), Photos (PhotoStream, MediaLibrary), Schedule,
                         SiteHealth
  InkwellMarkdown        MarkdownScanner (editor styling), MarkdownRenderer (kramdown + GFM HTML), Formatting (editor commands),
                         SmartTyping, Tables (MarkdownTable, ImageLines)
  InkwellTemplate        LiquidTemplate, LiquidContext, LiquidFilters, PreviewBuilder
  InkwellMedia           ImageImport
  InkwellPublish         Git, PagesStatus
InkwellKit/Tests         XCTest, with a synthetic fixture site in Fixtures/site
scripts/                 build.sh, make-sample-site.sh, sync-strings.sh, make-dmg.sh, readme/screenshots.sh
```

## Build and test

- Always build outside the iCloud folder: `scripts/build.sh` (DerivedData in `~/Library/Caches/InkwellBuild`), and
  `cd InkwellKit && swift test --scratch-path ~/Library/Caches/InkwellBuild/spm`.
- Run against a copy, never the real site: `scripts/make-sample-site.sh` clones the site into `~/Library/Caches/InkwellBuild/sample-site` with a local bare repo as `origin`.
- End to end: `Inkwell.app/Contents/MacOS/Inkwell --site <sample-site> --selftest-publish` prints `SELFTEST PASS` when a draft and its image are published as exactly one two-file commit. It refuses GitHub remotes.
- Launch the built app with `open -n <app> --args …` (running the binary directly from a shell may show no window), and use
  `open -W --stdout <file>` to read self-test output.
- Live GitHub check (read-only): `INKWELL_LIVE_TOKEN=$(gh auth token) INKWELL_LIVE_REPO=owner/name swift test --filter LiveGitHubTests`.
  Live publishing (writes!): `INKWELL_LIVE_TOKEN=$(gh auth token) INKWELL_LIVE_WRITE_REPO=leeyenkai/inkwell-publish-test swift test --filter LivePublishTests`.
  That private repository is a throwaway the user agreed to; never point the write test at a real site.
- Websites (SPEC §4.12): `scripts/make-plain-site.sh` makes a code repository with a hand-built site in `docs/` and a local
  bare remote. `--site <plain-site> --selftest-website` edits and publishes a page and checks the commit (page and new
  picture only, no front matter), then adds a description, drops in a picture, makes a new page, edits a paragraph on the
  preview and applies a header change to another page (refuses GitHub remotes).
- Preview pictures: window captures leave web views blank, so `--snapshot-preview <file.png>` saves what the preview shows.
- Design self-test: `--site <sample-site> --selftest-design` (applies a theme, edits colours, options and the menu, checks files,
  preview and the change list; refuses GitHub remotes).
- Typing cost: `--site <sample-site> --measure-typing` prints milliseconds per keystroke at 15k, 60k and 150k characters.
  `swift test --filter PerformanceTests` times load, health, media and preview on a generated 600-post site.
- Content self-test: `--site <sample-site> --selftest-content` (move with redirect and publish, history, duplicate, new page, tags,
  Photos setup and import, the media library, a scheduled post published with its workflow, an inline image, and a table edit
  undone in one step, quick restyle matching a full one, a health fix; refuses GitHub remotes).
- Designer flags: `--new-page <template>` (blank, about, now, contact, projects, links, timeline, places, landing, archive, albums,
  slides), `--element-picker`, `--edit-element` (form of the first wrapped element in the open post), `--select <text>`,
  `--link-popover <text>`, `--album <id|none>`, `--photo a,b` (several), `--gallery-theme <id>` before `--theme-gallery`,
  `--render-theme-previews <folder>` (with `--site`; regenerates the gallery pictures in `Themes/<id>/preview*.png`).
- Screenshots: `scripts/capture-window.sh <out.png> "<title or empty>" <args>` launches through Launch Services and captures
  only its own instance. Web views (the preview) come out blank in captures; check pages in a browser instead.
- Release: `scripts/make-dmg.sh` (steps in docs/RELEASING.md). Update check: `--update-feed <url or file URL>` with
  `--check-updates` shows the Software Update window against a test release JSON.
- Launch flags for checking UI states: `--fresh` (do not reopen the last site), `--pane design|navigation|settings|media|health` (`--issue <id>`)
  (`--media-file <path in site>`), `--photo <_photos/file>`,
  `--apply-theme <id>`, `--theme-gallery`, `--pane code --code-file <path> [--theme-file]`, `--site`, `--section <id>`, `--open <path in site>`, `--preview`, `--source`, `--publish-sheet`, `--new-draft <title>` with `--draft-body <file>`, `--table-cursor` (cursor in the first table),
  `--edit-table` (the table grid, in a window so it can be captured), `--settings`, `--help <topic>`, `--summary` (first-open
  summary, which `--site` otherwise suppresses).
- README screenshots: `scripts/readme/screenshots.sh` (needs Screen Recording permission for the terminal). Files the app reads must live outside `~/Desktop`, or macOS blocks the app on a privacy prompt.

## Rules

- **Never write to `~/Desktop/leeyenkai.github.io`** (or any real site) from tests, scripts or manual runs. Use the sample clone.
- **Markdown is source-preserving.** Display is attributes only. Opening and saving a file without edits must give the same bytes; a front matter edit rewrites only that field's lines. Keep the round-trip tests passing.
- **Publish commits only the paths it names**: `WorkingCopy.publish` (GitHub API) and `Git.publish` (`commit --only`). Never
  commit the whole tree.
- **Sign-in tokens live only in the keychain** (`TokenStore`). Never log them or write them to disk or test fixtures.
- **Sync never overwrites local edits**: a file changed both here and on GitHub becomes a conflict for the person to resolve.
- **Drafts stay out of the repo** until publish (`DraftStore`, Application Support). Images are written into the site when added; they are committed only with the post that uses them.
- **Image import strips location and camera metadata** and never keeps the original file in the site.
- Text views: formatting commands go through `Formatting` (pure, tested) and `InkwellTextView.apply`, so each is one undo step.
- Sites GitHub serves as they are (`SiteKind.servesFilesAsIs`: `.nojekyll`, or hand-written HTML) never get front matter or
  Liquid written into them, and pages without front matter (`SiteDocument.isStatic`) are edited as HTML source, byte for byte.
- Page elements are plain Markdown/HTML that GitHub Pages builds without Inkwell (`PageElements`, `ElementKit`). New element
  styles go in `ElementKit/assets/css/inkwell-blocks.css` using theme tokens with fallbacks, so they work on any theme.
- User-facing copy: plain and short, no exclamation marks, no emoji.
- Localisation: text a person reads goes through the string catalogs. SwiftUI literals are keys already; a `String` shown on
  screen needs `String(localized:)` in the app and `localized(...)` in InkwellKit (each module's own bundle). One key per
  whole sentence, counts inside it (`"\(n) posts"`) with English singulars added as plural forms in the catalog
  (`LocalizationTests` fails without them). Run `scripts/sync-strings.sh` after adding strings. Site content (commit
  messages, files written to the site) stays in English.
- Never name other applications in UI copy or code identifiers (the spec's landscape table is the exception).

## Gotchas

- GitHub API answers are marked cacheable for a minute: every request uses `reloadIgnoringLocalAndRemoteCacheData`, and
  `WorkingCopy` ignores a branch head it has already moved past (`SyncState.passed`), since GitHub can also lag briefly.
- `FrontMatterDocument.set` compares parsed values, so writing an equal value is a no-op. Keep it that way: it is what keeps diffs clean.
- `MarkdownScanner.regex` caches compiled patterns behind a lock; `MarkdownRenderer.match` reuses it.
- Collection URLs come from the filename slug (`permalink: /:collection/:title/`), not the title. A draft's filename follows its title; a published file is never renamed.
- The preview serves site files through the `inkwell-site://site/` scheme, so `/assets/...` resolves as on the live site. Updates replace `<body>` in place to keep the scroll position.
- The app icon is `AppIcon.icon` (Icon Composer format: `icon.json` + SVG layers in `Assets/`), not an asset-catalog icon set.
  Groups front to back (Xcode allows at most four): Grip, Roller (core, roller, fork), Page (lines, ink, page), Sheet. The system adds
  glass, highlights and shadows. `scripts/icon/render.sh` renders every appearance with Icon Composer's `ictool` and writes a
  contact sheet to `~/Library/Caches/InkwellBuild/icon/`; `docs/images/icon.png` is the Default render at 256 px.
- This folder is in an iCloud-synced Desktop. iCloud can leave duplicates named `File 2.swift`; `.gitignore` excludes them, but check before deleting one.

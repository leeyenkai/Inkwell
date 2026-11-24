# Inkwell, working notes for Claude

## What this project is

A native Mac app for writing, previewing and publishing posts on a GitHub Pages site, with an Apple Notes feel. It reads and writes the site's own files, so the site works the same without it. It grew out of `~/Desktop/leeyenkai.github.io` (Jekyll, kramdown, collections `notes`/`sidenotes`/`travel`).

- Specification (source of truth): [docs/SPEC.md](docs/SPEC.md). Its "Implementation status" section says what is built.
- Why the spec differs from the first proposal: [docs/REVIEW.md](docs/REVIEW.md).

If a request conflicts with the spec, say so and update the spec before the code.

## Stack

- Swift 6, SwiftUI, AppKit where SwiftUI falls short (the text view). macOS 26 or later, Apple silicon. App target is MainActor by default.
- `InkwellKit` local package (macOS 26 and iOS 26), imported by the app as one module (`InkwellKit` re-exports the rest).
- No third-party Swift packages, the same rule as MediaPull. Ask before adding any.
- Same formatting as MediaPull: `.swiftformat` and `.swiftlint.yml`, 140-column lines, few comments that explain why.

## Layout

```
Inkwell/                 app target (synchronized folder)
  App/                   InkwellApp (scenes, commands, launch flags, self-test), AppModel, EditorDocument
  Features/              ContentView (window, sidebar, list, detail), EditorView (+ Properties), PreviewView, PublishSession, Sheets
  Platform/              InkwellTextView (NSTextView, MarkdownStyler, MarkdownEditor representable)
  Resources/             AppIcon.icon (Liquid Glass: icon.json + SVG layers), Assets.xcassets (accent colour)
InkwellKit/Sources/
  InkwellCore            YAML subset, FrontMatterDocument, SiteLoader, Permalink, Filename, Slug, SchemaInference, Validation, ContentChecks, DraftStore
  InkwellMarkdown        MarkdownScanner (editor styling), MarkdownRenderer (kramdown + GFM HTML), Formatting (editor commands)
  InkwellTemplate        LiquidTemplate, LiquidContext, LiquidFilters, PreviewBuilder
  InkwellMedia           ImageImport
  InkwellPublish         Git, PagesStatus
InkwellKit/Tests         XCTest, with a synthetic fixture site in Fixtures/site
scripts/                 build.sh, make-sample-site.sh, readme/screenshots.sh
```

## Build and test

- Always build outside the iCloud folder: `scripts/build.sh` (DerivedData in `~/Library/Caches/InkwellBuild`), and
  `cd InkwellKit && swift test --scratch-path ~/Library/Caches/InkwellBuild/spm`.
- Run against a copy, never the real site: `scripts/make-sample-site.sh` clones the site into `~/Library/Caches/InkwellBuild/sample-site` with a local bare repo as `origin`.
- End to end: `Inkwell.app/Contents/MacOS/Inkwell --site <sample-site> --selftest-publish` prints `SELFTEST PASS` when a draft and its image are published as exactly one two-file commit. It refuses GitHub remotes.
- Launch flags for checking UI states: `--site`, `--section <id>`, `--open <path in site>`, `--preview`, `--source`, `--publish-sheet`, `--new-draft <title>` with `--draft-body <file>`.
- README screenshots: `scripts/readme/screenshots.sh` (needs Screen Recording permission for the terminal). Files the app reads must live outside `~/Desktop`, or macOS blocks the app on a privacy prompt.

## Rules

- **Never write to `~/Desktop/leeyenkai.github.io`** (or any real site) from tests, scripts or manual runs. Use the sample clone.
- **Markdown is source-preserving.** Display is attributes only. Opening and saving a file without edits must give the same bytes; a front matter edit rewrites only that field's lines. Keep the round-trip tests passing.
- **Publish commits only the paths it names** (`Git.publish`, `commit --only`). Never `git add -A` or commit the whole tree.
- **Drafts stay out of the repo** until publish (`DraftStore`, Application Support). Images are written into the site when added; they are committed only with the post that uses them.
- **Image import strips location and camera metadata** and never keeps the original file in the site.
- Text views: formatting commands go through `Formatting` (pure, tested) and `InkwellTextView.apply`, so each is one undo step.
- User-facing copy: plain and short, no exclamation marks, no emoji.
- Never name other applications in UI copy or code identifiers (the spec's landscape table is the exception).

## Gotchas

- `FrontMatterDocument.set` compares parsed values, so writing an equal value is a no-op. Keep it that way: it is what keeps diffs clean.
- `MarkdownScanner.regex` caches compiled patterns behind a lock; `MarkdownRenderer.match` reuses it.
- Collection URLs come from the filename slug (`permalink: /:collection/:title/`), not the title. A draft's filename follows its title; a published file is never renamed.
- The preview serves site files through the `inkwell-site://site/` scheme, so `/assets/...` resolves as on the live site. Updates replace `<body>` in place to keep the scroll position.
- The app icon is `AppIcon.icon` (Icon Composer format: `icon.json` + SVG layers in `Assets/`), not an asset-catalog icon set.
  Groups front to back: Grip, Roller (core, roller, fork), Ink, Page (lines, page), Sheet. Shapes stay flat; the system adds
  glass, highlights and shadows. `scripts/icon/render.sh` renders every appearance with Icon Composer's `ictool` and writes a
  contact sheet to `~/Library/Caches/InkwellBuild/icon/`; `docs/images/icon.png` is the Default render at 256 px.
- This folder is in an iCloud-synced Desktop. iCloud can leave duplicates named `File 2.swift`; `.gitignore` excludes them, but check before deleting one.

<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Inkwell icon">
</p>

<h1 align="center">Inkwell</h1>

<p align="center">Write, preview and publish posts on your GitHub Pages site, as easily as writing a note. A Mac app that keeps your site as plain files in your own repository.</p>

![Inkwell: a note open in the editor beside a preview that uses the site's own layout and CSS](docs/images/main.png)

## Features

- **Opens your existing site.** Sections, fields and URLs come from `_config.yml`, `_data/navigation.yml` and the posts already there. No config file.
- **Writes clean Markdown.** The editor styles Markdown as you type but saves exactly what you wrote, so untouched lines never change. Liquid tags show as chips you can't break by accident.
- **Properties instead of YAML.** Title, date, byline and the rest as fields, inferred per section, with warnings for unclosed quotes, bad dates and filename mismatches.
- **Images done for you.** Paste or drop a photo: it is resized, turned upright, cleaned of location data, named after the post and linked with `relative_url`.
- **A real preview.** Posts render through the site's own layouts and CSS as you type, at desktop or phone width.
- **Private drafts, one-click publish.** Drafts stay on your Mac until you publish. Publishing checks the post, commits only its own files, pushes, and tells you when GitHub Pages has it live.

| Draft with preview | Publish |
|---|---|
| ![A new draft with a footnote, a list and an image, previewed beside it](docs/images/draft.png) | ![The publish checklist: valid properties, one new image, no broken links, and the files to commit](docs/images/publish.png) |
| **Sidenotes** | **Source** |
| ![A sidenote of quotes, styled in the editor and in the preview](docs/images/sidenotes.png) | ![The raw file, front matter included](docs/images/source.png) |

The screenshots show [leeyenkai.github.io](https://leeyenkai.github.io), the site Inkwell was built for.

## Build

```bash
./scripts/build.sh
```

Needs macOS 26 or later on Apple silicon, Xcode 27 and git. Tests: `cd InkwellKit && swift test`. Try it on a throwaway copy of a site with `./scripts/make-sample-site.sh <site folder>`.

Status: an early MVP. The plan and what is built are in [docs/SPEC.md](docs/SPEC.md), and the review behind them is in [docs/REVIEW.md](docs/REVIEW.md).

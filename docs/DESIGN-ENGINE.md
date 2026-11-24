# Design engine (`InkwellDesign`)

The non-UI half of milestone M3. Every editor works on the site's own files, line by line: unchanged files stay byte-identical, and an edit touches only what it changes.

## Editors

| Type | File | What it does |
|---|---|---|
| `CSSTokenDocument` | any stylesheet | Reads `--name: value;` properties in `:root` (or `html`) rules. A rule inside `@media (prefers-color-scheme: dark)` is the dark palette. `set(_:to:scheme:)` replaces only the value, and adds the property or the dark block when missing. Comments are ignored, and so is a final declaration with no `;`. |
| `ConfigDocument` | `_config.yml` | `value("inkwell.theme")` reads any depth. `set("title", raw:)` and `set("inkwell.theme", raw:)` write a top-level or one-level-nested key, creating the parent when needed. `raw: nil` removes the key. Values are already-formatted YAML (`YAMLFormat.quoted`, `.bool`, `.list`). |
| `NavigationDocument` | `_data/navigation.yml` | A list of `NavigationEntry(title:url:)`. You can `move`, append or remove entries. `text` writes the list back and keeps the comment lines at the top. |

## Themes

`ThemeManifest.bundled()` returns Essayist, Notebook, Photo journal and Minimal. They share one set of layouts (`Themes/_base`): `default`, `post`, `page` and `home`, plus `inkwell-header`, `inkwell-footer` and `inkwell-post-list` in `_includes`. They also share one stylesheet that only uses tokens.

Each `theme.json` lists 13 tokens (colours with light and dark values, fonts, size, line height, width and corner radius), each with a label and group for the Design panel. It also lists the options and their defaults.

Options live in `_config.yml` under `inkwell:`, so the layouts and Jekyll on GitHub Pages read the same values:

| Key | Values |
|---|---|
| `theme` | the theme id |
| `home_style` | `list` / `cards` / `chain` |
| `home_collection` | which collection the `home` layout lists (a page can override it with `list:`) |
| `date_format` | a strftime pattern |
| `reading_time` | `true` / `false` |
| `appearance` | `auto` / `light` / `dark` |
| `footer`, `favicon`, `social_image` | optional |

The layouts use only Liquid that `InkwellTemplate` runs. They don't need `jekyll-seo-tag`, because they write the title and Open Graph tags themselves.

`ThemeApplier.plan(theme:siteRoot:)` returns an `AdoptionPlan` (`FileChange`s with old text, new text and a plain-English reason) for the UI to show before anything is written:
- the layouts and includes;
- `assets/css/inkwell.css` (tokens plus the base styles) and `assets/css/inkwell-dark.css` (the dark tokens, linked with `media="(prefers-color-scheme: dark)"` when the appearance is `auto`);
- the `inkwell:` keys (option defaults are written only when missing);
- `_data/navigation.yml`, only when the site has none.

It never touches posts or pages. `plan.apply(to:)` writes the files, and planning again afterwards returns no changes.

## Tokens for the Design panel

`DesignTokens.load(siteRoot:)` finds a site's tokens:
- **Inkwell theme:** read from the theme's two stylesheets, labelled by the manifest.
- **Any other site:** read from the first stylesheet in `assets/css` that has `:root` variables (for example `style.css` on leeyenkai.github.io). Labels and groups are inferred from names and values.

`set(_:to:scheme:siteRoot:)` writes one value and returns the `FileChange`. For a hand-made theme, setting a dark value adds a `prefers-color-scheme: dark` block to that stylesheet.

Tests: `InkwellKit/Tests/InkwellKitTests/DesignTests.swift`. Each theme is applied to the fixture site and every page is rendered.

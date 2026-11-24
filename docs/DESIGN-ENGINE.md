# Design engine (`InkwellDesign`)

The non-UI half of milestone M3. Every editor works on the site's own files, line by line: unchanged files stay byte-identical, and an edit touches only what it changes.

## Editors

| Type | File | What it does |
|---|---|---|
| `CSSTokenDocument` | any stylesheet | Reads `--name: value;` properties in `:root` (or `html`) rules. A rule inside `@media (prefers-color-scheme: dark)` is the dark palette. `set(_:to:scheme:)` replaces only the value, and adds the property or the dark block when missing. Comments are ignored, and so is a final declaration with no `;`. |
| `ConfigDocument` | `_config.yml` | `value("inkwell.theme")` reads any depth. `set("title", raw:)` and `set("inkwell.theme", raw:)` write a top-level or one-level-nested key, creating the parent when needed. `raw: nil` removes the key. Values are already-formatted YAML (`YAMLFormat.quoted`, `.bool`, `.list`). |
| `NavigationDocument` | `_data/navigation.yml` | A list of `NavigationEntry(title:url:)`. You can `move`, append or remove entries. `text` writes the list back and keeps the comment lines at the top. |

## Themes

`ThemeManifest.bundled()` returns six themes, each different in structure as well as colour:

| Theme | Character | Own files |
|---|---|---|
| Essayist | centred serif column on warm paper, quiet centred header, small capitals, a drop cap | header, post layout, `theme.css` |
| Notebook | sticky sidebar with title, description and menu; compact dated list; a top bar on phones | default layout, header, `theme.css` |
| Photo journal | dark unless changed (`appearance: dark`); home page as a picture grid; full-bleed covers; wide photos in posts | home and post layouts, `theme.css` |
| Minimal | one monospaced face, dates in the margin, Markdown-style `#` headings, almost no chrome | `theme.css` |
| Magazine | masthead and ruled menu bar; a lead story with its picture, then cards under section labels; kickers from the first tag | header, kicker include, home and post layouts, `theme.css` |
| Studio | pill menu, a welcome with `site.inkwell.avatar` and `site.description`, rounded project cards with tags | header, home and post layouts, `theme.css` |

A theme folder holds `theme.json` and whatever it needs over the shared base (`Themes/_base`): layouts `default`, `post`, `page` and `home`; includes `inkwell-head` (title, Open Graph, stylesheets), `inkwell-header`, `inkwell-footer`, `inkwell-post-list` and `inkwell-cover` (sets `cover` to a post's `image`, else the first image in its text). `ThemeManifest.siteFiles` merges base and theme files (the theme wins). `inkwell.css` is the tokens, the base stylesheet, then the theme's `theme.css`.

Every default layout loads the element kit in `<head>` and has a skip link. The base stylesheet has focus outlines, reduced motion and phone widths. The page layout honours `wide: true` (a `is-wide` class on `<body>`) and `hide_title: true`. Layouts written elsewhere that use `layout: default` (album, slides) get the theme's frame.

Each `theme.json` lists at least the 13 tokens (colours with light and dark values, fonts, size, line height, width and corner radius), each with a label and group for the Design panel, plus its options and defaults. Labels, groups, option labels and summaries are keys in `Themes.xcstrings`. Fonts are system stacks only, so nothing is downloaded.

`home_style` keeps `list`, `cards` and `chain` in every theme; Photo journal adds `grid` and Magazine adds `front` (their defaults). Studio adds an `avatar` option (kind `image`).

### Previews and the sample site

`Themes/_sample` is a small made-up site (six posts with cover images drawn from gradients and curves, an About page, a Writing page, an avatar). It has no `theme.json`, so it is not a theme. `ThemeManifest.sampleSite` points to it.

`--render-theme-previews <folder>` (app launch flag) applies each theme to a copy of the sample site, draws the home page at 1280 × 800 through the preview's scheme handler, light and dark, and writes `<folder>/<id>/preview.png` and `preview-dark.png` at 1200 px wide. A picture over 240 KB is reduced to 256 colours. `--preview-path` and `--preview-size 390x1400` draw other pages and sizes for checking. Copy the results into the theme folders; `previewImage(dark:)` finds them. Put each flag before its value; a stray word on the command line is taken as a document to open and the app opens no window.

`ThemeTrial.make(theme:site:at:)` copies a site (without `.git`, `_site` and caches) to another folder and applies a theme there; it refuses a destination inside or around the site. The theme gallery uses it to preview a theme on the person's own posts (home, newest post, a page; light or dark; desktop or phone) before the file-by-file review.

### Presets

`DesignPresets.palettes(for:)` gives a theme's own colours ("Original") and six palettes of its family (paper, clean, night, editorial, soft), each with light and dark values for `--bg`, `--surface`, `--text`, `--muted`, `--accent` and `--border`. The data is in `DesignPresetData.swift`. Tests require text 7:1 and secondary text and accent 4.5:1 against both background and panels, in both palettes. `DesignPresets.fontPairings` are eight heading and body pairings of the named `fontStacks` (which the font menus also use). The Design panel applies them through `DesignModel.setTokens`, so they are ordinary token edits.

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

Tests: `DesignTests.swift` (each theme on the fixture site, every page rendered) and `ThemeGalleryTests.swift` (the sample site in every theme, page options, other layouts, contrast, presets, theme trials).

## Sass themes and the preview's site server

- `SassVariables` reads a Sass theme's `$name: value !default;` declarations and writes overrides (`$name: value;`) into the site's `assets/main.scss`, just above the import, as minima's documentation describes. `DesignTokens.load(siteRoot:themeRoot:)` falls back to these when the site has no Inkwell theme and no `:root` variables. `supportsColorSchemes` is false for them.
- `CSSTokenDocument` knows three palettes: the default `:root`, `prefers-color-scheme: dark`, and `prefers-color-scheme: light` (`ColorSchemeKind.lightMode`, for sites that are dark by default). `DesignTokens.invertedLightness` makes the starting point for a new palette.
- `ThemeReference.of(config)` maps `theme:` (the gem themes GitHub Pages supports, at the versions it uses) and `remote_theme:` to a GitHub repository. `ThemeCache` (InkwellSync) downloads it once into `~/Library/Caches/Inkwell/Themes`.
- `SiteResources` (InkwellTemplate) answers any path the way the built site would:
  - pages by URL, through their layouts, with GitHub Pages' default layouts;
  - static files from the site, then from the theme;
  - Liquid in front-matter files such as `feed.xml`;
  - `.css` compiled from `.scss`/`.sass`, with both `_sass` folders on the load path;
  - otherwise `404.html`.

  The preview's `WKURLSchemeHandler` uses it, so the whole site can be browsed.

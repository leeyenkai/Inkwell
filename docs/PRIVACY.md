# Privacy

Inkwell has no server and no account of its own. It sends nothing to its developer: no analytics, no crash reports, no usage counts.

## What leaves your Mac, and where it goes

- **GitHub.** Inkwell talks to GitHub with the sign-in you give it. It downloads your site, publishes changes you choose to publish, reads version history, and checks whether GitHub Pages has finished building. Your posts are sent only to the repository you picked, and only when you publish.
- **Update check.** Once a day (you can turn this off in Settings › General), and when you choose Check for Updates, Inkwell asks GitHub for the latest Inkwell release. The request carries nothing about you or your sites.
- **Themes.** When a site uses a GitHub Pages theme, Inkwell downloads that theme's files from GitHub once, so the preview matches the live site.
- **Check Links.** Only when you click it, Inkwell asks each site your posts link to whether the page still exists. Those sites see an ordinary request from your Mac.
- **Preview.** The preview shows your pages as a browser would, so anything your site's layouts load from elsewhere (web fonts, embedded videos, scripts) is loaded too. Nothing is kept between launches.

## What stays on your Mac

- **Your sign-in** is kept in your keychain and used only to talk to GitHub. It is never written to a file or a log.
- **Drafts** stay in `~/Library/Application Support/Inkwell` until you publish them. The site copy Inkwell works on lives there too.
- **Pictures** you add are resized and lose their location and camera details before they are saved into your site. The original file is never copied.
- **The error log** in `~/Library/Logs/Inkwell` holds error messages only, to help you report a problem. Help › Copy Diagnostics puts a summary on the clipboard for you to paste where you choose; Inkwell never sends it anywhere.

## Removing Inkwell

Sign out in Settings › Account to remove the sign-in from your keychain. Then delete the app and the folders above. Your site and its history stay on GitHub.

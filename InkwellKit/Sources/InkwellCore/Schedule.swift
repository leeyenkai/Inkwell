import Foundation

/// Posts dated in the future stay off the site until GitHub Pages next builds after that date. Pages only builds when
/// something is pushed, so an optional hourly workflow asks for a build when a scheduled post has just come due.
public enum Schedule {
    public static let workflowPath = ".github/workflows/inkwell-scheduled.yml"

    public static func isScheduled(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date > now
    }

    /// `future: true` in `_config.yml` builds future-dated posts straight away, so nothing waits.
    public static func publishesFutureNow(_ config: SiteConfig) -> Bool {
        config.raw["future"]?.bool == true
    }

    public static func hasWorkflow(siteRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: siteRoot.appending(path: workflowPath).path)
    }

    /// Runs hourly. It looks at the date of every post and collection entry (front matter `date:`, else the filename),
    /// read in the site's `timezone:`, and requests a Pages build only when one came due in the last three hours, so a
    /// delayed run still catches it. Sites built by their own Actions workflow need that workflow to run on a schedule instead.
    public static let workflow = #"""
    # Added by Inkwell. Rebuilds the site with GitHub Pages when a post dated in the future comes due.
    # Delete this file to stop; posts dated in the future then appear the next time anything is published.
    name: Publish scheduled posts

    on:
      schedule:
        - cron: "17 * * * *"
      workflow_dispatch:

    permissions:
      contents: read
      pages: write

    jobs:
      build-if-due:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - name: Find posts that just came due
            id: due
            run: |
              zone=$(sed -n 's/^timezone:[[:space:]]*["'"'"']\{0,1\}\([^"'"'"' #]*\).*/\1/p' _config.yml | head -n 1)
              export TZ="${zone:-UTC}"
              now=$(date +%s)
              due=""
              while IFS= read -r -d '' file; do
                stamp=$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit}
                  /^date:/ {sub(/^date:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; exit}' "$file")
                if [ -z "$stamp" ]; then
                  stamp=$(basename "$file" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
                fi
                [ -n "$stamp" ] || continue
                when=$(date -d "$stamp" +%s 2>/dev/null) || continue
                if [ "$when" -le "$now" ] && [ "$when" -gt $((now - 10800)) ]; then
                  due="$due $file"
                fi
              done < <(find . -path ./_site -prune -o -path ./node_modules -prune -o -path ./vendor -prune -o -type f \
                \( -path './_*/*.md' -o -path './_*/*.markdown' -o -path './_*/*.html' \) \
                -not -path './_layouts/*' -not -path './_includes/*' -not -path './_drafts/*' -not -path './_data/*' -print0)
              echo "Due:${due:- none}"
              if [ -n "$due" ]; then echo "build=true" >> "$GITHUB_OUTPUT"; fi
          - name: Ask GitHub Pages to rebuild
            if: steps.due.outputs.build == 'true'
            env:
              GH_TOKEN: ${{ github.token }}
            run: gh api --method POST "repos/${GITHUB_REPOSITORY}/pages/builds"

    """#
}

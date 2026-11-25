import Foundation

/// Posts dated in the future stay off the site until GitHub Pages next builds after that date. Pages only builds when
/// something is pushed, so an optional hourly workflow asks for a build when a scheduled post has just come due.
public enum Schedule {
    public static let workflowPath = ".github/workflows/inkwell-scheduled.yml"

    public static func isScheduled(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return date > now
    }

    /// Whether the site builds posts dated in the future straight away. GitHub Pages does unless `_config.yml` says
    /// `future: false` (its default is true, unlike plain Jekyll), so a missing key counts as true.
    public static func publishesFutureNow(_ config: SiteConfig) -> Bool {
        config.raw["future"]?.bool != false
    }

    /// Whether `_config.yml` sets `future: true` on purpose. Scheduling leaves that choice alone.
    public static func futureTurnedOn(_ config: SiteConfig) -> Bool {
        config.raw["future"]?.bool == true
    }

    /// Why the hourly workflow cannot publish a scheduled post on time on a site.
    public enum WorkflowBlocker: Sendable, Equatable {
        /// GitHub Pages runs the site's own Actions workflow, so asking Pages for a build does nothing.
        case builtByWorkflow
        /// Workflows live in `.github/` at the repository root, outside a site built from a folder such as /docs.
        case siteInFolder
        /// GitHub runs scheduled workflows only on the default branch.
        case notDefaultBranch(site: String, default: String)

        public var message: String {
            switch self {
            case .builtByWorkflow:
                localized("""
                This site is built by its own GitHub Actions workflow, so the post appears the first time that workflow runs \
                after its date.
                """)
            case .siteInFolder:
                localized("""
                GitHub runs workflows only from the repository root, and this site is in a folder, so the post appears the next \
                time you publish anything after its date.
                """)
            case let .notDefaultBranch(site, main):
                localized("""
                GitHub runs scheduled workflows only on the default branch (\(main)), and this site publishes from \(site), so the \
                post appears the next time you publish anything after its date.
                """)
            }
        }
    }

    /// Nil when the hourly workflow can publish scheduled posts on time. Unknown values (a local folder) do not block it.
    public static func workflowBlocker(sitePath: String, branch: String?, defaultBranch: String?, buildType: String?) -> WorkflowBlocker? {
        if buildType == "workflow" { return .builtByWorkflow }
        if !sitePath.isEmpty { return .siteInFolder }
        if let branch, let defaultBranch, branch != defaultBranch { return .notDefaultBranch(site: branch, default: defaultBranch) }
        return nil
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
          - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
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

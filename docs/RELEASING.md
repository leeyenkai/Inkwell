# Releasing a beta

1. Set `MARKETING_VERSION` in the Xcode project to the new version (for example 0.9.1) and raise `CURRENT_PROJECT_VERSION`.
   Every release needs a higher plain version: the update check compares `CFBundleShortVersionString` with the release tag,
   and a suffix such as `-beta.2` counts as older than the same version without one.
2. Run the checks: `cd InkwellKit && swift test --scratch-path ~/Library/Caches/InkwellBuild/spm`, then the publish, content and
   design self-tests against a fresh `scripts/make-sample-site.sh` copy (see CLAUDE.md).
3. `scripts/make-dmg.sh` writes `Inkwell-<version>.dmg` and its `.sha256` to `~/Library/Caches/InkwellBuild/release`.
4. Open the disk image on a clean account or Mac and go through first launch, sign-in, opening a site and publishing a draft
   to a throwaway repository.
5. Create a GitHub release in the repository named by `InkwellReleasesRepository` in `Config/Info.plist`, tagged
   `v<version>`, as a normal release (not a pre-release: the update check reads `releases/latest`, which skips pre-releases).
   Attach the disk image and its `.sha256`, and write short notes in Markdown. The repository must be public, or nobody
   else can see the release.

Notarization (a Developer ID certificate and `notarytool`) removes the Open Anyway step and the keychain prompt after each
update. It needs no code changes.

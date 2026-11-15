# Versioning and release checklist

`version.h` is the source of truth: MAJOR.MINOR.PATCH for the user-visible version
and an always-increasing integer build number. GitHub releases use `vVERSION`.
`--version`, About, bundle metadata, release assets and Homebrew use these values.
Drafts, prereleases and arbitrary main commits are not offered by the update checker.

## Prepare a release

1. Update `version.h`. Use PATCH for fixes, MINOR for compatible features and
   MAJOR for incompatible changes; always increment the build number.
2. Write the matching `CHANGELOG.md` section. Replace `Unreleased` with the
   release date before final review. Clearly retain hardware-verification limits.
3. Run `bash scripts/test.sh`, open a PR, and merge only after required CI passes.
4. From a clean, current main checkout, create and verify a signed annotated tag
   using the existing configured signing identity (never disable signing):

   ```bash
   git tag -s v2.3.0 -m "TrackPointD 2.3.0"
   git verify-tag v2.3.0
   git push origin v2.3.0
   ```

   Substitute the version from `version.h`. Never move an already published tag.

The tag workflow checks main ancestry, tag/version agreement, the changelog and
all tests, then creates a **draft** GitHub Release with source `.tar.gz`,
`SHA256SUMS`, generated stable Homebrew formula and patch notes. It does not
publish a prebuilt unsigned app or automatically publish the draft.

You can inspect the same assets locally with:

```bash
python3 scripts/release.py --ref HEAD --tag v2.3.0
```

## Publish and update Homebrew

1. Inspect the draft notes/assets and publish the GitHub Release.
2. Generate package metadata from that published release:

   ```bash
   python3 scripts/sync-homebrew.py             # print for inspection
   python3 scripts/sync-homebrew.py --write     # update only Formula/trackpointd.rb
   bash scripts/test.sh
   ```

   The helper accepts only a stable release, reads its packaged version without
   extracting or executing source, and computes SHA-256 from the exact release
   asset. It does not commit or push.
3. Submit and merge the formula update through a signed PR and required CI.
   Until that PR merges, Homebrew may still offer the preceding release. A
   release is not fully rolled out to Homebrew until this step is complete.
4. Verify `brew update`, `brew info hoyaaaa/trackpointd/trackpointd`, an install/
   upgrade, and `trackpointd --version` on a test Mac. Do not test with two running
   copies of the app.

The same repository is a custom tap; no separate tap repository or cross-repo
secret is needed:

```bash
brew tap hoyaaaa/trackpointd https://github.com/hoyaaaa/trackpoint-daemon-macos
brew install hoyaaaa/trackpointd/trackpointd
brew update && brew upgrade hoyaaaa/trackpointd/trackpointd
```

For development, explicitly request `brew install --HEAD hoyaaaa/trackpointd/trackpointd`.
HEAD builds are development builds, not stable GitHub Releases. Regular installs
use the latest promoted stable formula.

## Installation identity and limits

Homebrew builds the app from source and signs locally/ad-hoc. It does not run
`install.sh`, register Login Items, kill the installed app, or change privacy
permissions. Quit before upgrading and reopen afterward. Add the stable
`$(brew --prefix trackpointd)/TrackPointD.app` path to Login Items manually.
Use either Homebrew or `~/Applications/TrackPointD.app`, not two copies.

Ad-hoc upgrades may require Accessibility/Input Monitoring approval again.
Developer ID distribution and notarization require a separate signing setup;
this release pipeline deliberately distributes source, not a publicly signed app.

The app's update check is user-triggered, uses GitHub's latest published stable
release endpoint with a timeout, and never downloads or executes an installer.
It opens canonical release notes or copies the Homebrew upgrade command.

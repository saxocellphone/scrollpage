# CI builds

Every push (any branch), pull request, and `v*` tag runs [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) on a GitHub-hosted Apple-silicon macOS runner with the newest stable Xcode:

1. `swift build` (with tests, if the package has test targets)
2. `swift test --parallel` — failures fail the job; a pass/fail table is shown on the run's summary page and the xunit XML is uploaded as `test-results-*`
3. `make build` (or `scripts/ci-bundle-app.sh` if the Makefile has no `build` target) to produce an ad-hoc signed `Scrollpage.app`
4. Zip with `ditto` and upload as the artifact `Scrollpage-<shortsha>` (kept 14 days)
5. On a `v*` tag, attach the zip to a GitHub Release

If there's no `Package.swift` at the repo root, the workflow passes with a "CI skipped" notice. Runs on the same branch cancel older in-progress runs.

## Installing a build

The easiest way, with the [GitHub CLI](https://cli.github.com) (`brew install gh && gh auth login`):

```sh
scripts/install-latest.sh                      # latest green build of the current branch
scripts/install-latest.sh -b main              # ...of another branch
scripts/install-latest.sh --run-id 123456789   # a specific run (ID is in the run URL)
scripts/install-latest.sh --system             # install to /Applications instead of ~/Applications
scripts/install-latest.sh --reset-permissions  # also reset the Accessibility grant (see below)
```

It finds the newest successful run that has an app artifact, quits a running Scrollpage, installs it to `~/Applications`, removes the quarantine flag, and opens it. Outside a git checkout it defaults to the `cursor/trackpad-gestures-e8e6` branch.

To install by hand instead: open the repo's **Actions** tab, pick a green run, download `Scrollpage-<sha>` under **Artifacts**, unzip it (twice if your browser didn't), move `Scrollpage.app` to Applications, then run:

```sh
xattr -dr com.apple.quarantine ~/Applications/Scrollpage.app
```

## Releases

```sh
git tag v0.1.0 && git push origin v0.1.0
```

This creates a release with `Scrollpage-<sha>.zip` attached and auto-generated notes. Tags with a hyphen (`v0.2.0-beta.1`) are marked as pre-release.

## Gatekeeper and permissions

- Builds are **ad-hoc signed**, not notarized. Files downloaded through a browser are quarantined, and Gatekeeper will refuse to open them ("can't be opened" or "is damaged"). Fix this with `xattr -dr com.apple.quarantine` as shown above, or right-click › Open. The install script does this for you.
- Scrollpage needs **Camera** and **Accessibility** permissions. macOS ties these to the app's code signature, and every ad-hoc build has a different one, so **after installing a new build you'll usually have to re-grant Accessibility**: go to System Settings › Privacy & Security › Accessibility, select Scrollpage, click **−**, then click **+** and add it again. Alternatively, run `scripts/install-latest.sh --reset-permissions`, which runs `tccutil reset Accessibility <bundle id>` so you get a fresh prompt. Camera access may be re-prompted too.
- A stable signing identity (Developer ID, or a self-signed certificate passed as `SIGN_IDENTITY`) would keep permissions across updates. CI doesn't have one yet.

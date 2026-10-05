# CI builds

Every push (any branch), pull request, and `v*` tag runs [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) on a GitHub-hosted Apple-silicon macOS runner with the newest stable Xcode:

1. `swift build` (with tests, if the package has test targets)
2. `swift test --parallel` — failures fail the job; a pass/fail table is shown on the run's summary page and the xunit XML is uploaded as `test-results-*`
3. `make build` (or `scripts/ci-bundle-app.sh` if the Makefile has no `build` target) to produce `Scrollpage.app`, signed with the project's self-signed identity (see [Signing](#signing)), or ad hoc when the signing secrets aren't available
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

## Signing

macOS remembers the Camera and Accessibility approvals by the app's *designated requirement*. For an ad-hoc signature that is the build's hash, so every build needs approving again. Local builds (`make build`) and CI builds both sign with **Scrollpage Local Signing**, one self-signed certificate, so the requirement is the same for every build:

```
identifier "com.saxocellphone.scrollpage" and certificate leaf = H"8e58a9e4a7319acb515cc32302e927913bb709cf"
```

- Locally, `scripts/local-signing.sh` keeps the identity in a keychain in the clone's git directory (`.git/scrollpage-signing/`, shared by all worktrees, never committed).
- In CI, the repository secrets `SCROLLPAGE_SIGNING_P12` (the identity as a base64 PKCS#12) and `SCROLLPAGE_SIGNING_PASSWORD` (its password) are imported into a temporary keychain, `make build SIGN_IDENTITY=local` signs with it, and the keychain is deleted afterwards. The run summary shows the designated requirement.
- Without the secrets (a fork's pull request, or a fork of the repo), CI falls back to an ad-hoc signature with a warning.

Check a build with `codesign -dr - Scrollpage.app`. To move the identity to another machine, export it from the keychain as a `.p12` (`security export -k <keychain> -t identities -f pkcs12 -o identity.p12`, which asks for confirmation in a dialog) and import it with the commands in the workflow's *Import signing identity* step. To replace it, generate a new one as `scripts/local-signing.sh` does, put it in the local keychain, and update both secrets:

```sh
base64 -i identity.p12 | gh secret set SCROLLPAGE_SIGNING_P12
gh secret set SCROLLPAGE_SIGNING_PASSWORD   # prompts for the password
```

Changing the identity changes the requirement, so the next install needs the approvals once more.

## Gatekeeper and permissions

- Builds are self-signed (or ad hoc), not notarized. Files downloaded through a browser are quarantined, and Gatekeeper will refuse to open them ("can't be opened" or "is damaged"). Fix this with `xattr -dr com.apple.quarantine` as shown above, or right-click › Open. The install script does this for you.
- Scrollpage needs **Camera** and **Accessibility** permissions. With the shared identity, approving them once covers later local and CI builds. After installing an ad-hoc build, or the first build after the identity changed, re-grant Accessibility: go to System Settings › Privacy & Security › Accessibility, select Scrollpage, click **−**, then click **+** and add it again. Alternatively, run `scripts/install-latest.sh --reset-permissions`, which runs `tccutil reset Accessibility <bundle id>` so you get a fresh prompt. Camera access may be re-prompted too.

#!/usr/bin/env bash
# Download the newest successful CI build of Scrollpage and install it.
#
#   scripts/install-latest.sh [options]
#
# Options:
#   -b, --branch BRANCH    branch whose CI build to install
#                          (default: current git branch, else cursor/trackpad-gestures-e8e6)
#   -r, --run-id ID        install the artifact from a specific workflow run instead
#   -R, --repo OWNER/NAME  GitHub repo (default: $SCROLLPAGE_REPO or saxocellphone/scrollpage)
#   -s, --system           install to /Applications instead of ~/Applications
#       --reset-permissions  run `tccutil reset Accessibility <bundle id>` after installing
#       --no-open          don't launch the app after installing
#   -h, --help             show this help
set -euo pipefail

REPO="${SCROLLPAGE_REPO:-saxocellphone/scrollpage}"
WORKFLOW="ci.yml"
FALLBACK_BRANCH="cursor/trackpad-gestures-e8e6"
BRANCH=""
RUN_ID=""
DEST_DIR="$HOME/Applications"
RESET_PERMISSIONS=false
OPEN_APP=true

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; }
die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    -r|--run-id) RUN_ID="${2:?--run-id needs a value}"; shift 2 ;;
    -R|--repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    -s|--system) DEST_DIR="/Applications"; shift ;;
    --reset-permissions) RESET_PERMISSIONS=true; shift ;;
    --no-open) OPEN_APP=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

command -v gh >/dev/null || die "GitHub CLI not found. Install with: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

run_has_app_artifact() {
  gh api "repos/$REPO/actions/runs/$1/artifacts" \
    -q '[.artifacts[] | select(.expired | not) | select(.name | startswith("test-results") | not)] | length' \
    2>/dev/null | grep -qv '^0$'
}

if [[ -z "$RUN_ID" ]]; then
  if [[ -z "$BRANCH" ]]; then
    BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    BRANCH="${BRANCH:-$FALLBACK_BRANCH}"
  fi
  echo "==> Looking for the latest successful '$WORKFLOW' run on $REPO@$BRANCH"
  # Runs that skipped the build (no Package.swift) succeed without an artifact,
  # so walk back through recent successes until one has an app.
  candidates="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$BRANCH" \
    --status success -L 10 --json databaseId -q '.[].databaseId')"
  for id in $candidates; do
    if run_has_app_artifact "$id"; then
      RUN_ID="$id"
      break
    fi
  done
  [[ -n "$RUN_ID" ]] || die "no successful run with an app artifact found for branch '$BRANCH'.
       Check https://github.com/$REPO/actions/workflows/$WORKFLOW"
fi

run_info="$(gh run view "$RUN_ID" --repo "$REPO" --json headSha,headBranch,url,createdAt \
  -q '"\(.headBranch)@\(.headSha[0:7]) (\(.createdAt))  \(.url)"')"
echo "==> Using run $RUN_ID: $run_info"

WORK_DIR="$(mktemp -d -t scrollpage-install)"
trap 'rm -rf "$WORK_DIR"' EXIT

app_artifact="$(gh api "repos/$REPO/actions/runs/$RUN_ID/artifacts" \
  -q '[.artifacts[] | select(.expired | not) | select(.name | startswith("test-results") | not)][0].name')"
[[ -n "$app_artifact" && "$app_artifact" != "null" ]] || die "run $RUN_ID has no (unexpired) app artifact"

echo "==> Downloading artifact $app_artifact"
gh run download "$RUN_ID" --repo "$REPO" --name "$app_artifact" --dir "$WORK_DIR/download"

zip_path="$(find "$WORK_DIR/download" -name '*.zip' -print -quit)"
if [[ -n "$zip_path" ]]; then
  ditto -x -k "$zip_path" "$WORK_DIR/app"
  search_root="$WORK_DIR/app"
else
  search_root="$WORK_DIR/download"
fi
app_src="$(find "$search_root" -maxdepth 3 -name '*.app' -type d -print -quit)"
[[ -n "$app_src" ]] || die "no .app found inside artifact $app_artifact"

app_name="$(basename "$app_src")"
plist="$app_src/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || basename "$app_name" .app)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || echo '?')"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || echo '?')"
echo "==> $app_name  bundle id: ${bundle_id:-?}  version: $version ($build)"

if pgrep -x "$executable" >/dev/null; then
  echo "==> Quitting running $executable"
  if [[ -n "$bundle_id" ]]; then
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$executable" >/dev/null || break
    sleep 0.5
  done
  pkill -x "$executable" 2>/dev/null || true
  sleep 0.5
fi

SUDO=()
mkdir -p "$DEST_DIR" 2>/dev/null || true
if [[ ! -w "$DEST_DIR" ]]; then
  echo "==> $DEST_DIR is not writable; using sudo"
  SUDO=(sudo)
fi
dest="$DEST_DIR/$app_name"
echo "==> Installing to $dest"
${SUDO[@]+"${SUDO[@]}"} rm -rf "$dest"
${SUDO[@]+"${SUDO[@]}"} ditto "$app_src" "$dest"
${SUDO[@]+"${SUDO[@]}"} xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

if ! codesign --verify --deep --strict "$dest" 2>/dev/null; then
  echo "warning: code signature did not verify; macOS may refuse to launch it" >&2
fi

if [[ "$RESET_PERMISSIONS" == true ]]; then
  if [[ -n "$bundle_id" ]]; then
    echo "==> Resetting Accessibility permission for $bundle_id"
    tccutil reset Accessibility "$bundle_id" || echo "warning: tccutil reset failed" >&2
  else
    echo "warning: no bundle id in Info.plist; skipping --reset-permissions" >&2
  fi
fi

if [[ "$OPEN_APP" == true ]]; then
  echo "==> Launching $app_name"
  open "$dest"
fi

cat <<EOF

✓ Installed $dest

Note: CI builds are ad-hoc signed, so every build has a new code identity and
macOS treats it as a different app for privacy permissions. If gestures don't
move the cursor after updating, re-grant Accessibility:
  System Settings › Privacy & Security › Accessibility → select $app_name,
  click "−" to remove it, then "+" to add $dest again (or rerun this script
  with --reset-permissions and approve the prompt on next launch).
Camera access may also be re-prompted.
EOF

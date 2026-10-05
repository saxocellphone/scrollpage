#!/usr/bin/env bash
# Assemble build/<App>.app from a SwiftPM executable when the repo has no
# `make build` target. Used by .github/workflows/ci.yml; runnable locally.
#
# Env overrides:
#   EXECUTABLE     SwiftPM executable product (default: first executable in Package.swift)
#   APP_NAME       bundle name (default: $EXECUTABLE)
#   BUNDLE_ID      used only when no Info.plist is found (default: com.saxocellphone.<app>)
#   SIGN_IDENTITY  codesign identity (default: "-" = ad-hoc)
#   OUT_DIR        output directory (default: build)
set -euo pipefail

OUT_DIR="${OUT_DIR:-build}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ -z "${EXECUTABLE:-}" ]]; then
  EXECUTABLE="$(swift package dump-package | jq -r '
    ([.products[] | select(.type | has("executable")) | .name]
     + [.targets[] | select(.type == "executable") | .name]) | first // empty')"
fi
if [[ -z "$EXECUTABLE" ]]; then
  echo "error: no executable product/target found in Package.swift" >&2
  exit 1
fi
APP_NAME="${APP_NAME:-$EXECUTABLE}"
lower_name="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"
BUNDLE_ID="${BUNDLE_ID:-com.saxocellphone.$lower_name}"

echo "==> swift build -c release --product $EXECUTABLE"
swift build -c release --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

plist_src=""
for candidate in Info.plist Resources/Info.plist "Sources/$EXECUTABLE/Info.plist" "Sources/$EXECUTABLE/Resources/Info.plist"; do
  if [[ -f "$candidate" ]]; then
    plist_src="$candidate"
    break
  fi
done

PLIST="$APP/Contents/Info.plist"
if [[ -n "$plist_src" ]]; then
  echo "==> Using $plist_src"
  cp "$plist_src" "$PLIST"
else
  echo "==> No Info.plist found; generating a minimal menu-bar one ($BUNDLE_ID)"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCameraUsageDescription</key><string>$APP_NAME uses the camera to track hand gestures.</string>
</dict>
</plist>
EOF
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $EXECUTABLE" "$PLIST"

if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GITHUB_RUN_NUMBER" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $GITHUB_RUN_NUMBER" "$PLIST"
fi

shopt -s nullglob
for res_bundle in "$BIN_DIR"/*.bundle; do
  echo "==> Copying resource bundle $(basename "$res_bundle")"
  cp -R "$res_bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$PLIST" 2>/dev/null || true)"
if [[ -n "$icon_name" ]]; then
  icon_path="$(find Sources Resources -name "${icon_name%.icns}.icns" -print -quit 2>/dev/null || true)"
  [[ -n "$icon_path" ]] && cp "$icon_path" "$APP/Contents/Resources/"
fi

entitlements=()
for candidate in "$APP_NAME.entitlements" "Resources/$APP_NAME.entitlements" "Sources/$EXECUTABLE/$APP_NAME.entitlements"; do
  if [[ -f "$candidate" ]]; then
    entitlements=(--entitlements "$candidate")
    break
  fi
done

echo "==> codesign (${SIGN_IDENTITY})"
codesign --force --deep --sign "$SIGN_IDENTITY" ${entitlements[@]+"${entitlements[@]}"} "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "✓ $APP"

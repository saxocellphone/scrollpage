#!/bin/sh
# Usage: scripts/local-signing.sh [codesign options] path
#
# Signs with "Scrollpage Local Signing", a self-signed code signing identity,
# creating it on first use.
#
# macOS remembers privacy approvals (Accessibility, Camera) by the app's
# designated requirement. An ad hoc signature's requirement is its cdhash, so
# every rebuild loses the approvals. Signing with one certificate keeps the
# requirement (identifier + certificate) stable across rebuilds.
#
# The keychain lives in the git common dir, so it is never committed and every
# worktree of this clone signs with the same identity. codesign only finds
# identities in the keychain search list, so the keychain is added to it for
# the duration of the codesign call and the list is then restored. The login
# keychain and trust settings are not touched.
set -eu

NAME="Scrollpage Local Signing"
# Only protects a throwaway local key; the keychain is unlocked for each build.
PASS="scrollpage-local-signing"

if [ -n "${SCROLLPAGE_SIGNING_DIR:-}" ]; then
    DIR="$SCROLLPAGE_SIGNING_DIR"
elif COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    DIR="$COMMON/scrollpage-signing"
else
    DIR="$(cd "$(dirname "$0")/.." && pwd)/.signing"
fi
KEYCHAIN="$DIR/signing.keychain-db"

if [ ! -f "$KEYCHAIN" ]; then
    mkdir -p "$DIR"
    TMP=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -subj "/CN=$NAME" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$NAME" -out "$TMP/identity.p12" -passout "pass:$PASS"
    security create-keychain -p "$PASS" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null
    rm -rf "$TMP"
    echo "Created $NAME in $KEYCHAIN" >&2
fi

security unlock-keychain -p "$PASS" "$KEYCHAIN"
HASH=$(security find-identity -p codesigning "$KEYCHAIN" | awk -v n="\"$NAME\"" 'index($0, n) { print $2; exit }')
[ -n "$HASH" ] || { echo "No $NAME identity in $KEYCHAIN" >&2; exit 1; }

SEARCH=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//')
restore() {
    printf '%s\n' "$SEARCH" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s
}
trap 'restore' EXIT INT TERM
printf '%s\n' "$SEARCH" | tr '\n' '\0' | xargs -0 sh -c 'security list-keychains -d user -s "$@" "$0"' "$KEYCHAIN"
codesign --force --sign "$HASH" --timestamp=none "$@"

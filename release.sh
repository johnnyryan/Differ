#!/bin/zsh
# Builds build/Differ.dmg: a disk image with Differ and an Applications shortcut.
#
# With a "Developer ID Application" certificate in the keychain and notary credentials saved as the
# keychain profile "differ-notary", the app and the image are signed, notarised and stapled, so they
# open on any Mac without a security warning. One-time setup of the credentials:
#
#   xcrun notarytool store-credentials differ-notary
#
# Without a certificate the script stops. Pass --unsigned for an ad-hoc signed image, which macOS
# blocks on first launch when downloaded.
set -euo pipefail
cd "${0:A:h}"

PROFILE="${NOTARY_PROFILE:-differ-notary}"
APP="build/Differ.app"
DMG="build/Differ.dmg"
UNSIGNED=0
[[ "${1:-}" == "--unsigned" ]] && UNSIGNED=1

if (( UNSIGNED )); then
  unset SIGN_ID
else
  SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)}"
  if [[ -z "$SIGN_ID" ]]; then
    echo "No \"Developer ID Application\" certificate in the keychain (see the notes in this script)." >&2
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Notary credentials \"$PROFILE\" are missing or do not work. Run: xcrun notarytool store-credentials $PROFILE" >&2
    exit 1
  fi
  export SIGN_ID
fi

./build.sh

# notarytool exits 0 even when Apple rejects the upload, so the status itself is checked.
notarise() {
  local log="build/obj/notary.plist" id
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format plist > "$log"
  if [[ "$(plutil -extract status raw "$log")" != "Accepted" ]]; then
    id="$(plutil -extract id raw "$log")"
    echo "Notarisation of $1 failed:" >&2
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
}

if (( ! UNSIGNED )); then
  echo "Notarising the app…"
  ditto -c -k --keepParent "$APP" build/obj/Differ.zip
  notarise build/obj/Differ.zip
  xcrun stapler staple "$APP"
fi

echo "Making the disk image…"
STAGE=build/obj/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Differ.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Differ -srcfolder "$STAGE" -fs HFS+ -format UDZO -quiet "$DMG"

if (( ! UNSIGNED )); then
  codesign --force --timestamp -s "$SIGN_ID" "$DMG"
  echo "Notarising the disk image…"
  notarise "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  spctl -a -t exec -v "$APP"
fi
echo "Made $DMG"

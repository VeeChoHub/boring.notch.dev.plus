#!/bin/bash
# Build Boring Notch, sign it with a local certificate and install it in /Applications.
# The certificate (created on first run, stays in your login keychain) keeps macOS
# permissions like Accessibility and Calendar across rebuilds. Usage: ./install.sh
set -eo pipefail
cd "$(dirname "$0")"

CERT="Boring Notch Local"
APP="/Applications/Boring Notch.app"
BUILT="build/Build/Products/Release/Boring Notch.app"

if ! security find-certificate -c "$CERT" >/dev/null 2>&1; then
  echo "Creating local signing certificate \"$CERT\"..."
  tmp=$(mktemp -d)
  # /usr/bin/openssl is LibreSSL: its .p12 format is the one `security import` accepts
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$CERT" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/cert.p12" -passout pass:tmp
  security import "$tmp/cert.p12" -P tmp -T /usr/bin/codesign
  rm -rf "$tmp"
fi

# Hardened runtime off: with it, library validation rejects the prebuilt MediaRemoteAdapter.framework. UNIVERSAL=1 (release.sh): Apple Silicon + Intel
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath build ${UNIVERSAL:+-destination generic/platform=macOS} ENABLE_HARDENED_RUNTIME=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

# The Install button in Settings (Claude Code) registers this copy as the Claude Code hook.
# ponytail: copied here instead of an Xcode resource, the app is only built by this script
cp claude-hook.js "$BUILT/Contents/Resources/"

# Inside-out: the XPC helper asks for Accessibility, so it needs the stable signature too
codesign --force --sign "$CERT" --preserve-metadata=entitlements "$BUILT/Contents/XPCServices/BoringNotchXPCHelper.xpc"
codesign --force --sign "$CERT" --preserve-metadata=entitlements "$BUILT"

# osascript, not pkill: the app ignores SIGTERM
osascript -e 'quit app "Boring Notch"' || true
sleep 2
# The media adapter survives the app quitting, don't let old instances pile up
pkill -f "Boring Notch.app/Contents/Resources/mediaremote-adapter.pl" || true
rm -rf "$APP"
ditto "$BUILT" "$APP"
open "$APP"
echo "Installed and launched $APP"

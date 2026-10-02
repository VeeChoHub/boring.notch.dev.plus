#!/bin/bash
# Push + GitHub release of the fork, picked up by the in-app updater (Sparkle). Usage: ./release.sh [version]
# Without a version: the next 2.7.3-plus.N after the last tag. SUFeedURL points to the appcast.xml of the latest
# release, signed with the EdDSA key in the login keychain (Sparkle's generate_keys, once). Needs gh logged in.
set -eo pipefail
cd "$(dirname "$0")"
REPO=VeeChoHub/boring.notch.dev.plus
OUT=build/release
PBX=boringNotch.xcodeproj/project.pbxproj

# The release is built from the working tree: it must match the pushed commit
git diff --quiet HEAD || { echo "Uncommitted changes: commit them first"; exit 1; }
git fetch -q --tags origin # releases created on GitHub only have the tag there
LAST=$(git describe --tags --abbrev=0 --match 'v*-plus.*')
VERSION=${1:-$(echo "${LAST#v}" | awk -F. -v OFS=. '{ $NF++; print }')}

# Sparkle compares the build number (CFBundleVersion): bump it in every target
BUILD=$(( $(grep -m1 -oE 'CURRENT_PROJECT_VERSION = [0-9]+' $PBX | grep -oE '[0-9]+$') + 1 ))
sed -i '' -E -e "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $BUILD;/" \
  -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/" $PBX
echo "Releasing $VERSION (build $BUILD)"

# Universal build, also installed on this Mac
UNIVERSAL=1 ./install.sh

rm -rf "$OUT" && mkdir -p "$OUT/dmg" "$OUT/archives"
ditto "build/Build/Products/Release/Boring Notch.app" "$OUT/dmg/Boring Notch.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "Boring Notch" -srcfolder "$OUT/dmg" -format UDZO "$OUT/archives/boringNotch.dmg"
# Signs the dmg with the keychain key and writes the appcast entry pointing to this release's asset
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" -o "$OUT/appcast.xml" "$OUT/archives"

git commit -m "Release $VERSION" $PBX
git tag "v$VERSION"
git push origin HEAD "v$VERSION"
# --latest: SUFeedURL reads releases/latest
gh release create "v$VERSION" "$OUT/archives/boringNotch.dmg" "$OUT/appcast.xml" -R $REPO --latest \
  --title "Boring Notch $VERSION" --generate-notes --notes 'Fork of Boring Notch with Claude Code integration. Universal build, not notarized.

First install: move the app to /Applications, then run `xattr -dr com.apple.quarantine "/Applications/Boring Notch.app"`. Later versions arrive in the app through Check for Updates.'

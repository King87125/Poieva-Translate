#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Poieva Translate.app"
[[ -d "$APP_DIR" ]] || { print -u2 "Build the app with ./scripts/build-app.sh first."; exit 1; }
codesign --verify --deep --strict "$APP_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
[[ "$VERSION" =~ '^[0-9]+([.][0-9]+)*$' ]] || { print -u2 "Invalid app version."; exit 1; }
STAGING_ROOT="$(mktemp -d "$PROJECT_DIR/.build/dmg-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
mkdir -p "$STAGING_ROOT/contents"
ditto "$APP_DIR" "$STAGING_ROOT/contents/Poieva Translate.app"
ln -s /Applications "$STAGING_ROOT/contents/Applications"
OUTPUT="$PROJECT_DIR/dist/Poieva-Translate-$VERSION.dmg"
hdiutil create -volname "Poieva Translate" -srcfolder "$STAGING_ROOT/contents" -format UDZO "$STAGING_ROOT/Poieva.dmg"
hdiutil verify "$STAGING_ROOT/Poieva.dmg"
mv -f "$STAGING_ROOT/Poieva.dmg" "$OUTPUT"
print "Package: $OUTPUT"

#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Poieva Translate.app"
[[ -d "$APP_DIR" ]] || { print -u2 "Build the app with ./scripts/build-app.sh first."; exit 1; }
codesign --verify --deep --strict "$APP_DIR"
mkdir -p "$PROJECT_DIR/.build"
TOOLS_DIR="$PROJECT_DIR/.build/dmg-tools"
REQUIREMENTS="$PROJECT_DIR/scripts/requirements-dmg.txt"
if [[ ! -x "$TOOLS_DIR/bin/python3" ]]; then python3 -m venv "$TOOLS_DIR"; fi
if [[ ! -f "$TOOLS_DIR/requirements.txt" ]] || ! cmp -s "$REQUIREMENTS" "$TOOLS_DIR/requirements.txt"; then
    "$TOOLS_DIR/bin/python3" -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes -r "$REQUIREMENTS"
    cp "$REQUIREMENTS" "$TOOLS_DIR/requirements.txt"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
[[ "$VERSION" =~ '^[0-9]+([.][0-9]+)*$' ]] || { print -u2 "Invalid app version."; exit 1; }
STAGING_ROOT="$(mktemp -d "$PROJECT_DIR/.build/dmg-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
mkdir -p "$STAGING_ROOT/contents"
ditto "$APP_DIR" "$STAGING_ROOT/contents/Poieva Translate.app"
ln -s /Applications "$STAGING_ROOT/contents/Applications"
"$TOOLS_DIR/bin/python3" "$PROJECT_DIR/scripts/dmg-layout.py" "$STAGING_ROOT/contents"
OUTPUT="$PROJECT_DIR/dist/Poieva-Translate-$VERSION.dmg"
hdiutil create -volname "Poieva Translate" -fs HFS+ -srcfolder "$STAGING_ROOT/contents" -format UDZO "$STAGING_ROOT/Poieva.dmg"
hdiutil verify "$STAGING_ROOT/Poieva.dmg"
mv -f "$STAGING_ROOT/Poieva.dmg" "$OUTPUT"
(
    cd "$PROJECT_DIR/dist"
    shasum -a 256 "Poieva-Translate-$VERSION.dmg" > SHA256SUMS.txt
)
print "Package: $OUTPUT"

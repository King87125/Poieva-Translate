#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
swift build -c release --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" --config-path "$PROJECT_DIR/.build/config" --security-path "$PROJECT_DIR/.build/security"
APP_DIR="$PROJECT_DIR/dist/Poieva Translate.app"
PREVIOUS_APP="$APP_DIR"
LEGACY_APP="$PROJECT_DIR/dist/TypeBridge.app"
if [[ -d "$APP_DIR" && -d "$LEGACY_APP" ]]; then
    print -u2 "发现新旧两份应用，请先确认需要更新的版本后再构建。"
    exit 1
elif [[ ! -d "$APP_DIR" && -d "$LEGACY_APP" ]]; then
    PREVIOUS_APP="$LEGACY_APP"
fi
STAGING_ROOT="$(mktemp -d "$PROJECT_DIR/.build/app-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/Poieva Translate.app"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PREVIOUS_APP/Contents/Info.plist" 2>/dev/null || print 0)"
[[ "$CURRENT_BUILD" == <-> ]] || CURRENT_BUILD=0
NEXT_BUILD=$((CURRENT_BUILD + 1))
mkdir -p "$PROJECT_DIR/dist" "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp .build/release/TypeBridge "$STAGED_APP/Contents/MacOS/TypeBridge"
cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
cp -R Resources/Design "$STAGED_APP/Contents/Resources/Design"
cp LICENSE "$STAGED_APP/Contents/Resources/LICENSE"
cp -R .build/release/TypeBridge_TypeBridgeCore.bundle "$STAGED_APP/Contents/Resources/TypeBridge_TypeBridgeCore.bundle"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$STAGED_APP/Contents/Info.plist"
swift scripts/make-icon.swift "$PROJECT_DIR/.build/AppIcon.iconset" "$STAGED_APP/Contents/Resources/AppIcon.icns"
SERVICE_RELATIVE="Contents/XPCServices/TypeBridgeCredentials.xpc"
SERVICE_DIR="$STAGED_APP/$SERVICE_RELATIVE"
mkdir -p "$SERVICE_DIR/Contents/MacOS"
cp .build/release/TypeBridgeCredentials "$SERVICE_DIR/Contents/MacOS/TypeBridgeCredentials"
cp Resources/Credentials-Info.plist "$SERVICE_DIR/Contents/Info.plist"
# The service is the keychain reader. Reuse its complete signed bundle when
# source and metadata are unchanged, so even its CodeDirectory hash stays fixed.
PREVIOUS_SERVICE="$PREVIOUS_APP/$SERVICE_RELATIVE"
REUSE_SERVICE=0
if [[ -d "$PREVIOUS_SERVICE" ]]; then
    cp "$PREVIOUS_SERVICE/Contents/MacOS/TypeBridgeCredentials" "$STAGING_ROOT/previous-reader"
    cp "$SERVICE_DIR/Contents/MacOS/TypeBridgeCredentials" "$STAGING_ROOT/current-reader"
    # Normalize the signature and __LINKEDIT sizes only on disposable copies.
    codesign --remove-signature "$STAGING_ROOT/previous-reader"
    codesign --remove-signature "$STAGING_ROOT/current-reader"
    codesign --force --sign - --identifier studio.typebridge.mac.credentials "$STAGING_ROOT/previous-reader"
    codesign --force --sign - --identifier studio.typebridge.mac.credentials "$STAGING_ROOT/current-reader"
    if cmp -s "$STAGING_ROOT/previous-reader" "$STAGING_ROOT/current-reader" && cmp -s "$PREVIOUS_SERVICE/Contents/Info.plist" "$SERVICE_DIR/Contents/Info.plist"; then
        REUSE_SERVICE=1
    elif [[ "${TYPEBRIDGE_CREDENTIAL_SERVICE_UPGRADE:-0}" != "1" ]]; then
        print -u2 "密钥组件发生变化，已停止发布。请先完成该组件升级的密钥迁移验证。"
        exit 1
    fi
fi
if [[ "$REUSE_SERVICE" == "1" ]]; then
    rm -rf "$SERVICE_DIR"
    cp -R "$PREVIOUS_SERVICE" "$SERVICE_DIR"
    codesign --verify --strict "$SERVICE_DIR"
elif [[ -n "${TYPEBRIDGE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$TYPEBRIDGE_SIGN_IDENTITY" --identifier studio.typebridge.mac.credentials --timestamp=none "$SERVICE_DIR"
else
    python3 scripts/local-signing.py sign "$SERVICE_DIR" --identifier studio.typebridge.mac.credentials
fi
if [[ -n "${TYPEBRIDGE_SIGN_IDENTITY:-}" ]]; then
    if [[ "$TYPEBRIDGE_SIGN_IDENTITY" == "-" ]]; then
        print -u2 "不能使用会随编译变化的临时签名。请保留本机固定签名，或指定开发者证书。"
        exit 1
    fi
    codesign --force --sign "$TYPEBRIDGE_SIGN_IDENTITY" --timestamp=none "$STAGED_APP"
    PREVIOUS_REQUIREMENT="$(python3 scripts/local-signing.py requirement "$PREVIOUS_APP")"
    if [[ "$PREVIOUS_REQUIREMENT" == *certificate* ]]; then
        codesign --verify --strict -R "=$PREVIOUS_REQUIREMENT" "$STAGED_APP"
    fi
else
    python3 scripts/local-signing.py sign "$STAGED_APP" --previous "$PREVIOUS_APP"
fi
codesign --verify --strict "$STAGED_APP"
# Publish a complete, signed bundle with an updated build number. Do not expose
# a partially replaced executable/signature pair to macOS identity caches.
if [[ -d "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$STAGING_ROOT/Previous.app"; fi
if ! mv "$STAGED_APP" "$APP_DIR"; then
    if [[ -d "$STAGING_ROOT/Previous.app" ]]; then mv "$STAGING_ROOT/Previous.app" "$PREVIOUS_APP"; fi
    exit 1
fi
print "应用已生成：$APP_DIR"

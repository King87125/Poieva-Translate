#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
TEST_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ ! -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
    TEST_FRAMEWORKS="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi
TEST_SUPPORT="$(dirname "$TEST_FRAMEWORKS")/usr/lib"
swift test --disable-xctest --enable-swift-testing --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" --config-path "$PROJECT_DIR/.build/config" --security-path "$PROJECT_DIR/.build/security" -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TEST_SUPPORT" "$@"

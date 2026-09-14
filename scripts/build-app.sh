#!/bin/bash
# 命令行构建 MacOSRoute.app（等价于在 Xcode 中以 Release 配置 Build）
#   ./scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: ..." TEAM_ID=XXXXXXXXXX ./scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/build"

ARGS=(
    -project MacOSRoute.xcodeproj
    -scheme MacOSRoute
    -configuration Release
    SYMROOT="$OUT/Products"
    OBJROOT="$OUT/Intermediates"
)
if [ -n "${SIGN_IDENTITY:-}" ]; then
    ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="${TEAM_ID:-}")
fi

xcodebuild "${ARGS[@]}" clean build

APP="$OUT/Products/Release/MacOSRoute.app"
codesign --verify --strict --deep "$APP"
echo "✅ 完成: $APP"

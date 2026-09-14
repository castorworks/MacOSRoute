#!/bin/bash
# 发布构建：Archive → Developer ID 签名并提交 Apple 公证（使用 Xcode 中登录的账号）→ 等待公证并装订 → 打包 DMG
#   ./scripts/release.sh
# 产物：build/release/MacOSRoute-<版本>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=build/release
ARCHIVE=$OUT/MacOSRoute.xcarchive
APP=$OUT/notarized/MacOSRoute.app

rm -rf "$OUT"
mkdir -p "$OUT"

echo "▶ Archive"
xcodebuild archive -project MacOSRoute.xcodeproj -scheme MacOSRoute -configuration Release \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet

echo "▶ Developer ID 签名并提交公证"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist Config/ExportOptions-DeveloperID.plist \
    -exportPath "$OUT/export" -allowProvisioningUpdates -quiet

echo "▶ 等待公证结果"
for i in $(seq 1 90); do
    if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$OUT/notarized" -allowProvisioningUpdates -quiet >/dev/null 2>&1; then
        break
    fi
    [ "$i" = 90 ] && { echo "❌ 等待公证超时，可在 Xcode Organizer 中查看状态"; exit 1; }
    sleep 20
done

echo "▶ 校验"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" || { echo "❌ Gatekeeper 校验未通过"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=$OUT/MacOSRoute-$VERSION.dmg
echo "▶ 打包 $DMG"
STAGING=$OUT/dmg
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/MacOSRoute.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "MacOSRoute $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"

shasum -a 256 "$DMG"
echo "✅ 完成：$DMG"

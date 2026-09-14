#!/bin/bash
# 从 Icon Composer 文档导出 PNG：
#   - 后台服务图标 → App 内使用的 HelperIcon 图片资源
#   - 两个图标的 1024px 预览 → Design/Icons/Exports（用于 README、网站等）
# 修改 Design/Icons/HelperIcon.icon 或 Sources/MacOSRoute/AppIcon.icon 后运行。
set -euo pipefail

cd "$(dirname "$0")/.."
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[ -x "$ICTOOL" ] || { echo "❌ 未找到 ictool，请安装 Xcode 26 或更新版本"; exit 1; }

render() { # <icon> <output> <points> <scale> [rendition]
    "$ICTOOL" "$1" --export-image --output-file "$2" --platform macOS --rendition "${5:-Default}" --width "$3" --height "$3" --scale "$4" >/dev/null
}

HELPER=Design/Icons/HelperIcon.icon
APP=Sources/MacOSRoute/AppIcon.icon
SET=Sources/MacOSRoute/Assets.xcassets/HelperIcon.imageset
EXPORTS=Design/Icons/Exports
mkdir -p "$SET" "$EXPORTS"

render "$HELPER" "$SET/HelperIcon.png" 128 1
render "$HELPER" "$SET/HelperIcon@2x.png" 128 2
render "$HELPER" "$SET/HelperIcon-dark.png" 128 1 Dark
render "$HELPER" "$SET/HelperIcon-dark@2x.png" 128 2 Dark
cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "HelperIcon.png", "idiom" : "universal", "scale" : "1x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "HelperIcon-dark.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "HelperIcon@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "HelperIcon-dark@2x.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

for rendition in Default Dark; do
    render "$APP" "$EXPORTS/AppIcon-$rendition.png" 1024 1 "$rendition"
    render "$HELPER" "$EXPORTS/HelperIcon-$rendition.png" 1024 1 "$rendition"
done
echo "✅ 已导出到 $SET 与 $EXPORTS"

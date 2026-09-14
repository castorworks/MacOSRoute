#!/bin/bash
# 生成发布截图（2880×1800，中英文）
#   ./scripts/screenshots.sh
# 流程：Debug 构建 → 在用户域启动演示用 Helper（dry run，不修改系统路由）并写入演示规则
#       → App 截图模式截取主窗口 → 用 ImageMagick 合成带标题的宣传图 → OCR 检查禁用词
# 依赖：Xcode、ImageMagick（brew install imagemagick）
# 注意：系统路由表、诊断两页读取的是本机真实网络信息，不用于发布截图。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
WORK=$(mktemp -d)
OUT=$ROOT/Design/Screenshots
LABEL=com.hyperits.app.MacOSRoute.helper
APP=$ROOT/build/Products/Debug/MacOSRoute.app
FONT="/System/Library/Fonts/STHeiti Medium.ttc"
FONT_LIGHT="/System/Library/Fonts/STHeiti Light.ttc"
[ -f "$FONT_LIGHT" ] || FONT_LIGHT=$FONT
BANNED_WORDS="VPN"

cleanup() {
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -rf "$WORK" "${TMPDIR:-/tmp}/MacOSRouteHelperDev"
}
trap cleanup EXIT

echo "▶ Debug 构建"
xcodebuild -project MacOSRoute.xcodeproj -scheme MacOSRoute -configuration Debug build -allowProvisioningUpdates \
    SYMROOT="$ROOT/build/Products" OBJROOT="$ROOT/build/Intermediates" -quiet

echo "▶ 启动演示 Helper"
cleanup; WORK=$(mktemp -d)
cat > "$WORK/helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/$LABEL</string><string>--allow-unsigned-clients</string></array>
<key>MachServices</key><dict><key>$LABEL</key><true/></dict>
<key>RunAtLoad</key><true/>
</dict></plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$WORK/helper.plist"
sleep 2

cat > "$WORK/seed.swift" <<'SWIFT'
import Foundation
@objc(RouteHelperProtocol) protocol RouteHelperProtocol {
    func fetchState(withReply reply: @escaping (Data?, String?) -> Void)
    func updateConfig(_ configData: Data, withReply reply: @escaping (String?, Bool) -> Void)
    func reapplyAll(withReply reply: @escaping (String?) -> Void)
    func removeAllRoutes(withReply reply: @escaping (String?) -> Void)
    func deleteSystemRoutes(_ addresses: [String], withReply reply: @escaping (String?) -> Void)
}
let connection = NSXPCConnection(machServiceName: CommandLine.arguments[1], options: [])
connection.remoteObjectInterface = NSXPCInterface(with: RouteHelperProtocol.self)
connection.resume()
let helper = connection.remoteObjectProxyWithErrorHandler { print("XPC error: \($0)"); exit(1) } as! RouteHelperProtocol
helper.updateConfig(try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) { error, conflict in
    if let error { print(error); exit(1) }
    helper.reapplyAll { _ in exit(conflict ? 1 : 0) }
}
RunLoop.main.run(until: Date().addingTimeInterval(60))
exit(1)
SWIFT
swiftc -O "$WORK/seed.swift" -o "$WORK/seed"
"$WORK/seed" "$LABEL" "$OUT/demo-config.json"

echo "▶ 截取窗口（App 窗口会在屏幕上出现约半分钟）"
mkdir -p "$WORK/raw"
MACOSROUTE_DEV_AGENT=1 MACOSROUTE_SCREENSHOT_DIR="$WORK/raw" "$APP/Contents/MacOS/MacOSRoute" | grep "screenshot:" || true

echo "▶ 合成宣传图"
compose() { # 原图 渐变起 渐变止 标题 副标题 输出
    magick -size 2880x1800 gradient:"$2"-"$3" \
        \( "$WORK/raw/$1" -resize 2240x \( +clone -background "#000000" -shadow 45x36+0+28 \) +swap -background none -layers merge +repage \) \
        -gravity north -geometry +0+430 -composite \
        -font "$FONT" -pointsize 104 -fill white -gravity north -annotate +0+120 "$4" \
        -font "$FONT_LIGHT" -pointsize 50 -fill "rgba(255,255,255,0.82)" -gravity north -annotate +0+270 "$5" \
        -depth 8 "$6"
}
rm -f "$OUT"/*.png
compose rules-dark.png  "#2A44A0" "#0B8F87" "指定流量，始终直连" "IP、网段和域名固定经由物理网关访问" "$OUT/zh-1-direct.png"
compose rules-light.png "#1F6FB0" "#12A58F" "切换 Wi-Fi，路由自动跟上" "后台服务监听网络变化，自动修正每一条路由" "$OUT/zh-2-auto.png"
compose logs-dark.png   "#2B2F3A" "#0F5F63" "每一次变更，都有记录" "自动解析域名、校验路由，全过程可追溯" "$OUT/zh-3-logs.png"
compose rules-dark.png  "#2A44A0" "#0B8F87" "Always direct for what matters" "Route chosen IPs, networks and domains through your physical gateway" "$OUT/en-1-direct.png"
compose rules-light.png "#1F6FB0" "#12A58F" "Switch Wi-Fi. Routes follow." "A background service re-applies every route when your network changes" "$OUT/en-2-auto.png"
compose logs-dark.png   "#2B2F3A" "#0F5F63" "Every change, on the record" "Domains resolved, routes verified, every step logged" "$OUT/en-3-logs.png"

echo "▶ OCR 检查禁用词：$BANNED_WORDS"
cat > "$WORK/ocr.swift" <<'SWIFT'
import AppKit
import Vision
var failed = false
for path in CommandLine.arguments.dropFirst(2) {
    let image = NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let request = VNRecognizeTextRequest()
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.recognitionLevel = .accurate
    try! VNImageRequestHandler(cgImage: image).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    for word in CommandLine.arguments[1].split(separator: ",") where text.localizedCaseInsensitiveContains(String(word)) {
        print("❌ \(URL(fileURLWithPath: path).lastPathComponent) 含有「\(word)」")
        failed = true
    }
}
exit(failed ? 1 : 0)
SWIFT
swiftc -O "$WORK/ocr.swift" -o "$WORK/ocr"
"$WORK/ocr" "$BANNED_WORDS" "$OUT"/*.png "$WORK"/raw/rules-*.png "$WORK"/raw/logs-*.png

echo "✅ 截图已生成：$OUT"

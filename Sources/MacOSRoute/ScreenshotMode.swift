#if DEBUG
import AppKit
import SwiftUI

/// 仅 Debug 构建：生成发布截图。
/// 用法：MACOSROUTE_DEV_AGENT=1 MACOSROUTE_SCREENSHOT_DIR=<目录> MacOSRoute.app/Contents/MacOS/MacOSRoute
/// App 会依次切换各页面和浅色 / 深色外观，截取自身主窗口（无需屏幕录制权限），完成后退出。
@MainActor
enum ScreenshotMode {
    private static var started = false

    static func startIfRequested(navigation: AppNavigation) {
        guard !started, let dir = ProcessInfo.processInfo.environment["MACOSROUTE_SCREENSHOT_DIR"] else { return }
        started = true
        Task { await run(outputDirectory: URL(fileURLWithPath: dir), navigation: navigation) }
    }

    private static func run(outputDirectory: URL, navigation: AppNavigation) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let pages: [(AppNavigation.Section, String)] = [(.rules, "rules"), (.routeTable, "routetable"), (.diagnostics, "diagnostics"), (.logs, "logs"), (.settings, "settings")]
        await pause(3)
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(AppWindow.mainID) == true }) else {
            print("screenshot: main window not found")
            exit(1)
        }
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (section, name) in pages {
                if section == .diagnostics {
                    navigation.diagnose(ProcessInfo.processInfo.environment["MACOSROUTE_SCREENSHOT_DIAGNOSE"] ?? "www.baidu.com")
                } else {
                    navigation.section = section
                }
                window.orderFrontRegardless()
                await pause(section == .diagnostics ? 7 : 1.5)
                capture(window, to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        exit(0)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            print("screenshot: capture failed for \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("screenshot: \(url.lastPathComponent) \(image.width)x\(image.height)")
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
#endif

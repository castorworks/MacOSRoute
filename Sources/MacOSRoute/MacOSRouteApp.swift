import AppKit
import RouteShared
import SwiftUI

@main
struct MacOSRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var client = HelperClient()
    @StateObject private var navigation = AppNavigation()

    var body: some Scene {
        Window("MacOSRoute", id: AppWindow.mainID) {
            MainView()
                .environmentObject(client)
                .environmentObject(navigation)
                .frame(minWidth: 900, minHeight: 520)
                .onAppear { AppWindow.mainWindowDidAppear() }
                .onDisappear { AppWindow.mainWindowDidDisappear() }
        }
        .defaultSize(width: 1080, height: 640)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(client)
                .environmentObject(navigation)
        } label: {
            MenuBarLabel(symbol: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        guard client.status == .running, client.state?.gateway != nil else { return "exclamationmark.triangle" }
        return client.isPaused ? "pause.circle" : "arrow.triangle.branch"
    }
}

/// 菜单栏图标；同时保存 openWindow，供 AppDelegate 等非视图代码打开主窗口
private struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear { AppWindow.openWindowAction = openWindow }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 从访达、Spotlight 或 Dock 再次打开 App 时显示主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppWindow.showMain() }
        return false
    }
}

@MainActor
enum AppWindow {
    static let mainID = "main"
    static var openWindowAction: OpenWindowAction?

    /// 打开并前置主窗口。
    /// 菜单栏 App（LSUIElement）在 macOS 14+ 的协作式激活下，仅调用 openWindow 窗口会停留在其他 App 之后，
    /// 因此先切换为普通 App，再显式前置窗口。
    static func showMain(_ openWindow: OpenWindowAction? = nil) {
        if let openWindow { openWindowAction = openWindow }
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            bringToFront(window)
        } else {
            openWindowAction?(id: mainID)
        }
        NSApp.activate()
        // 新建窗口在下一轮 run loop 才出现
        DispatchQueue.main.async {
            if let window = mainWindow { bringToFront(window) }
            NSApp.activate()
        }
    }

    static func mainWindowDidAppear() {
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow { bringToFront(window) }
        NSApp.activate()
    }

    static func mainWindowDidDisappear() {
        // 主窗口关闭后恢复为纯菜单栏 App（不占 Dock）
        DispatchQueue.main.async {
            if mainWindow?.isVisible != true {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(mainID) == true && !($0 is NSPanel) }
    }

    private static func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

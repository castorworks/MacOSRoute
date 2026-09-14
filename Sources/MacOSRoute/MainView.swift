import RouteShared
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation

    var body: some View {
        NavigationSplitView {
            List(AppNavigation.Section.allCases, selection: $navigation.section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                HelperBanner()
                switch navigation.section ?? .rules {
                case .rules: RulesView()
                case .routeTable: RouteTableView()
                case .diagnostics: DiagnosticsView()
                case .logs: LogsView()
                case .settings: SettingsView()
                }
            }
        }
        #if DEBUG
        .onAppear { ScreenshotMode.startIfRequested(navigation: navigation) }
        #endif
        .alert("提示", isPresented: Binding(get: { client.alertMessage != nil }, set: { if !$0 { client.alertMessage = nil } })) {
            Button("好") { client.alertMessage = nil }
        } message: {
            Text(client.alertMessage ?? "")
        }
    }
}

/// 窗口顶部：Helper 状态、当前物理网关与全局开关
struct HelperBanner: View {
    @EnvironmentObject private var client: HelperClient

    var body: some View {
        HStack(spacing: 12) {
            switch client.status {
            case .checking:
                ProgressView().controlSize(.small)
                Text("正在连接后台服务…")
                Spacer()
            case .notInstalled:
                helperIcon
                Text("需要安装后台服务才能修改系统路由，只需输入一次管理员密码。")
                Spacer()
                installButton("安装后台服务")
            case .outdated(let installed):
                helperIcon
                Text("后台服务版本 \(installed) 需要更新到 \(RouteConstants.helperVersion)，更新前无法修改规则。")
                Spacer()
                installButton("更新后台服务")
            case .unreachable(let message):
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
                Text("无法连接后台服务：\(message)").lineLimit(1)
                Spacer()
                installButton("重新安装")
            case .running:
                GatewayLabel()
                Spacer()
                if let date = client.state?.lastApplyAt {
                    Text("同步于 \(date.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Toggle(isOn: Binding(get: { !client.isPaused }, set: { client.setPaused(!$0) })) {
                    Text(client.isPaused ? "已暂停" : "生效中")
                }
                .toggleStyle(.switch)
                .help("暂停会移除所有由 MacOSRoute 添加的路由，恢复后重新应用")
                Button {
                    client.reapply()
                } label: {
                    Label("重新应用", systemImage: "arrow.clockwise")
                }
                .help("重新探测网关、重新解析域名并校验全部路由")
                .disabled(client.isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(client.isPaused && client.status == .running ? AnyShapeStyle(Color.orange.opacity(0.12)) : AnyShapeStyle(.bar))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var helperIcon: some View {
        Image("HelperIcon")
            .resizable()
            .frame(width: 28, height: 28)
    }

    private func installButton(_ title: String) -> some View {
        Button(title) { client.installHelper() }
            .buttonStyle(.borderedProminent)
            .disabled(client.isBusy)
    }
}

struct GatewayLabel: View {
    @EnvironmentObject private var client: HelperClient

    var body: some View {
        if let gw = client.state?.gateway {
            Label {
                Text("物理网关 ") + Text(gw.router).monospaced().bold() + Text("  ·  \(gw.interface)").foregroundColor(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Label("未检测到物理网关，现有路由保持不变", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}

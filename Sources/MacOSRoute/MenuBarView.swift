import AppKit
import RouteShared
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if client.canModify {
                HStack {
                    TextField("添加 IP / 域名", text: $input)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("添加", action: add)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !client.groups.isEmpty {
                    groupToggles
                }

                if !client.rules.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(client.rules) { rule in
                                ruleRow(rule)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            } else {
                Text(statusMessage).foregroundStyle(.secondary)
                Button(client.status == .notInstalled ? "安装后台服务" : "更新后台服务") { client.installHelper() }
                    .disabled(client.isBusy)
            }

            Divider()

            HStack {
                Button("打开主窗口", action: openMainWindow)
                Button("重新应用") { client.reapply() }
                    .disabled(!client.canModify || client.isBusy)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            Text("退出 App 不影响已设置的路由，后台服务会继续维护。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360)
    }

    private var statusMessage: String {
        switch client.status {
        case .notInstalled: return "后台服务未安装"
        case .outdated(let v): return "后台服务 \(v) 需要更新"
        case .checking: return "正在连接后台服务…"
        default: return "后台服务未运行"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("MacOSRoute").font(.headline)
                Spacer()
                if client.canModify {
                    Toggle(client.isPaused ? "已暂停" : "生效中", isOn: Binding(get: { !client.isPaused }, set: { client.setPaused(!$0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            if client.canModify {
                GatewayLabel().font(.callout)
                let enabled = client.rules.filter(\.enabled)
                let ok = enabled.filter { RuleRow(rule: $0, status: client.status(for: $0), paused: client.isPaused).health == .ok }.count
                Text("\(enabled.count) 条启用规则，\(ok) 条完全生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var groupToggles: some View {
        HStack(spacing: 6) {
            Text("分组").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(client.groups, id: \.self) { group in
                        let rules = client.rules.filter { $0.group == group }
                        let on = rules.contains(where: \.enabled)
                        Button {
                            client.setGroupEnabled(group, enabled: !on)
                        } label: {
                            Text(group)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(on ? "点击停用分组「\(group)」" : "点击启用分组「\(group)」")
                    }
                }
            }
        }
    }

    private func ruleRow(_ rule: RouteRule) -> some View {
        let row = RuleRow(rule: rule, status: client.status(for: rule), paused: client.isPaused)
        return HStack {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { client.setEnabled($0, for: [rule.id]) }))
                .labelsHidden()
                .controlSize(.mini)
                .toggleStyle(.switch)
            Text(rule.target).monospaced().lineLimit(1)
            if rule.via != .physical {
                Text(rule.via.label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(row: row)
                .labelStyle(.iconOnly)
        }
        .help(row.detailText)
        .contextMenu {
            Button("诊断") {
                navigation.diagnose(rule.target)
                openMainWindow()
            }
        }
    }

    private func openMainWindow() {
        dismiss() // 先收起菜单栏面板，避免它挡住主窗口或抢走焦点
        AppWindow.showMain(openWindow)
    }

    private func add() {
        let invalid = client.addTargets(from: input)
        input = invalid.joined(separator: " ")
    }
}

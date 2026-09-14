import AppKit
import RouteShared
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var client: HelperClient
    @State private var confirmUninstall = false
    @State private var customServersText = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var config: HelperConfig { client.config ?? HelperConfig() }

    var body: some View {
        Form {
            Section("通用") {
                Toggle("登录时启动 MacOSRoute", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Text("只影响菜单栏 App。后台服务由系统在开机时启动，退出 App 后路由仍会继续维护。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("物理网关") {
                Picker("出口网卡", selection: Binding(get: { config.interface }, set: { value in client.mutateConfig { $0.interface = value } })) {
                    Text("自动（跟随 Wi-Fi / 有线切换，推荐）").tag(HelperConfig.automaticInterface)
                    ForEach(physicalInterfaceOptions, id: \.self) { Text($0).tag($0) }
                }
                Text("自动模式会跳过 VPN 隧道（utun、ipsec、ppp 等），按系统网络服务顺序选择物理网卡的网关。规则的“出口”选择“物理网关”时使用这里的结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section("域名解析") {
                Picker("DNS", selection: Binding(get: { config.dnsMode }, set: { value in client.mutateConfig { $0.dnsMode = value } })) {
                    ForEach(DNSMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if config.dnsMode == .custom {
                    TextField("DNS 服务器（逗号分隔）", text: $customServersText, prompt: Text("223.5.5.5, 119.29.29.29"))
                        .onSubmit(saveCustomServers)
                }
                Text(dnsModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(value: Binding(get: { config.dnsRefreshMinutes }, set: { value in client.mutateConfig { $0.dnsRefreshMinutes = value } }), in: 1...1440) {
                    LabeledContent("重新解析间隔", value: "\(config.dnsRefreshMinutes) 分钟")
                }
                Stepper(value: Binding(get: { config.dnsRetentionHours }, set: { value in client.mutateConfig { $0.dnsRetentionHours = value } }), in: 0...168) {
                    LabeledContent("旧 IP 保留时间", value: config.dnsRetentionHours == 0 ? "不保留" : "\(config.dnsRetentionHours) 小时")
                }
                Text("CDN 域名的 IP 经常轮换。解析结果变化后，旧 IP 的路由会继续保留一段时间，避免已建立的连接突然改走 VPN。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section("规则") {
                HStack {
                    Button("导入…", action: importConfig)
                    Button("导出…", action: exportConfig)
                }
                Text("导入支持本 App 导出的 JSON，也支持每行一个 IP / 网段 / 域名的纯文本。已存在的目标会跳过。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!client.canModify)

            Section("关于") {
                LabeledContent("版本", value: Self.versionText)
                LabeledContent("开发者", value: "Chongqing Hyperits Network Technology Co., Ltd.")
                LabeledContent("隐私政策") {
                    Link("查看", destination: Self.privacyPolicyURL)
                }
            }

            Section("后台服务") {
                HStack(spacing: 12) {
                    Image("HelperIcon")
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacOSRoute 后台服务").font(.headline)
                        Text("以 root 身份运行，监听网络变化并维护路由。在“系统设置 → 通用 → 登录项与扩展”中显示为 MacOSRoute。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("状态", value: statusText)
                LabeledContent("App 需要的版本", value: RouteConstants.helperVersion)
                LabeledContent("配置目录", value: RouteConstants.supportDirectory)
                LabeledContent("日志", value: RouteConstants.helperLogPath)
                HStack {
                    Button(client.isInstalled ? "重新安装" : "安装") { client.installHelper() }
                    Button("卸载…", role: .destructive) { confirmUninstall = true }
                        .disabled(!client.isInstalled)
                }
                .disabled(client.isBusy)
            }
        }
        .formStyle(.grouped)
        .onAppear { customServersText = config.customDNSServers.joined(separator: ", ") }
        .onChange(of: config.customDNSServers) { _, servers in customServersText = servers.joined(separator: ", ") }
        .confirmationDialog("卸载后台服务？", isPresented: $confirmUninstall) {
            Button("删除已添加的路由并卸载", role: .destructive) { client.uninstallHelper() }
        } message: {
            Text("卸载后路由规则不再生效。规则配置会保留，重新安装即可恢复。")
        }
    }

    private static let privacyPolicyURL = URL(string: "https://github.com/castorworks/Privacy/blob/main/MacOSRoute/privacy-zh.md")!

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    private var dnsModeHelp: String {
        switch config.dnsMode {
        case .physical:
            return "经由物理网卡向当前网络的 DNS 查询，查询失败时改用公共 DNS。能绕过 VPN 的 DNS 和 Surge / Clash 的 Fake-IP，得到与物理网络匹配的 IP。"
        case .system:
            return "使用系统解析器。开启 VPN 或代理增强模式时，可能得到海外节点 IP 或 Fake-IP（198.18.x.x，会被自动忽略）。"
        case .custom:
            return "经由物理网卡向指定的 DNS 服务器查询。按回车保存。"
        }
    }

    private var physicalInterfaceOptions: [String] {
        var names = (client.state?.interfaces ?? []).filter { !$0.isVirtual && $0.router != nil }.map(\.name)
        if config.interface != HelperConfig.automaticInterface, !names.contains(config.interface) {
            names.append(config.interface)
        }
        return names
    }

    private var statusText: String {
        switch client.status {
        case .checking: return "检查中"
        case .notInstalled: return "未安装"
        case .running: return "运行中（\(client.state?.version ?? "")）"
        case .outdated(let v): return "需要更新（已安装 \(v)）"
        case .unreachable(let msg): return "无法连接：\(msg)"
        }
    }

    private func saveCustomServers() {
        let servers = TargetParser.splitInput(customServersText).filter { TargetParser.ipv4Value($0) != nil }
        client.mutateConfig { $0.customDNSServers = servers }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            client.alertMessage = "设置登录启动失败: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func exportConfig() {
        guard var config = client.config else { return }
        config.revision = 0
        guard let data = try? RouteJSON.encoder().encode(config) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacOSRoute-rules.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            client.alertMessage = "导出失败: \(error.localizedDescription)"
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if let imported = try? RouteJSON.decoder().decode(HelperConfig.self, from: data) {
            client.mutateConfig { config in
                let existing = Set(config.rules.map { $0.target.lowercased() })
                let added = imported.rules
                    .filter { !existing.contains($0.target.lowercased()) }
                    .map { RouteRule(target: $0.target, enabled: $0.enabled, note: $0.note, group: $0.group, via: $0.via) }
                config.rules.append(contentsOf: added)
            }
        } else {
            let invalid = client.addTargets(from: String(decoding: data, as: UTF8.self))
            if !invalid.isEmpty {
                client.alertMessage = "以下内容无法识别，已跳过：\(invalid.prefix(20).joined(separator: ", "))"
            }
        }
    }
}

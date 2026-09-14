import AppKit
import RouteShared
import SwiftUI

struct RuleRow: Identifiable {
    var rule: RouteRule
    var status: RuleStatus?
    var paused: Bool
    var id: UUID { rule.id }

    var kind: String { TargetParser.parse(rule.target)?.kindLabel ?? "无效" }
    var addressesText: String { status?.addresses.joined(separator: ", ") ?? "" }

    enum Health { case ok, warning, partial, error, pending, disabled }

    var health: Health {
        guard rule.enabled, !paused else { return .disabled }
        guard let status else { return .pending }
        if status.addresses.isEmpty { return status.error == nil ? .pending : .error }
        let applied = status.appliedAddresses.count
        if applied == status.addresses.count { return status.warning == nil && status.error == nil ? .ok : .warning }
        if applied == 0 { return status.error == nil ? .pending : .error }
        return .partial
    }

    var statusText: String {
        switch health {
        case .disabled: return paused ? "已暂停" : "已停用"
        case .pending: return status?.error ?? "等待中"
        case .ok: return "已生效"
        case .warning: return status?.warning ?? status?.error ?? "已生效"
        case .partial: return status?.error ?? "部分生效 \(status?.appliedAddresses.count ?? 0)/\(status?.addresses.count ?? 0)"
        case .error: return status?.error ?? "未生效"
        }
    }

    var detailText: String {
        var lines = [statusText]
        if let hop = status?.nextHop { lines.append("下一跳：\(hop)") }
        if let status, !status.addresses.isEmpty { lines.append("地址：\(status.addresses.joined(separator: ", "))") }
        if let retained = status?.retainedAddresses, !retained.isEmpty { lines.append("保留的旧解析结果：\(retained.joined(separator: ", "))") }
        if let date = status?.resolvedAt { lines.append("解析于 \(date.formatted(date: .omitted, time: .standard))") }
        return lines.joined(separator: "\n")
    }
}

struct RulesView: View {
    enum GroupFilter: Hashable {
        case all, ungrouped, group(String)
    }

    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation
    @State private var input = ""
    @State private var note = ""
    @State private var newGroup = ""
    @State private var newVia: RouteVia = .physical
    @State private var selection = Set<RouteRule.ID>()
    @State private var search = ""
    @State private var groupFilter: GroupFilter = .all
    @State private var editingRule: RouteRule?
    @State private var groupPrompt: GroupPrompt?

    struct GroupPrompt: Identifiable {
        enum Kind { case assign(Set<RouteRule.ID>), rename(String) }
        let id = UUID()
        var kind: Kind
        var text: String
    }

    private var rows: [RuleRow] {
        client.rules
            .filter { rule in
                switch groupFilter {
                case .all: return true
                case .ungrouped: return rule.group.isEmpty
                case .group(let g): return rule.group == g
                }
            }
            .filter { search.isEmpty || $0.target.localizedCaseInsensitiveContains(search) || $0.note.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
            .map { RuleRow(rule: $0, status: client.status(for: $0), paused: client.isPaused) }
    }

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            filterBar
            table
        }
        .searchable(text: $search, prompt: "搜索目标、备注或分组")
        .sheet(item: $editingRule) { rule in
            RuleEditor(rule: rule, groups: client.groups, interfaces: client.state?.interfaces ?? []) { client.updateRule($0) }
        }
        .sheet(item: $groupPrompt) { prompt in
            GroupNameSheet(prompt: prompt, groups: client.groups) { name in
                switch prompt.kind {
                case .assign(let ids): client.setGroup(name, for: ids)
                case .rename(let old):
                    client.renameGroup(old, to: name)
                    groupFilter = name.isEmpty ? .ungrouped : .group(name)
                }
            }
        }
    }

    // MARK: 添加

    private var addBar: some View {
        HStack(spacing: 8) {
            TextField("IP、网段（CIDR）或域名，可一次输入多个", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            ViaMenu(via: $newVia, interfaces: client.state?.interfaces ?? [])
                .frame(width: 150)
            GroupField(text: $newGroup, groups: client.groups)
                .frame(width: 120)
            TextField("备注", text: $note)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit(add)
            Button("添加", action: add)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || !client.canModify)
        }
        .padding(12)
    }

    private func add() {
        let group: String
        if case .group(let g) = groupFilter, newGroup.isEmpty { group = g } else { group = newGroup.trimmingCharacters(in: .whitespaces) }
        let invalid = client.addTargets(from: input, note: note.trimmingCharacters(in: .whitespaces), group: group, via: newVia)
        if invalid.isEmpty {
            input = ""
            note = ""
        } else {
            input = invalid.joined(separator: " ")
            client.alertMessage = "无法识别：\(invalid.joined(separator: ", "))"
        }
    }

    // MARK: 过滤

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("分组", selection: $groupFilter) {
                Text("全部分组").tag(GroupFilter.all)
                Text("未分组").tag(GroupFilter.ungrouped)
                if !client.groups.isEmpty { Divider() }
                ForEach(client.groups, id: \.self) { Text($0).tag(GroupFilter.group($0)) }
            }
            .fixedSize()
            .frame(maxWidth: 220)

            if case .group(let group) = groupFilter {
                Button("启用本组") { client.setGroupEnabled(group, enabled: true) }
                Button("停用本组") { client.setGroupEnabled(group, enabled: false) }
                Button("重命名…") { groupPrompt = GroupPrompt(kind: .rename(group), text: group) }
            }
            Spacer()
            let all = client.rules.filter(\.enabled)
            let ok = all.filter { RuleRow(rule: $0, status: client.status(for: $0), paused: client.isPaused).health == .ok }.count
            Text("共 \(client.rules.count) 条 · 启用 \(all.count) · 完全生效 \(ok)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onChange(of: client.groups) { _, groups in
            if case .group(let g) = groupFilter, !groups.contains(g) { groupFilter = .all }
        }
    }

    // MARK: 表格

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("启用") { row in
                Toggle("", isOn: Binding(get: { row.rule.enabled }, set: { client.setEnabled($0, for: [row.id]) }))
                    .labelsHidden()
                    .disabled(!client.canModify)
            }
            .width(36)

            TableColumn("目标") { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.rule.target).monospaced()
                    Text(row.kind).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 190)

            TableColumn("出口") { row in
                Text(row.rule.via.label).foregroundStyle(row.rule.via == .physical ? .secondary : .primary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("地址") { row in
                Text(row.addressesText.isEmpty ? "—" : row.addressesText)
                    .monospaced()
                    .foregroundStyle(row.addressesText.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .help(row.detailText)
            }
            .width(min: 150, ideal: 240)

            TableColumn("状态") { row in
                StatusBadge(row: row).help(row.detailText)
            }
            .width(min: 90, ideal: 160)

            TableColumn("分组") { row in
                Text(row.rule.group.isEmpty ? "—" : row.rule.group).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)

            TableColumn("备注") { row in
                Text(row.rule.note).foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: RouteRule.ID.self) { ids in
            if !ids.isEmpty { contextMenu(ids) }
        } primaryAction: { ids in
            editingRule = client.rules.first { ids.contains($0.id) }
        }
        .onDeleteCommand { client.removeRules(selection) }
        .overlay {
            if client.rules.isEmpty && client.canModify {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有规则").font(.headline)
                    Text("添加的 IP / 网段 / 域名将始终经由指定出口访问，\n切换 Wi-Fi 或网络后会自动重新应用。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<RouteRule.ID>) -> some View {
        let selected = client.rules.filter { ids.contains($0.id) }
        Button("编辑…") { editingRule = selected.first }
            .disabled(selected.count != 1)
        if let first = selected.first, selected.count == 1 {
            Button("诊断「\(first.target)」") { navigation.diagnose(first.target) }
        }
        Divider()
        Button("启用") { client.setEnabled(true, for: ids) }
        Button("停用") { client.setEnabled(false, for: ids) }
        Menu("出口") {
            Button("物理网关（自动）") { client.setVia(.physical, for: ids) }
            ForEach(client.state?.interfaces ?? [], id: \.name) { info in
                Button(ViaMenu.label(for: info)) { client.setVia(.interface(info.name), for: ids) }
            }
        }
        Menu("分组") {
            ForEach(client.groups, id: \.self) { group in
                Button(group) { client.setGroup(group, for: ids) }
            }
            if !client.groups.isEmpty { Divider() }
            Button("新建分组…") { groupPrompt = GroupPrompt(kind: .assign(ids), text: "") }
            Button("移出分组") { client.setGroup("", for: ids) }
        }
        Menu("优先级") {
            Button("移到最前") { client.moveRules(ids, toTop: true) }
            Button("移到最后") { client.moveRules(ids, toTop: false) }
        }
        Button("复制地址") { copyAddresses(ids) }
        Divider()
        Button("删除", role: .destructive) { client.removeRules(ids) }
    }

    private func copyAddresses(_ ids: Set<RouteRule.ID>) {
        let text = rows.filter { ids.contains($0.id) }
            .flatMap { ($0.status?.addresses.isEmpty ?? true) ? [$0.rule.target] : $0.status!.addresses }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct StatusBadge: View {
    let row: RuleRow

    var body: some View {
        Label {
            Text(row.statusText).lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }

    private var symbol: String {
        switch row.health {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "checkmark.circle.trianglebadge.exclamationmark"
        case .partial: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .pending: return "clock"
        case .disabled: return "pause.circle"
        }
    }

    private var color: Color {
        switch row.health {
        case .ok: return .green
        case .warning, .partial: return .orange
        case .error: return .red
        case .pending, .disabled: return .secondary
        }
    }
}

/// 出口选择菜单
struct ViaMenu: View {
    @Binding var via: RouteVia
    let interfaces: [NetworkInterfaceInfo]
    @State private var askGateway = false
    @State private var gatewayText = ""

    static func label(for info: NetworkInterfaceInfo) -> String {
        if info.isVirtual { return "\(info.name)（VPN / 虚拟网卡）" }
        return "\(info.name)（\(info.router ?? info.localAddress ?? "无网关")）"
    }

    var body: some View {
        Menu {
            Button("物理网关（自动）") { via = .physical }
            if !interfaces.isEmpty {
                Section("指定网卡") {
                    ForEach(interfaces, id: \.name) { info in
                        Button(Self.label(for: info)) { via = .interface(info.name) }
                    }
                }
            }
            Divider()
            Button("指定网关…") {
                if case .gateway(let ip) = via { gatewayText = ip }
                askGateway = true
            }
        } label: {
            Label(via.label, systemImage: via == .physical ? "wifi" : "arrow.turn.up.right")
        }
        .help("物理网关：自动选择 Wi-Fi / 有线的网关（绕过 VPN）\n指定网卡：固定走某个网卡，可以是 VPN 隧道\n指定网关：固定使用某个网关 IP")
        .alert("指定网关", isPresented: $askGateway) {
            TextField("例如 192.168.1.254", text: $gatewayText)
            Button("确定") {
                let ip = gatewayText.trimmingCharacters(in: .whitespaces)
                if TargetParser.ipv4Value(ip) != nil { via = .gateway(ip) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("网关必须位于某个已连接网络的子网内。")
        }
    }
}

/// 可输入也可选择已有分组
struct GroupField: View {
    @Binding var text: String
    let groups: [String]

    var body: some View {
        HStack(spacing: 2) {
            TextField("分组", text: $text)
                .textFieldStyle(.roundedBorder)
            if !groups.isEmpty {
                Menu {
                    ForEach(groups, id: \.self) { g in Button(g) { text = g } }
                    Divider()
                    Button("不分组") { text = "" }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

struct GroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: RulesView.GroupPrompt
    let groups: [String]
    let onDone: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRename ? "重命名分组" : "移动到新分组").font(.headline)
            GroupField(text: $name, groups: groups)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("确定") {
                    onDone(name.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { name = prompt.text }
    }

    private var isRename: Bool {
        if case .rename = prompt.kind { return true }
        return false
    }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: RouteRule
    let groups: [String]
    let interfaces: [NetworkInterfaceInfo]
    let onSave: (RouteRule) -> Void

    var body: some View {
        Form {
            TextField("目标", text: $rule.target)
            if TargetParser.parse(rule.target) == nil {
                Text("无法识别的 IP / 网段 / 域名").foregroundStyle(.red).font(.caption)
            }
            LabeledContent("出口") {
                ViaMenu(via: $rule.via, interfaces: interfaces).fixedSize()
            }
            LabeledContent("分组") {
                GroupField(text: $rule.group, groups: groups)
            }
            TextField("备注", text: $rule.note)
            Toggle("启用", isOn: $rule.enabled)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    rule.target = rule.target.trimmingCharacters(in: .whitespaces)
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TargetParser.parse(rule.target) == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

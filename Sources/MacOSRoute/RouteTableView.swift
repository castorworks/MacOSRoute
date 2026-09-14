import AppKit
import RouteHelperCore
import RouteShared
import SwiftUI

struct RouteTableView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case staticRoutes = "静态路由"
        case stale = "失效路由"
        case managed = "MacOSRoute 管理"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        var entry: RouteEntry
        var staleReason: String?
        var managed: Bool
        var id: String { entry.id }
    }

    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation
    @State private var entries: [RouteEntry] = []
    @State private var localAddresses: [LocalAddress] = []
    @State private var filter: Filter = .all
    @State private var showCloned = false
    @State private var search = ""
    @State private var selection = Set<Row.ID>()
    @State private var pendingDeletion: [String]?
    @State private var updatedAt = Date()

    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var managedAddresses: Set<String> {
        Set(client.state?.managedRoutes.map(\.address) ?? [])
    }

    private var allRows: [Row] {
        let managed = managedAddresses
        return entries.map { entry in
            Row(entry: entry,
                staleReason: RouteAnalyzer.staleReason(entry, localAddresses: localAddresses),
                managed: managed.contains(entry.address) && entry.isStatic && !entry.isScoped)
        }
    }

    private var rows: [Row] {
        allRows.filter { row in
            if !showCloned, filter == .all, row.entry.isCloned || row.entry.isLinkLayer { return false }
            switch filter {
            case .all: break
            case .staticRoutes: if !row.entry.isStatic { return false }
            case .stale: if row.staleReason == nil { return false }
            case .managed: if !row.managed { return false }
            }
            guard !search.isEmpty else { return true }
            return [row.entry.displayDestination, row.entry.gateway ?? "", row.entry.interface].contains { $0.localizedCaseInsensitiveContains(search) }
        }
        .sorted { ($0.entry.prefix, $0.entry.destination) < ($1.entry.prefix, $1.entry.destination) }
    }

    /// 可清理的失效路由（排除 MacOSRoute 管理的，它们会由 Helper 自动修正）
    private var staleAddresses: [String] {
        Array(Set(allRows.filter { $0.staleReason != nil && !$0.managed }.map(\.entry.address))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .searchable(text: $search, prompt: "搜索目的地址、网关或网卡")
        .onAppear(perform: reload)
        .onReceive(timer) { _ in reload() }
        .confirmationDialog("删除以下 \(pendingDeletion?.count ?? 0) 条静态路由？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("删除", role: .destructive) {
                if let addresses = pendingDeletion { client.deleteSystemRoutes(addresses) { reload() } }
                pendingDeletion = nil
            }
        } message: {
            Text((pendingDeletion ?? []).prefix(12).joined(separator: "\n") + ((pendingDeletion?.count ?? 0) > 12 ? "\n…" : ""))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    if f == .stale, !staleAddresses.isEmpty {
                        Text("\(f.rawValue) (\(staleAddresses.count))").tag(f)
                    } else {
                        Text(f.rawValue).tag(f)
                    }
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Toggle("显示缓存 / ARP 条目", isOn: $showCloned)
                .disabled(filter != .all)
            Spacer()
            Text("\(rows.count) 条 · \(updatedAt.formatted(date: .omitted, time: .standard))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                pendingDeletion = staleAddresses
            } label: {
                Label("清理失效路由", systemImage: "trash")
            }
            .disabled(staleAddresses.isEmpty || !client.canModify || client.isBusy)
            .help("删除网关已不在当前任何网络中的静态路由，例如切换网络后脚本遗留的路由")
        }
        .controlSize(.small)
        .padding(12)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("目的地址") { row in
                HStack(spacing: 6) {
                    Text(row.entry.displayDestination).monospaced()
                    if row.managed {
                        Text("MacOSRoute").font(.caption2).padding(.horizontal, 4).background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                    if row.staleReason != nil {
                        Text("失效").font(.caption2).foregroundStyle(.white).padding(.horizontal, 4).background(Color.red, in: Capsule())
                    }
                }
                .help(row.staleReason ?? "")
            }
            .width(min: 160, ideal: 240)
            TableColumn("网关") { row in
                Text(row.entry.gateway ?? "link").monospaced().foregroundStyle(row.entry.gateway == nil ? .secondary : .primary)
            }
            .width(min: 100, ideal: 140)
            TableColumn("网卡") { row in Text(row.entry.interface) }
                .width(min: 50, ideal: 70)
            TableColumn("源地址") { row in
                Text(row.entry.interfaceAddress ?? "—").monospaced().foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
            TableColumn("标志") { row in
                Text(row.entry.flagString).monospaced().help(flagHelp)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            let selected = allRows.filter { ids.contains($0.id) }
            if let first = selected.first, selected.count == 1 {
                Button("诊断 \(first.entry.destination)") { navigation.diagnose(first.entry.destination) }
            }
            let convertible = selected.filter { $0.entry.prefix > 0 && !$0.managed }.map(\.entry.address)
            Button("添加为规则（经由物理网关）") {
                client.addTargets(from: convertible.joined(separator: " "))
            }
            .disabled(convertible.isEmpty || !client.canModify)
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selected.map { "\($0.entry.displayDestination) \($0.entry.gateway ?? "link") \($0.entry.interface) \($0.entry.flagString)" }.joined(separator: "\n"), forType: .string)
            }
            Divider()
            let deletable = selected.filter { $0.entry.isStatic && !$0.managed && !$0.entry.isScoped }.map(\.entry.address)
            Button("删除静态路由…", role: .destructive) { pendingDeletion = deletable }
                .disabled(deletable.isEmpty || !client.canModify)
        }
    }

    private let flagHelp = "U 可用 · G 网关 · H 主机 · S 静态 · C 可克隆 · W 克隆生成 · L 链路层 · I 绑定网卡"

    private func reload() {
        entries = RoutingTable.dump()
        localAddresses = LocalAddress.current()
        updatedAt = Date()
    }
}

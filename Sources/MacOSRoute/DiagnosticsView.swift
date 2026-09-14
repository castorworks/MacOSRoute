import AppKit
import Darwin
import RouteHelperCore
import RouteShared
import SwiftUI

struct DiagnosticReport: Sendable {
    struct AddressProbe: Identifiable, Sendable {
        var address: String
        var sources: [String]
        var route: RouteTool.RouteInfo?
        var isVirtualInterface: Bool
        var tcp: Result<Double, TCPProbe.ProbeError>?
        var id: String { address }
    }

    var target: String
    var kind: String
    var physical: GatewayInfo?
    var systemDNS: Result<[String], ResolveError>?
    var physicalDNS: Result<[String], ResolveError>?
    var probes: [AddressProbe]
    var finishedAt = Date()

    static func run(target raw: String, port: UInt16?) -> DiagnosticReport? {
        guard let parsed = TargetParser.parse(raw) else { return nil }
        let snapshot = GatewayDetector.snapshot(preferredInterface: HelperConfig.automaticInterface)
        var report = DiagnosticReport(target: raw, kind: parsed.kindLabel, physical: snapshot.physical, probes: [])

        var addresses: [(String, String)] = []
        switch parsed {
        case .host(let ip):
            addresses = [(ip, "输入")]
        case .network(let net, let prefix):
            addresses = [("\(net)/\(prefix)", "输入")]
        case .domain(let domain):
            report.physicalDNS = DNSResolver.resolve(domain, mode: .physical, customServers: [], physical: snapshot.physicalInterface)
            report.systemDNS = DNSResolver.resolveSystem(domain)
            if case .success(let ips) = report.physicalDNS { addresses += ips.map { ($0, "物理网络 DNS") } }
            if case .success(let ips) = report.systemDNS { addresses += ips.map { ($0, "系统 DNS") } }
        }

        var merged: [(String, [String])] = []
        for (ip, source) in addresses {
            if let i = merged.firstIndex(where: { $0.0 == ip }) { merged[i].1.append(source) } else { merged.append((ip, [source])) }
        }

        let virtualNames = Set(snapshot.interfaces.filter(\.isVirtual).map(\.name))
        report.probes = merged.prefix(12).map { address, sources in
            let route = RouteTool.get(address)
            let isNetwork = address.contains("/")
            return AddressProbe(address: address, sources: sources, route: route,
                                isVirtualInterface: route?.interface.map { virtualNames.contains($0) || GatewayDetector.isVirtual($0) } ?? false,
                                tcp: isNetwork || port == nil ? nil : TCPProbe.connect(address, port: port!, timeout: 3))
        }
        return report
    }
}

enum TCPProbe {
    enum ProbeError: Error, Sendable, CustomStringConvertible {
        case timeout
        case failed(String)
        var description: String {
            switch self {
            case .timeout: return "连接超时"
            case .failed(let m): return m
            }
        }
    }

    /// 返回建立 TCP 连接的耗时（毫秒）
    static func connect(_ ip: String, port: UInt16, timeout: TimeInterval) -> Result<Double, ProbeError> {
        guard let value = TargetParser.ipv4Value(ip) else { return .failure(.failed("无效地址")) }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .failure(.failed(String(cString: strerror(errno)))) }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = value.bigEndian
        let start = Date()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS else { return .failure(.failed(String(cString: strerror(errno)))) }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return .failure(.timeout) }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            if error != 0 { return .failure(.failed(String(cString: strerror(error)))) }
        }
        return .success(Date().timeIntervalSince(start) * 1000)
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var client: HelperClient
    @EnvironmentObject private var navigation: AppNavigation
    @State private var portText = "443"
    @State private var running = false
    @State private var report: DiagnosticReport?
    @State private var invalid = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("输入 IP、网段或域名，检查实际走哪个网卡", text: $navigation.diagnosticsTarget)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Text("TCP 端口")
                TextField("443", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                Button(action: run) {
                    if running { ProgressView().controlSize(.small) } else { Text("诊断") }
                }
                .disabled(running || navigation.diagnosticsTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
            Divider()

            if invalid {
                ContentUnavailableView("无法识别的目标", systemImage: "questionmark.circle")
            } else if let report {
                ScrollView { reportView(report).padding(16) }
            } else {
                ContentUnavailableView("连通性诊断", systemImage: "stethoscope",
                                       description: Text("对比系统 DNS 与物理网络 DNS 的解析结果，\n查看每个地址实际使用的网卡和网关，并测试 TCP 连接。"))
            }
        }
        .onChange(of: navigation.diagnosticsRequest) { run() }
        .onAppear { if navigation.diagnosticsRequest > 0, report == nil { run() } }
    }

    private func run() {
        let target = navigation.diagnosticsTarget.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !running else { return }
        let port = UInt16(portText)
        running = true
        invalid = false
        Task.detached(priority: .userInitiated) {
            let result = DiagnosticReport.run(target: target, port: port)
            await MainActor.run {
                running = false
                report = result
                invalid = result == nil
            }
        }
    }

    @ViewBuilder
    private func reportView(_ report: DiagnosticReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            summary(report)

            if report.systemDNS != nil || report.physicalDNS != nil {
                GroupBox("DNS 解析") {
                    VStack(alignment: .leading, spacing: 6) {
                        dnsLine("物理网络 DNS", report.physicalDNS)
                        dnsLine("系统 DNS", report.systemDNS)
                        if case .success(let a)? = report.physicalDNS, case .success(let b)? = report.systemDNS, Set(a).isDisjoint(with: b) {
                            Label("两种 DNS 的结果完全不同：系统 DNS 可能被 VPN 或代理接管。MacOSRoute 默认使用物理网络 DNS。", systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            GroupBox("路由与连通性") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("地址"); Text("来源"); Text("网卡"); Text("网关"); Text("匹配路由"); Text("TCP")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(report.probes) { probe in
                        GridRow {
                            Text(probe.address).monospaced().textSelection(.enabled)
                            Text(probe.sources.joined(separator: " / ")).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                Image(systemName: probe.isVirtualInterface ? "lock.shield" : "wifi")
                                    .foregroundStyle(interfaceColor(probe, report))
                                Text(probe.route?.interface ?? "—")
                            }
                            Text(probe.route?.gateway ?? "—").monospaced()
                            Text(probe.route?.destination ?? "—").monospaced().foregroundStyle(.secondary)
                            tcpText(probe.tcp)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            let matched = matchingRules(report)
            GroupBox("MacOSRoute 规则") {
                VStack(alignment: .leading, spacing: 6) {
                    if matched.isEmpty {
                        Text("没有规则覆盖这些地址。").foregroundStyle(.secondary)
                        Button("添加规则（经由物理网关）") {
                            client.addTargets(from: report.target)
                            navigation.section = .rules
                        }
                        .disabled(!client.canModify)
                    } else {
                        ForEach(matched) { row in
                            HStack {
                                Text(row.rule.target).monospaced()
                                Text(row.rule.via.label).foregroundStyle(.secondary)
                                Spacer()
                                StatusBadge(row: row)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private func summary(_ report: DiagnosticReport) -> some View {
        let physical = report.physical?.interface
        let viaPhysical = report.probes.filter { $0.route?.interface == physical }.count
        let total = report.probes.count
        let ok = total > 0 && viaPhysical == total
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.target).font(.title3.bold()).textSelection(.enabled)
                if total == 0 {
                    Text("没有可检测的地址")
                } else if ok {
                    Text("全部 \(total) 个地址都经由物理网卡 \(physical ?? "")")
                } else {
                    Text("\(total - viaPhysical)/\(total) 个地址没有经由物理网卡\(physical.map { " \($0)" } ?? "")")
                }
                Text("\(report.kind) · 诊断于 \(report.finishedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dnsLine(_ title: String, _ result: Result<[String], ResolveError>?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
            switch result {
            case .success(let ips)?: Text(ips.joined(separator: ", ")).monospaced().textSelection(.enabled)
            case .failure(let error)?: Text(error.description).foregroundStyle(.red)
            case nil: Text("—")
            }
        }
    }

    private func tcpText(_ result: Result<Double, TCPProbe.ProbeError>?) -> some View {
        switch result {
        case .success(let ms)?: return Text(String(format: "%.0f ms", ms)).foregroundStyle(.green)
        case .failure(let error)?: return Text(error.description).foregroundStyle(.red)
        case nil: return Text("—").foregroundStyle(.secondary)
        }
    }

    private func interfaceColor(_ probe: DiagnosticReport.AddressProbe, _ report: DiagnosticReport) -> Color {
        if probe.route?.interface == report.physical?.interface { return .green }
        return probe.isVirtualInterface ? .orange : .secondary
    }

    private func matchingRules(_ report: DiagnosticReport) -> [RuleRow] {
        let addresses = Set(report.probes.map(\.address))
        let target = TargetParser.parse(report.target)
        return client.rules.compactMap { rule in
            let status = client.status(for: rule)
            let hit = TargetParser.parse(rule.target) == target || !(addresses.isDisjoint(with: status?.addresses ?? []))
            return hit ? RuleRow(rule: rule, status: status, paused: client.isPaused) : nil
        }
    }
}

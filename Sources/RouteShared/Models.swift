import Foundation

/// 规则的出口
public enum RouteVia: Codable, Hashable, Sendable {
    /// 自动选择的物理网卡网关（绕过 VPN）
    case physical
    /// 指定网卡：有网关时经由其网关，否则（如 VPN 的 utun）直接走该接口
    case interface(String)
    /// 指定网关 IP
    case gateway(String)

    public var label: String {
        switch self {
        case .physical: return "物理网关"
        case .interface(let name): return "网卡 \(name)"
        case .gateway(let ip): return "网关 \(ip)"
        }
    }
}

public struct RouteRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// IP、CIDR 或域名
    public var target: String
    public var enabled: Bool
    public var note: String
    /// 分组名，空字符串表示未分组
    public var group: String
    public var via: RouteVia

    public init(id: UUID = UUID(), target: String, enabled: Bool = true, note: String = "", group: String = "", via: RouteVia = .physical) {
        self.id = id
        self.target = target
        self.enabled = enabled
        self.note = note
        self.group = group
        self.via = via
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        target = try c.decode(String.self, forKey: .target)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        via = try c.decodeIfPresent(RouteVia.self, forKey: .via) ?? .physical
    }
}

public enum DNSMode: String, Codable, CaseIterable, Sendable {
    /// 通过物理网卡向该网络的 DNS 服务器查询（绕过 VPN / 代理的 DNS 与 Fake-IP）
    case physical
    /// 使用系统解析器（可能被 VPN / 代理接管）
    case system
    /// 通过物理网卡向自定义 DNS 服务器查询
    case custom

    public var label: String {
        switch self {
        case .physical: return "物理网络 DNS（推荐）"
        case .system: return "系统 DNS"
        case .custom: return "自定义 DNS 服务器"
        }
    }
}

public struct HelperConfig: Codable, Equatable, Sendable {
    public static let automaticInterface = "auto"

    public var rules: [RouteRule]
    /// 物理网关使用的网卡："auto" 或 BSD 接口名（如 en0）
    public var interface: String
    /// 域名重新解析的间隔（分钟）
    public var dnsRefreshMinutes: Int
    public var dnsMode: DNSMode
    public var customDNSServers: [String]
    /// 域名解析结果变化后，旧 IP 继续保留路由的小时数（避免 CDN 轮换导致已有连接中断）
    public var dnsRetentionHours: Int
    /// 暂停：移除全部由 MacOSRoute 添加的路由，但保留规则
    public var paused: Bool
    /// 配置版本号，用于检测并发修改（多个窗口或多个 App 实例）
    public var revision: Int

    public init(rules: [RouteRule] = [], interface: String = HelperConfig.automaticInterface, dnsRefreshMinutes: Int = 10,
                dnsMode: DNSMode = .physical, customDNSServers: [String] = [], dnsRetentionHours: Int = 6,
                paused: Bool = false, revision: Int = 0) {
        self.rules = rules
        self.interface = interface
        self.dnsRefreshMinutes = dnsRefreshMinutes
        self.dnsMode = dnsMode
        self.customDNSServers = customDNSServers
        self.dnsRetentionHours = dnsRetentionHours
        self.paused = paused
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([RouteRule].self, forKey: .rules) ?? []
        interface = try c.decodeIfPresent(String.self, forKey: .interface) ?? HelperConfig.automaticInterface
        dnsRefreshMinutes = try c.decodeIfPresent(Int.self, forKey: .dnsRefreshMinutes) ?? 10
        dnsMode = try c.decodeIfPresent(DNSMode.self, forKey: .dnsMode) ?? .physical
        customDNSServers = try c.decodeIfPresent([String].self, forKey: .customDNSServers) ?? []
        dnsRetentionHours = try c.decodeIfPresent(Int.self, forKey: .dnsRetentionHours) ?? 6
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }

    /// 修正越界值
    public mutating func sanitize() {
        dnsRefreshMinutes = min(max(1, dnsRefreshMinutes), 1440)
        dnsRetentionHours = min(max(0, dnsRetentionHours), 168)
        customDNSServers = customDNSServers.filter { TargetParser.ipv4Value($0) != nil }
        for i in rules.indices {
            rules[i].target = rules[i].target.trimmingCharacters(in: .whitespacesAndNewlines)
            rules[i].group = rules[i].group.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public var groups: [String] {
        Array(Set(rules.map(\.group).filter { !$0.isEmpty })).sorted()
    }
}

/// 物理网关（默认出口）
public struct GatewayInfo: Codable, Equatable, Sendable {
    public var interface: String
    public var router: String
    public var localAddress: String?

    public init(interface: String, router: String, localAddress: String?) {
        self.interface = interface
        self.router = router
        self.localAddress = localAddress
    }
}

/// 系统中拥有 IPv4 配置的网络接口
public struct NetworkInterfaceInfo: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var router: String?
    public var localAddress: String?
    public var subnetMask: String?
    public var dnsServers: [String]
    /// VPN 隧道等虚拟接口
    public var isVirtual: Bool

    public init(name: String, router: String?, localAddress: String?, subnetMask: String?, dnsServers: [String], isVirtual: Bool) {
        self.name = name
        self.router = router
        self.localAddress = localAddress
        self.subnetMask = subnetMask
        self.dnsServers = dnsServers
        self.isVirtual = isVirtual
    }
}

public struct RuleStatus: Codable, Equatable, Sendable {
    /// 规则对应的地址（主机 IP 或 CIDR），包含保留的旧解析结果
    public var addresses: [String]
    /// 当前确认已按期望出口生效的地址
    public var appliedAddresses: [String]
    /// 来自旧解析结果、仍在保留期内的地址
    public var retainedAddresses: [String]
    public var error: String?
    public var warning: String?
    public var resolvedAt: Date?
    /// 实际使用的下一跳描述，如 "192.168.1.1 (en0)"
    public var nextHop: String?

    public init(addresses: [String] = [], appliedAddresses: [String] = [], retainedAddresses: [String] = [],
                error: String? = nil, warning: String? = nil, resolvedAt: Date? = nil, nextHop: String? = nil) {
        self.addresses = addresses
        self.appliedAddresses = appliedAddresses
        self.retainedAddresses = retainedAddresses
        self.error = error
        self.warning = warning
        self.resolvedAt = resolvedAt
        self.nextHop = nextHop
    }
}

/// Helper 当前维护的一条路由
public struct ManagedRoute: Codable, Equatable, Hashable, Sendable {
    public var address: String
    public var gateway: String?
    public var interface: String?

    public init(address: String, gateway: String?, interface: String?) {
        self.address = address
        self.gateway = gateway
        self.interface = interface
    }
}

public struct LogEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable { case info, warning, error }

    public var id: UUID
    public var date: Date
    public var level: Level
    public var message: String

    public init(level: Level, message: String) {
        id = UUID()
        date = Date()
        self.level = level
        self.message = message
    }
}

public struct HelperState: Codable, Sendable {
    public var version: String
    public var config: HelperConfig
    public var gateway: GatewayInfo?
    public var interfaces: [NetworkInterfaceInfo]
    /// key 为 RouteRule.id.uuidString
    public var statuses: [String: RuleStatus]
    public var managedRoutes: [ManagedRoute]
    public var lastApplyAt: Date?
    public var logs: [LogEntry]

    public init(version: String, config: HelperConfig, gateway: GatewayInfo? = nil, interfaces: [NetworkInterfaceInfo] = [],
                statuses: [String: RuleStatus] = [:], managedRoutes: [ManagedRoute] = [], lastApplyAt: Date? = nil, logs: [LogEntry] = []) {
        self.version = version
        self.config = config
        self.gateway = gateway
        self.interfaces = interfaces
        self.statuses = statuses
        self.managedRoutes = managedRoutes
        self.lastApplyAt = lastApplyAt
        self.logs = logs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        config = try c.decode(HelperConfig.self, forKey: .config)
        gateway = try c.decodeIfPresent(GatewayInfo.self, forKey: .gateway)
        interfaces = try c.decodeIfPresent([NetworkInterfaceInfo].self, forKey: .interfaces) ?? []
        statuses = try c.decodeIfPresent([String: RuleStatus].self, forKey: .statuses) ?? [:]
        managedRoutes = try c.decodeIfPresent([ManagedRoute].self, forKey: .managedRoutes) ?? []
        lastApplyAt = try c.decodeIfPresent(Date.self, forKey: .lastApplyAt)
        logs = try c.decodeIfPresent([LogEntry].self, forKey: .logs) ?? []
    }
}

public enum RouteJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

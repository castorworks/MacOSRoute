import Foundation
import RouteShared
import SystemConfiguration

/// 从 SCDynamicStore 读取各网络服务的 IPv4 配置，并选出物理网卡（非 VPN 隧道）的网关。
public enum GatewayDetector {
    /// 隧道、虚拟网卡前缀：这些接口的 "Router" 不是可以绕行到的物理网关
    static let virtualInterfacePrefixes = ["utun", "ipsec", "ppp", "gif", "stf", "feth", "awdl", "llw", "anpi", "lo", "vmenet", "tap", "tun"]

    public static func isVirtual(_ name: String) -> Bool {
        virtualInterfacePrefixes.contains { name.hasPrefix($0) }
    }

    public struct ServiceEntry {
        public var serviceID: String
        public var ipv4: [String: Any]
        public var dns: [String: Any]?

        public init(serviceID: String, ipv4: [String: Any], dns: [String: Any]? = nil) {
            self.serviceID = serviceID
            self.ipv4 = ipv4
            self.dns = dns
        }
    }

    public struct Snapshot: Equatable {
        public var physical: GatewayInfo?
        public var interfaces: [NetworkInterfaceInfo]

        public var physicalInterface: NetworkInterfaceInfo? {
            physical.flatMap { p in interfaces.first { $0.name == p.interface } }
        }
    }

    public static func snapshot(preferredInterface: String) -> Snapshot {
        guard let store = SCDynamicStoreCreate(nil, "MacOSRouteGateway" as CFString, nil, nil) else {
            return Snapshot(physical: nil, interfaces: [])
        }
        let serviceOrder = (SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any])?["ServiceOrder"] as? [String] ?? []
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
        var entries: [ServiceEntry] = []
        for key in keys {
            let parts = key.split(separator: "/")
            guard parts.count == 5, let ipv4 = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { continue }
            let serviceID = String(parts[3])
            let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any]
            entries.append(ServiceEntry(serviceID: serviceID, ipv4: ipv4, dns: dns))
        }
        return choose(entries: entries, serviceOrder: serviceOrder, preferredInterface: preferredInterface)
    }

    /// 纯函数，便于测试
    public static func choose(entries: [ServiceEntry], serviceOrder: [String], preferredInterface: String) -> Snapshot {
        func rank(_ e: ServiceEntry, _ name: String) -> (Int, Int, String) {
            (serviceOrder.firstIndex(of: e.serviceID) ?? Int.max, name.hasPrefix("en") ? 0 : 1, name)
        }
        let sorted = entries.compactMap { e -> (ServiceEntry, String)? in
            (e.ipv4["InterfaceName"] as? String).map { (e, $0) }
        }.sorted { rank($0.0, $0.1) < rank($1.0, $1.1) }

        var interfaces: [NetworkInterfaceInfo] = []
        var physical: GatewayInfo?
        for (entry, name) in sorted where !interfaces.contains(where: { $0.name == name }) {
            let addresses = entry.ipv4["Addresses"] as? [String] ?? []
            var router = entry.ipv4["Router"] as? String
            if let r = router, TargetParser.ipv4Value(r) == nil || r.hasPrefix("127.") || r == "0.0.0.0" || addresses.contains(r) {
                router = nil
            }
            let dnsServers = (entry.dns?["ServerAddresses"] as? [String] ?? []).filter { TargetParser.ipv4Value($0) != nil }
            let info = NetworkInterfaceInfo(name: name, router: router, localAddress: addresses.first,
                                            subnetMask: (entry.ipv4["SubnetMasks"] as? [String])?.first,
                                            dnsServers: dnsServers, isVirtual: isVirtual(name))
            interfaces.append(info)

            guard physical == nil, let router else { continue }
            let eligible = preferredInterface == HelperConfig.automaticInterface ? !info.isVirtual : name == preferredInterface
            if eligible {
                physical = GatewayInfo(interface: name, router: router, localAddress: info.localAddress)
            }
        }
        return Snapshot(physical: physical, interfaces: interfaces)
    }
}

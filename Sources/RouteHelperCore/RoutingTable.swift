import Darwin
import Foundation
import RouteShared

/// 内核 IPv4 路由表中的一条记录
public struct RouteEntry: Equatable, Hashable, Identifiable, Sendable {
    public var destination: String
    public var prefix: Int
    /// IPv4 网关；直连 / 接口路由为 nil
    public var gateway: String?
    public var interface: String
    /// 路由使用的本机地址（ifa）
    public var interfaceAddress: String?
    public var flags: Int32

    public init(destination: String, prefix: Int, gateway: String?, interface: String, interfaceAddress: String?, flags: Int32) {
        self.destination = destination
        self.prefix = prefix
        self.gateway = gateway
        self.interface = interface
        self.interfaceAddress = interfaceAddress
        self.flags = flags
    }

    /// 与规则地址格式一致：主机为 "1.2.3.4"，网段为 "10.0.0.0/8"
    public var address: String { prefix == 32 ? destination : "\(destination)/\(prefix)" }
    public var id: String { "\(address)|\(gateway ?? "link")|\(interface)|\(flags)" }

    public var isStatic: Bool { flags & RTF_STATIC != 0 }
    public var hasGateway: Bool { flags & RTF_GATEWAY != 0 }
    public var isScoped: Bool { flags & RTF_IFSCOPE != 0 }
    public var isCloned: Bool { flags & RTF_WASCLONED != 0 }
    public var isLinkLayer: Bool { flags & RTF_LLINFO != 0 }

    public var displayDestination: String { prefix == 0 && destination == "0.0.0.0" ? "default" : address }

    /// 与 netstat -rn 一致的标志字符串
    public var flagString: String {
        let table: [(Int32, Character)] = [
            (RTF_UP, "U"), (RTF_GATEWAY, "G"), (RTF_HOST, "H"), (RTF_REJECT, "R"), (RTF_DYNAMIC, "D"),
            (RTF_MODIFIED, "M"), (RTF_CLONING, "C"), (RTF_PRCLONING, "c"), (RTF_LLINFO, "L"),
            (RTF_STATIC, "S"), (RTF_BLACKHOLE, "B"), (RTF_WASCLONED, "W"), (RTF_IFSCOPE, "I"),
        ]
        return String(table.compactMap { flags & $0.0 != 0 ? $0.1 : nil })
    }
}

public enum RoutingTable {
    public static func dump() -> [RouteEntry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return [] }
            length += length / 4 + 1024 // 路由表可能在两次调用之间增长
            var buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 {
                return buffer.withUnsafeBytes { parse(UnsafeRawBufferPointer(rebasing: $0[0..<length]), interfaceName: interfaceName) }
            }
            if errno != ENOMEM { return [] }
        }
        return []
    }

    static func interfaceName(_ index: UInt16) -> String {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
        return if_indextoname(UInt32(index), &name) != nil ? String(cString: name) : "if\(index)"
    }

    /// 解析 NET_RT_DUMP 返回的 rt_msghdr 序列
    public static func parse(_ bytes: UnsafeRawBufferPointer, interfaceName: (UInt16) -> String) -> [RouteEntry] {
        let headerSize = MemoryLayout<rt_msghdr>.size
        var entries: [RouteEntry] = []
        var offset = 0
        while offset + headerSize <= bytes.count {
            var header = rt_msghdr()
            withUnsafeMutableBytes(of: &header) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + headerSize])) }
            let messageLength = Int(header.rtm_msglen)
            guard messageLength >= headerSize, offset + messageLength <= bytes.count else { break }
            defer { offset += messageLength }
            guard header.rtm_version == RTM_VERSION else { continue }

            var sockaddrs = [[UInt8]?](repeating: nil, count: Int(RTAX_MAX))
            var cursor = offset + headerSize
            let end = offset + messageLength
            for i in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << i) != 0 {
                guard cursor < end else { break }
                let saLength = Int(bytes[cursor])
                let available = min(saLength, end - cursor)
                sockaddrs[i] = Array(bytes[cursor..<cursor + available])
                cursor += saLength > 0 ? 1 + ((saLength - 1) | (MemoryLayout<UInt32>.size - 1)) : MemoryLayout<UInt32>.size
            }

            guard let dst = sockaddrs[Int(RTAX_DST)], let destination = ipv4(dst) else { continue }
            var gateway: String?
            if let gw = sockaddrs[Int(RTAX_GATEWAY)], gw.count > 1, gw[1] == UInt8(AF_INET) {
                gateway = ipv4(gw)
            }
            let prefix: Int
            if header.rtm_flags & RTF_HOST != 0 {
                prefix = 32
            } else if let mask = sockaddrs[Int(RTAX_NETMASK)] {
                prefix = maskPrefix(mask)
            } else {
                prefix = destination == "0.0.0.0" ? 0 : 32
            }
            let ifa = sockaddrs[Int(RTAX_IFA)].flatMap(ipv4)
            entries.append(RouteEntry(destination: destination, prefix: prefix, gateway: gateway,
                                      interface: interfaceName(header.rtm_index), interfaceAddress: ifa, flags: header.rtm_flags))
        }
        return entries
    }

    private static func ipv4(_ sa: [UInt8]) -> String? {
        guard sa.count >= 8, sa[1] == UInt8(AF_INET) else { return nil }
        return "\(sa[4]).\(sa[5]).\(sa[6]).\(sa[7])"
    }

    /// 掩码 sockaddr 可能被截断（sa_len < 8）或 family 为 0/255
    private static func maskPrefix(_ sa: [UInt8]) -> Int {
        var bits = 0
        for i in 4..<8 where i < sa.count { bits += sa[i].nonzeroBitCount }
        return bits
    }

    /// 精确匹配某个地址的非 scoped 路由；优先返回静态路由，其次非克隆路由
    public static func exactRoute(for address: String, in entries: [RouteEntry]) -> RouteEntry? {
        let candidates = entries.filter { $0.address == address && !$0.isScoped && !$0.isLinkLayer }
        return candidates.first(where: \.isStatic) ?? candidates.first(where: { !$0.isCloned }) ?? candidates.first
    }
}

/// 本机 IPv4 接口地址
public struct LocalAddress: Equatable, Sendable {
    public var interface: String
    public var address: String
    public var netmask: String

    public init(interface: String, address: String, netmask: String) {
        self.interface = interface
        self.address = address
        self.netmask = netmask
    }

    public static func current() -> [LocalAddress] {
        var result: [LocalAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            result.append(LocalAddress(interface: String(cString: ifa.pointee.ifa_name),
                                       address: string(addr), netmask: string(mask)))
        }
        return result
    }

    private static func string(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            TargetParser.ipv4String(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
        }
    }
}

public enum RouteAnalyzer {
    /// 判断静态网关路由是否已失效：网关不在任何当前接口的子网内，或路由绑定的本机地址已不存在
    public static func staleReason(_ entry: RouteEntry, localAddresses: [LocalAddress]) -> String? {
        guard entry.isStatic, entry.hasGateway, !entry.isScoped, !entry.isCloned, let gateway = entry.gateway else { return nil }
        if let ifa = entry.interfaceAddress, !localAddresses.contains(where: { $0.address == ifa }) {
            return "绑定的本机地址 \(ifa) 已不存在"
        }
        let reachable = localAddresses.contains { TargetParser.sameSubnet(gateway, $0.address, mask: $0.netmask) }
        return reachable ? nil : "网关 \(gateway) 不在任何当前网络中"
    }
}

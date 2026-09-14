import Foundation

public enum RouteTarget: Equatable, Sendable {
    case host(String)
    /// 规范化后的网络地址与前缀长度
    case network(String, prefix: Int)
    case domain(String)

    public var kindLabel: String {
        switch self {
        case .host: return "IP"
        case .network: return "网段"
        case .domain: return "域名"
        }
    }
}

public enum TargetParser {
    public static func parse(_ raw: String) -> RouteTarget? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 允许直接粘贴 URL：https://example.com:8443/path -> example.com
        if s.contains("://"), let host = URLComponents(string: s)?.host {
            s = host
        }

        if let slash = s.firstIndex(of: "/") {
            let addr = String(s[..<slash])
            guard let prefix = Int(s[s.index(after: slash)...]), (0...32).contains(prefix),
                  let value = ipv4Value(addr) else { return nil }
            if prefix == 32 { return .host(ipv4String(value)) }
            return .network(ipv4String(value & maskValue(prefix: prefix)), prefix: prefix)
        }

        if let value = ipv4Value(s) {
            return .host(ipv4String(value))
        }

        // 看起来像 IP 但不合法（如 1.2.3.256），不要当作域名
        if s.allSatisfy({ $0.isNumber || $0 == "." }) { return nil }

        let host = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return isValidHostname(host) ? .domain(host) : nil
    }

    /// 将用户输入按空白、逗号、分号拆分为多个目标
    public static func splitInput(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: " \t\n\r,;，；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func ipv4Value(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            value = value << 8 | octet
        }
        return value
    }

    public static func ipv4String(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    public static func netmask(prefix: Int) -> String {
        ipv4String(maskValue(prefix: prefix))
    }

    public static func maskValue(prefix: Int) -> UInt32 {
        prefix <= 0 ? 0 : prefix >= 32 ? ~UInt32(0) : ~UInt32(0) << UInt32(32 - prefix)
    }

    public static func prefixLength(mask: String) -> Int? {
        ipv4Value(mask).map { $0.nonzeroBitCount }
    }

    /// ip 是否位于 address/mask 所在的子网
    public static func sameSubnet(_ ip: String, _ address: String, mask: String) -> Bool {
        guard let a = ipv4Value(ip), let b = ipv4Value(address), let m = ipv4Value(mask) else { return false }
        return a & m == b & m
    }

    /// Surge / Clash 等代理的 Fake-IP 网段 198.18.0.0/15
    public static func isFakeIP(_ ip: String) -> Bool {
        guard let v = ipv4Value(ip) else { return false }
        return v & maskValue(prefix: 15) == 0xC612_0000
    }

    /// 不应作为路由目标的解析结果
    public static func isUnroutableResolution(_ ip: String) -> Bool {
        guard let v = ipv4Value(ip) else { return true }
        return v == 0 || v >> 24 == 127 || v >> 28 == 0xE || v == ~UInt32(0)
    }

    private static func isValidHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.count <= 63,
                  label.unicodeScalars.allSatisfy(allowed.contains),
                  !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        }
        return true
    }
}

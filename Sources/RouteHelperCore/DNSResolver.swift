import Darwin
import Foundation
import RouteShared

public enum ResolveError: Error, Equatable, Sendable, CustomStringConvertible {
    case failed(String)
    case timeout
    case notFound
    case fakeIP([String])
    case noServers

    public var description: String {
        switch self {
        case .failed(let msg): return "解析失败: \(msg)"
        case .timeout: return "解析超时"
        case .notFound: return "域名不存在或没有 IPv4 地址"
        case .fakeIP(let ips): return "解析到代理 Fake-IP（\(ips.first ?? "")），请在设置中使用物理网络 DNS"
        case .noServers: return "没有可用的 DNS 服务器"
        }
    }
}

public enum DNSResolver {
    /// 物理网络 DNS 不可达时（例如非 root 进程受“本地网络”隐私限制）经由物理网卡使用的公共 DNS
    public static let fallbackServers = ["223.5.5.5", "119.29.29.29", "8.8.8.8"]

    /// 按模式解析域名的 IPv4 地址，并过滤不可路由 / Fake-IP 结果
    public static func resolve(_ domain: String, mode: DNSMode, customServers: [String], physical: NetworkInterfaceInfo?) -> Result<[String], ResolveError> {
        let raw: Result<[String], ResolveError>
        switch mode {
        case .system:
            raw = resolveSystem(domain)
        case .physical:
            guard let physical else { return .failure(.noServers) }
            var servers = physical.dnsServers.filter { TargetParser.ipv4Value($0) != nil }
            if servers.isEmpty, let router = physical.router { servers = [router] }
            servers += fallbackServers.filter { !servers.contains($0) }
            raw = DNSClient.resolveA(domain, servers: servers, interface: physical.name)
        case .custom:
            guard !customServers.isEmpty else { return .failure(.noServers) }
            raw = DNSClient.resolveA(domain, servers: customServers, interface: physical?.name)
        }
        return raw.flatMap(filter)
    }

    static func filter(_ ips: [String]) -> Result<[String], ResolveError> {
        let routable = ips.filter { !TargetParser.isUnroutableResolution($0) }
        let real = routable.filter { !TargetParser.isFakeIP($0) }
        if real.isEmpty {
            return routable.isEmpty ? .failure(.notFound) : .failure(.fakeIP(routable))
        }
        return .success(real)
    }

    /// 系统解析器（带超时，避免断网时 getaddrinfo 长时间阻塞）
    public static func resolveSystem(_ host: String, timeout: TimeInterval = 8) -> Result<[String], ResolveError> {
        final class Box: @unchecked Sendable { var result: Result<[String], ResolveError>? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.result = blockingResolve(host)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let result = box.result else {
            return .failure(.timeout)
        }
        return result
    }

    private static func blockingResolve(_ host: String) -> Result<[String], ResolveError> {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0 else {
            return rc == EAI_NONAME ? .failure(.notFound) : .failure(.failed(String(cString: gai_strerror(rc))))
        }
        defer { freeaddrinfo(res) }

        var ips: [String] = []
        var cursor = res
        while let ai = cursor {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    TargetParser.ipv4String(UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
                }
                if !ips.contains(ip) { ips.append(ip) }
            }
            cursor = ai.pointee.ai_next
        }
        return ips.isEmpty ? .failure(.notFound) : .success(ips)
    }
}

/// 最小 DNS 客户端：UDP A 记录查询，socket 绑定到指定网卡（IP_BOUND_IF），不受 VPN 默认路由影响
public enum DNSClient {
    public static func resolveA(_ name: String, servers: [String], interface: String?, timeout: TimeInterval = 2.5) -> Result<[String], ResolveError> {
        guard !servers.isEmpty else { return .failure(.noServers) }
        var lastError = ResolveError.timeout
        for server in servers {
            switch query(name, server: server, interface: interface, timeout: timeout) {
            case .success(let ips): return .success(ips)
            case .failure(.notFound): return .failure(.notFound)
            case .failure(let error): lastError = error
            }
        }
        return .failure(lastError)
    }

    static func query(_ name: String, server: String, interface: String?, timeout: TimeInterval) -> Result<[String], ResolveError> {
        guard let serverValue = TargetParser.ipv4Value(server) else { return .failure(.failed("无效的 DNS 服务器 \(server)")) }
        let id = UInt16.random(in: 1...UInt16.max)
        guard let packet = DNSMessage.query(id: id, name: name) else { return .failure(.failed("无效的域名")) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failure(.failed(String(cString: strerror(errno)))) }
        defer { close(fd) }

        if let interface {
            var index = if_nametoindex(interface)
            guard index != 0 else { return .failure(.failed("网卡 \(interface) 不存在")) }
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(53).bigEndian
        addr.sin_addr.s_addr = serverValue.bigEndian
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return .failure(.failed(String(cString: strerror(errno)))) }

        let deadline = Date().addingTimeInterval(timeout)
        var response = [UInt8](repeating: 0, count: 1500)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .failure(.timeout) }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(remaining * 1000)) > 0 else { return .failure(.timeout) }
            let n = recv(fd, &response, response.count, 0)
            guard n > 0 else { return .failure(.failed(String(cString: strerror(errno)))) }
            let result = DNSMessage.parseA(Array(response[0..<n]), expectedID: id)
            if case .failure(.failed("ID 不匹配")) = result { continue }
            return result
        }
    }
}

public enum DNSMessage {
    public static func query(id: UInt16, name: String) -> [UInt8]? {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let utf8 = Array(label.utf8)
            guard !utf8.isEmpty, utf8.count <= 63 else { return nil }
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(contentsOf: [0, 0, 1, 0, 1]) // root, QTYPE=A, QCLASS=IN
        return bytes.count <= 512 ? bytes : nil
    }

    public static func parseA(_ data: [UInt8], expectedID: UInt16) -> Result<[String], ResolveError> {
        guard data.count >= 12 else { return .failure(.failed("响应过短")) }
        let id = UInt16(data[0]) << 8 | UInt16(data[1])
        guard id == expectedID else { return .failure(.failed("ID 不匹配")) }
        let flags = UInt16(data[2]) << 8 | UInt16(data[3])
        guard flags & 0x8000 != 0 else { return .failure(.failed("不是 DNS 响应")) }
        switch flags & 0x000F {
        case 0: break
        case 3: return .failure(.notFound)
        case let rcode: return .failure(.failed("DNS 错误码 \(rcode)"))
        }
        if flags & 0x0200 != 0 { return .failure(.failed("响应被截断")) }

        let qdcount = Int(UInt16(data[4]) << 8 | UInt16(data[5]))
        let ancount = Int(UInt16(data[6]) << 8 | UInt16(data[7]))
        var offset = 12
        for _ in 0..<qdcount {
            guard let next = skipName(data, offset), next + 4 <= data.count else { return .failure(.failed("响应格式错误")) }
            offset = next + 4
        }
        var ips: [String] = []
        for _ in 0..<ancount {
            guard let next = skipName(data, offset), next + 10 <= data.count else { break }
            let type = UInt16(data[next]) << 8 | UInt16(data[next + 1])
            let klass = UInt16(data[next + 2]) << 8 | UInt16(data[next + 3])
            let rdlength = Int(UInt16(data[next + 8]) << 8 | UInt16(data[next + 9]))
            let rdata = next + 10
            guard rdata + rdlength <= data.count else { break }
            if type == 1, klass == 1, rdlength == 4 {
                let ip = "\(data[rdata]).\(data[rdata + 1]).\(data[rdata + 2]).\(data[rdata + 3])"
                if !ips.contains(ip) { ips.append(ip) }
            }
            offset = rdata + rdlength
        }
        return ips.isEmpty ? .failure(.notFound) : .success(ips)
    }

    /// 跳过（可能压缩的）域名，返回其后的偏移
    static func skipName(_ data: [UInt8], _ start: Int) -> Int? {
        var offset = start
        while offset < data.count {
            let length = data[offset]
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 { return offset + 2 <= data.count ? offset + 2 : nil }
            offset += Int(length) + 1
        }
        return nil
    }
}

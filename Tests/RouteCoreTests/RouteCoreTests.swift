import Darwin
@testable import RouteHelperCore
import RouteShared
import XCTest

final class TargetParserTests: XCTestCase {
    func testHosts() {
        XCTAssertEqual(TargetParser.parse("1.2.3.4"), .host("1.2.3.4"))
        XCTAssertEqual(TargetParser.parse(" 10.0.0.1 "), .host("10.0.0.1"))
        XCTAssertEqual(TargetParser.parse("8.8.8.8/32"), .host("8.8.8.8"))
        XCTAssertNil(TargetParser.parse("1.2.3.256"))
        XCTAssertNil(TargetParser.parse("1.2.3"))
    }

    func testNetworks() {
        XCTAssertEqual(TargetParser.parse("10.1.2.3/8"), .network("10.0.0.0", prefix: 8))
        XCTAssertEqual(TargetParser.parse("192.168.1.0/24"), .network("192.168.1.0", prefix: 24))
        XCTAssertNil(TargetParser.parse("10.0.0.0/33"))
        XCTAssertEqual(TargetParser.netmask(prefix: 20), "255.255.240.0")
    }

    func testDomains() {
        XCTAssertEqual(TargetParser.parse("Example.COM"), .domain("example.com"))
        XCTAssertEqual(TargetParser.parse("https://api.example.com:8443/v1?x=1"), .domain("api.example.com"))
        XCTAssertNil(TargetParser.parse("bad domain"))
        XCTAssertNil(TargetParser.parse("-bad.com"))
    }

    func testSplitInput() {
        XCTAssertEqual(TargetParser.splitInput("a.com, 1.1.1.1\nb.com；c.com"), ["a.com", "1.1.1.1", "b.com", "c.com"])
    }

    func testAddressHelpers() {
        XCTAssertTrue(TargetParser.isFakeIP("198.18.0.5"))
        XCTAssertTrue(TargetParser.isFakeIP("198.19.255.1"))
        XCTAssertFalse(TargetParser.isFakeIP("198.20.0.1"))
        XCTAssertTrue(TargetParser.sameSubnet("192.168.1.1", "192.168.1.27", mask: "255.255.255.0"))
        XCTAssertFalse(TargetParser.sameSubnet("172.20.10.1", "192.168.1.27", mask: "255.255.255.0"))
        XCTAssertTrue(TargetParser.isUnroutableResolution("127.0.0.1"))
        XCTAssertTrue(TargetParser.isUnroutableResolution("0.0.0.0"))
    }

    func testConfigDecodesLegacyFormat() throws {
        let json = #"{"rules":[{"id":"11111111-1111-1111-1111-111111111111","target":"github.com","enabled":true,"note":""}],"interface":"auto","dnsRefreshMinutes":10}"#
        let config = try RouteJSON.decoder().decode(HelperConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.rules.first?.via, .physical)
        XCTAssertEqual(config.rules.first?.group, "")
        XCTAssertEqual(config.dnsMode, .physical)
        XCTAssertEqual(config.revision, 0)
    }
}

final class RouteToolTests: XCTestCase {
    func testParseGetOutput() {
        let output = """
           route to: 1.1.1.1
        destination: default
               mask: default
          interface: utun19
              flags: <UP,DONE,CLONING,STATIC,GLOBAL>
        """
        let info = RouteTool.parseGetOutput(output)
        XCTAssertNil(info.gateway)
        XCTAssertEqual(info.interface, "utun19")
        XCTAssertEqual(info.destination, "default")
    }

    func testAddArguments() {
        XCTAssertEqual(RouteTool.addArguments("1.2.3.4", via: NextHop(gateway: "192.168.1.1", interface: "en0")), ["-n", "add", "-host", "1.2.3.4", "192.168.1.1"])
        XCTAssertEqual(RouteTool.addArguments("10.0.0.0/8", via: NextHop(gateway: nil, interface: "utun3")), ["-n", "add", "-net", "10.0.0.0/8", "-interface", "utun3"])
    }
}

final class RoutingTableTests: XCTestCase {
    /// 构造一条 NET_RT_DUMP 消息
    private func message(flags: Int32, index: UInt16, sockaddrs: [(Int32, [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        var addrs: Int32 = 0
        for (rta, sa) in sockaddrs.sorted(by: { $0.0 < $1.0 }) {
            addrs |= Int32(1) << rta
            body += sa
            let rounded = sa.isEmpty ? 4 : 1 + ((sa.count - 1) | 3)
            body += [UInt8](repeating: 0, count: rounded - sa.count)
        }
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(RTM_GET)
        header.rtm_index = index
        header.rtm_flags = flags
        header.rtm_addrs = addrs
        return withUnsafeBytes(of: &header) { Array($0) } + body
    }

    private func sin(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
        [16, UInt8(AF_INET), 0, 0, a, b, c, d, 0, 0, 0, 0, 0, 0, 0, 0]
    }

    func testParsesHostNetAndStaleRoutes() {
        let bytes = message(flags: RTF_UP | RTF_GATEWAY | RTF_HOST | RTF_STATIC, index: 4,
                            sockaddrs: [(RTAX_DST, sin(203, 0, 113, 22)), (RTAX_GATEWAY, sin(172, 20, 10, 1)), (RTAX_IFA, sin(172, 20, 10, 9))])
            + message(flags: RTF_UP | RTF_GATEWAY | RTF_STATIC, index: 4,
                      sockaddrs: [(RTAX_DST, sin(10, 0, 0, 0)), (RTAX_GATEWAY, sin(192, 168, 1, 1)), (RTAX_NETMASK, [5, 255, 0, 0, 255])])
            + message(flags: RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_IFSCOPE, index: 4,
                      sockaddrs: [(RTAX_DST, sin(0, 0, 0, 0)), (RTAX_GATEWAY, sin(192, 168, 1, 1)), (RTAX_NETMASK, [])])

        let entries = bytes.withUnsafeBytes { RoutingTable.parse($0, interfaceName: { _ in "en0" }) }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].address, "203.0.113.22")
        XCTAssertEqual(entries[0].gateway, "172.20.10.1")
        XCTAssertEqual(entries[0].interfaceAddress, "172.20.10.9")
        XCTAssertEqual(entries[0].flagString, "UGHS")
        XCTAssertEqual(entries[1].address, "10.0.0.0/8")
        XCTAssertEqual(entries[2].displayDestination, "default")
        XCTAssertTrue(entries[2].isScoped)

        let local = [LocalAddress(interface: "en0", address: "192.168.1.27", netmask: "255.255.255.0")]
        XCTAssertNotNil(RouteAnalyzer.staleReason(entries[0], localAddresses: local))
        XCTAssertNil(RouteAnalyzer.staleReason(entries[1], localAddresses: local))
        XCTAssertNil(RoutingTable.exactRoute(for: "0.0.0.0/0", in: entries), "scoped 路由不参与精确匹配")
    }

    func testLiveDumpReturnsDefaultRoute() {
        XCTAssertTrue(RoutingTable.dump().contains { $0.prefix == 0 }, "本机路由表应至少包含一条默认路由")
    }
}

final class DNSMessageTests: XCTestCase {
    func testQueryAndCompressedResponse() throws {
        let query = try XCTUnwrap(DNSMessage.query(id: 0x1234, name: "www.example.com"))
        XCTAssertEqual(query.count, 12 + 17 + 4)

        var response = query
        response[2] = 0x81; response[3] = 0x80 // QR, RD, RA
        response[7] = 2 // ANCOUNT
        // CNAME: 指向问题中的名字（压缩指针 0xC00C）
        response += [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, 2, 0xC0, 0x10]
        // A: 93.184.216.34
        response += [0xC0, 0x10, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        XCTAssertEqual(DNSMessage.parseA(response, expectedID: 0x1234), .success(["93.184.216.34"]))
        XCTAssertEqual(DNSMessage.parseA(response, expectedID: 0x9999), .failure(.failed("ID 不匹配")))

        var nx = query
        nx[2] = 0x81; nx[3] = 0x83
        XCTAssertEqual(DNSMessage.parseA(nx, expectedID: 0x1234), .failure(.notFound))
    }

    func testFakeIPIsRejected() {
        XCTAssertEqual(DNSResolver.filter(["198.18.0.7"]), .failure(.fakeIP(["198.18.0.7"])))
        XCTAssertEqual(DNSResolver.filter(["198.18.0.7", "1.2.3.4"]), .success(["1.2.3.4"]))
    }
}

final class GatewayDetectorTests: XCTestCase {
    let entries: [GatewayDetector.ServiceEntry] = [
        .init(serviceID: "vpn", ipv4: ["InterfaceName": "utun19", "Router": "100.100.10.53", "Addresses": ["100.100.10.53"]]),
        .init(serviceID: "feth", ipv4: ["InterfaceName": "feth1234", "Router": "127.0.0.1", "Addresses": ["10.99.0.91"]]),
        .init(serviceID: "wifi", ipv4: ["InterfaceName": "en0", "Router": "192.168.1.1", "Addresses": ["192.168.1.27"], "SubnetMasks": ["255.255.255.0"]],
              dns: ["ServerAddresses": ["192.168.1.1", "fe80::1"]]),
        .init(serviceID: "eth", ipv4: ["InterfaceName": "en7", "Router": "10.0.0.1", "Addresses": ["10.0.0.5"]]),
    ]

    func testSkipsTunnelsAndUsesServiceOrder() {
        XCTAssertEqual(GatewayDetector.choose(entries: entries, serviceOrder: ["vpn", "eth", "wifi"], preferredInterface: "auto").physical?.router, "10.0.0.1")
        let snapshot = GatewayDetector.choose(entries: entries, serviceOrder: ["vpn", "wifi", "eth"], preferredInterface: "auto")
        XCTAssertEqual(snapshot.physical?.interface, "en0")
        XCTAssertEqual(snapshot.physicalInterface?.dnsServers, ["192.168.1.1"])
        XCTAssertEqual(snapshot.interfaces.first { $0.name == "utun19" }?.router, nil, "VPN 的 Router 等于自身地址，应视为无网关")
        XCTAssertEqual(snapshot.interfaces.first { $0.name == "utun19" }?.isVirtual, true)
    }

    func testPreferredInterface() {
        XCTAssertEqual(GatewayDetector.choose(entries: entries, serviceOrder: [], preferredInterface: "en0").physical?.router, "192.168.1.1")
        XCTAssertNil(GatewayDetector.choose(entries: entries, serviceOrder: [], preferredInterface: "en9").physical)
    }
}

// MARK: - 引擎一致性测试

/// 模拟内核路由表与网络环境
final class FakeSystem: RouteSystem {
    var network: GatewayDetector.Snapshot
    var table: [String: RouteEntry] = [:]
    var dnsAnswers: [String: Result<[String], ResolveError>] = [:]
    var failAdd = Set<String>()
    var operations: [String] = []

    init(network: GatewayDetector.Snapshot) {
        self.network = network
    }

    func networkSnapshot(preferredInterface: String) -> GatewayDetector.Snapshot { network }
    func routingTable() -> [RouteEntry] { Array(table.values) }

    func addRoute(_ address: String, via hop: NextHop) -> Result<Void, RouteToolError> {
        if failAdd.contains(address) { return .failure(RouteToolError(message: "模拟失败")) }
        if table[address] != nil { return .failure(RouteToolError(message: "File exists")) }
        table[address] = FakeSystem.entry(address, gateway: hop.gateway, network: network, interface: hop.interface)
        operations.append("add \(address) \(hop.gateway ?? hop.interface ?? "")")
        return .success(())
    }

    func deleteRoute(_ address: String) -> Result<Void, RouteToolError> {
        guard table.removeValue(forKey: address) != nil else { return .failure(RouteToolError(message: "not in table")) }
        operations.append("delete \(address)")
        return .success(())
    }

    func resolve(_ domain: String, mode: DNSMode, customServers: [String], physical: NetworkInterfaceInfo?) -> Result<[String], ResolveError> {
        dnsAnswers[domain] ?? .failure(.notFound)
    }

    static func entry(_ address: String, gateway: String?, network: GatewayDetector.Snapshot, interface: String? = nil) -> RouteEntry {
        let parts = address.split(separator: "/")
        let info = network.interfaces.first { i in
            if let interface { return i.name == interface }
            guard let gateway, let local = i.localAddress, let mask = i.subnetMask else { return false }
            return TargetParser.sameSubnet(gateway, local, mask: mask)
        }
        return RouteEntry(destination: String(parts[0]), prefix: parts.count == 2 ? Int(parts[1])! : 32, gateway: gateway,
                          interface: info?.name ?? interface ?? "en0", interfaceAddress: info?.localAddress,
                          flags: RTF_UP | RTF_STATIC | (gateway != nil ? RTF_GATEWAY : 0) | (parts.count == 1 ? RTF_HOST : 0))
    }
}

final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

final class RouteEngineTests: XCTestCase {
    static let vpn = NetworkInterfaceInfo(name: "utun19", router: nil, localAddress: "100.100.10.53", subnetMask: nil, dnsServers: [], isVirtual: true)
    static let wifi = GatewayDetector.Snapshot(
        physical: GatewayInfo(interface: "en0", router: "192.168.1.1", localAddress: "192.168.1.27"),
        interfaces: [NetworkInterfaceInfo(name: "en0", router: "192.168.1.1", localAddress: "192.168.1.27", subnetMask: "255.255.255.0", dnsServers: ["192.168.1.1"], isVirtual: false), vpn])
    static let hotspot = GatewayDetector.Snapshot(
        physical: GatewayInfo(interface: "en0", router: "172.20.10.1", localAddress: "172.20.10.9"),
        interfaces: [NetworkInterfaceInfo(name: "en0", router: "172.20.10.1", localAddress: "172.20.10.9", subnetMask: "255.255.255.240", dnsServers: ["172.20.10.1"], isVirtual: false), vpn])
    static let offline = GatewayDetector.Snapshot(physical: nil, interfaces: [vpn])

    var storage: URL!
    var system: FakeSystem!
    var clock: Clock!

    override func setUp() {
        storage = FileManager.default.temporaryDirectory.appendingPathComponent("MacOSRouteTests-\(UUID().uuidString)")
        system = FakeSystem(network: Self.wifi)
        clock = Clock()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storage)
    }

    private func makeEngine() -> RouteEngine {
        let clock = self.clock!
        return RouteEngine(storageDirectory: storage, system: system, now: { clock.date })
    }

    @discardableResult
    private func update(_ engine: RouteEngine, _ body: (inout HelperConfig) -> Void) -> Bool {
        var config = engine.currentState().config
        body(&config)
        var conflict = false
        engine.updateConfig(config) { _, c in conflict = c }
        engine.workQueue.sync {}
        return !conflict
    }

    private func status(_ engine: RouteEngine, _ rule: RouteRule) -> RuleStatus? {
        engine.currentState().statuses[rule.id.uuidString]
    }

    func testAppliesHostNetworkAndDomainRules() {
        system.dnsAnswers["example.com"] = .success(["93.184.216.34", "93.184.216.35"])
        let engine = makeEngine()
        let rules = [RouteRule(target: "1.2.3.4"), RouteRule(target: "10.0.0.0/8"), RouteRule(target: "example.com")]
        update(engine) { $0.rules = rules }

        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.1")
        XCTAssertEqual(system.table["10.0.0.0/8"]?.gateway, "192.168.1.1")
        XCTAssertEqual(system.table["93.184.216.35"]?.gateway, "192.168.1.1")
        XCTAssertEqual(status(engine, rules[2])?.appliedAddresses.count, 2)
        XCTAssertEqual(engine.currentState().managedRoutes.count, 4)
    }

    func testWiFiSwitchReplacesRoutesUsingDeleteAndAdd() {
        system.network = Self.hotspot
        let engine = makeEngine()
        let rule = RouteRule(target: "203.0.113.22")
        update(engine) { $0.rules = [rule] }
        XCTAssertEqual(system.table["203.0.113.22"]?.gateway, "172.20.10.1")

        system.network = Self.wifi
        system.operations.removeAll()
        engine.reconcileNow(reason: "网络状态变化")

        XCTAssertEqual(system.table["203.0.113.22"]?.gateway, "192.168.1.1")
        XCTAssertEqual(system.table["203.0.113.22"]?.interfaceAddress, "192.168.1.27")
        XCTAssertEqual(system.operations, ["delete 203.0.113.22", "add 203.0.113.22 192.168.1.1"])
        XCTAssertEqual(status(engine, rule)?.appliedAddresses, ["203.0.113.22"])
    }

    func testFixesRouteWithStaleSourceAddress() {
        let engine = makeEngine()
        // 网关相同但仍绑定旧网络的源地址（route change 后常见）
        var stale = FakeSystem.entry("1.2.3.4", gateway: "192.168.1.1", network: Self.wifi)
        stale.interfaceAddress = "172.20.10.9"
        system.table["1.2.3.4"] = stale
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        XCTAssertEqual(system.table["1.2.3.4"]?.interfaceAddress, "192.168.1.27")
    }

    func testKeepsRoutesWhileOffline() {
        let engine = makeEngine()
        let rule = RouteRule(target: "1.2.3.4")
        update(engine) { $0.rules = [rule] }

        system.network = Self.offline
        engine.reconcileNow()
        XCTAssertNotNil(system.table["1.2.3.4"], "断网时不应删除路由")
        XCTAssertTrue(status(engine, rule)?.error?.contains("保留") ?? false)

        system.network = Self.hotspot
        engine.reconcileNow()
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "172.20.10.1")
    }

    func testRepairsRouteRemovedByAnotherProgram() {
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        system.table["1.2.3.4"] = nil // 例如 VPN 连接时清理了路由
        engine.reconcileNow()
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.1")
    }

    func testRemovingRuleOnlyDeletesRoutesWeStillOwn() {
        let engine = makeEngine()
        let a = RouteRule(target: "1.2.3.4"), b = RouteRule(target: "5.6.7.8")
        update(engine) { $0.rules = [a, b] }
        // 5.6.7.8 被其他程序改成了别的网关
        system.table["5.6.7.8"] = FakeSystem.entry("5.6.7.8", gateway: "192.168.1.254", network: Self.wifi)

        update(engine) { $0.rules = [] }
        XCTAssertNil(system.table["1.2.3.4"])
        XCTAssertEqual(system.table["5.6.7.8"]?.gateway, "192.168.1.254", "不应删除别人的路由")
        XCTAssertTrue(engine.currentState().managedRoutes.isEmpty)
    }

    func testRestoresReplacedStaticRoute() {
        system.table["1.2.3.4"] = FakeSystem.entry("1.2.3.4", gateway: "192.168.1.254", network: Self.wifi)
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.1")

        update(engine) { $0.rules = [] }
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.254", "删除规则后应恢复原有路由")
    }

    func testAdoptedIdenticalRouteIsKeptAfterRuleRemoval() {
        // 例如 VPN 客户端自己的 100.64.0.0/10 → utun19
        system.table["100.64.0.0/10"] = FakeSystem.entry("100.64.0.0/10", gateway: nil, network: Self.wifi, interface: "utun19")
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "100.64.0.0/10", via: .interface("utun19"))] }
        XCTAssertTrue(system.operations.isEmpty, "相同的路由不应被重建")

        update(engine) { $0.rules = [] }
        XCTAssertNotNil(system.table["100.64.0.0/10"], "删除规则不应删除原本就存在的路由")
    }

    func testAdoptedRouteBecomesOwnedAfterReplacement() {
        system.table["1.2.3.4"] = FakeSystem.entry("1.2.3.4", gateway: "192.168.1.1", network: Self.wifi)
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        system.network = Self.hotspot
        engine.reconcileNow()
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "172.20.10.1")

        update(engine) { $0.rules = [] }
        XCTAssertNil(system.table["1.2.3.4"], "网络切换后重建的路由归我们所有，删除规则时清理")
    }

    func testStaleRouteIsNotRestored() {
        // 在热点网络下留下的失效路由
        system.table["203.0.113.22"] = FakeSystem.entry("203.0.113.22", gateway: "172.20.10.1", network: Self.hotspot)
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "203.0.113.22")] }
        XCTAssertEqual(system.table["203.0.113.22"]?.gateway, "192.168.1.1")

        update(engine) { $0.rules = [] }
        XCTAssertNil(system.table["203.0.113.22"], "失效路由不应被恢复")
    }

    func testFailedAddIsNotRecordedAndIsRetried() {
        system.failAdd = ["1.2.3.4"]
        let engine = makeEngine()
        let rule = RouteRule(target: "1.2.3.4")
        update(engine) { $0.rules = [rule] }
        XCTAssertEqual(status(engine, rule)?.error, "模拟失败")
        XCTAssertTrue(engine.currentState().managedRoutes.isEmpty)

        system.failAdd = []
        engine.reconcileNow()
        XCTAssertNotNil(system.table["1.2.3.4"])
        XCTAssertNil(status(engine, rule)?.error)
    }

    func testDNSFailureKeepsLastResult() {
        system.dnsAnswers["example.com"] = .success(["93.184.216.34"])
        let engine = makeEngine()
        let rule = RouteRule(target: "example.com")
        update(engine) { $0.rules = [rule] }

        system.dnsAnswers["example.com"] = .failure(.timeout)
        engine.reconcileNow(forceResolve: true)
        XCTAssertNotNil(system.table["93.184.216.34"])
        XCTAssertEqual(status(engine, rule)?.appliedAddresses, ["93.184.216.34"])
        XCTAssertNotNil(status(engine, rule)?.warning)
    }

    func testChangedDNSAnswersAreRetainedThenPruned() {
        system.dnsAnswers["cdn.example.com"] = .success(["1.1.1.1"])
        let engine = makeEngine()
        let rule = RouteRule(target: "cdn.example.com")
        update(engine) { $0.rules = [rule]; $0.dnsRetentionHours = 6 }

        clock.date += 11 * 60
        system.dnsAnswers["cdn.example.com"] = .success(["2.2.2.2"])
        engine.reconcileNow()
        XCTAssertNotNil(system.table["1.1.1.1"], "旧 IP 在保留期内继续有效")
        XCTAssertNotNil(system.table["2.2.2.2"])
        XCTAssertEqual(status(engine, rule)?.retainedAddresses, ["1.1.1.1"])

        clock.date += 7 * 3600
        engine.reconcileNow()
        XCTAssertNil(system.table["1.1.1.1"], "超过保留期后删除")
        XCTAssertNotNil(system.table["2.2.2.2"])
    }

    func testRevisionConflictIsRejected() {
        let engine = makeEngine()
        let stale = engine.currentState().config
        XCTAssertTrue(update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] })

        var other = stale
        other.rules = [RouteRule(target: "5.6.7.8")]
        var conflict = false
        engine.updateConfig(other) { _, c in conflict = c }
        engine.workQueue.sync {}
        XCTAssertTrue(conflict)
        XCTAssertEqual(engine.currentState().config.rules.map(\.target), ["1.2.3.4"])
    }

    func testPauseAndResume() {
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }
        update(engine) { $0.paused = true }
        XCTAssertNil(system.table["1.2.3.4"])
        update(engine) { $0.paused = false }
        XCTAssertNotNil(system.table["1.2.3.4"])
    }

    func testRecordsSurviveRestart() {
        let rule = RouteRule(target: "1.2.3.4")
        update(makeEngine()) { $0.rules = [rule] }

        let restarted = makeEngine()
        XCTAssertEqual(restarted.currentState().config.rules, [rule])
        update(restarted) { $0.rules = [] }
        XCTAssertNil(system.table["1.2.3.4"], "重启后仍能清理之前添加的路由")
    }

    func testConflictingNextHopsPreferEarlierRule() {
        let engine = makeEngine()
        let first = RouteRule(target: "1.2.3.4")
        let second = RouteRule(target: "1.2.3.4/32", via: .interface("utun19"))
        update(engine) { $0.rules = [first, second] }
        XCTAssertEqual(system.table["1.2.3.4"]?.gateway, "192.168.1.1")
        XCTAssertNotNil(status(engine, second)?.warning)
    }

    func testInterfaceAndGatewayVia() {
        let engine = makeEngine()
        update(engine) {
            $0.rules = [RouteRule(target: "100.64.0.0/10", via: .interface("utun19")),
                        RouteRule(target: "8.8.8.8", via: .gateway("192.168.1.254")),
                        RouteRule(target: "9.9.9.9", via: .gateway("10.9.9.1"))]
        }
        XCTAssertNil(system.table["100.64.0.0/10"]?.gateway)
        XCTAssertEqual(system.table["100.64.0.0/10"]?.interface, "utun19")
        XCTAssertEqual(system.table["8.8.8.8"]?.gateway, "192.168.1.254")
        XCTAssertNil(system.table["9.9.9.9"], "网关不在当前网络中时不添加")
    }

    func testDeleteSystemRoutesRefusesManagedRoutes() {
        system.table["203.0.113.22"] = FakeSystem.entry("203.0.113.22", gateway: "172.20.10.1", network: Self.hotspot)
        let engine = makeEngine()
        update(engine) { $0.rules = [RouteRule(target: "1.2.3.4")] }

        var error: String?
        engine.deleteSystemRoutes(["203.0.113.22", "1.2.3.4"]) { error = $0 }
        engine.workQueue.sync {}
        XCTAssertNil(system.table["203.0.113.22"])
        XCTAssertNotNil(system.table["1.2.3.4"])
        XCTAssertTrue(error?.contains("1.2.3.4") ?? false)
    }
}

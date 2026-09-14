import Foundation
import RouteShared

/// 路由引擎：保存配置、跟踪已添加的路由，并把期望状态同步（reconcile）到内核路由表。
///
/// 一致性约定：
/// - 所有变更都在 workQueue 上串行执行；对外发布的快照受 lock 保护，读取不会被慢操作阻塞。
/// - applied.json 记录的路由始终是实际添加路由的超集：添加前先记录，删除成功后再移除记录，崩溃后重启可以继续清理。
/// - 每次同步都以内核路由表为准重新比对，而不是信任上一次的结果，因此能修复被 VPN 等程序改动的路由。
/// - 下一跳暂时不可用（断网、网卡未连接）时保留现有路由，不做删除。
/// - 删除规则时让该地址回到规则存在之前的状态：原本就存在且相同的路由保留，被替换的有效静态路由恢复，失效的不恢复。
public final class RouteEngine: @unchecked Sendable {
    struct AppliedRoute: Codable, Equatable {
        var gateway: String?
        var interface: String?
        /// 被替换掉的原有静态路由网关，删除规则时恢复
        var restoreGateway: String?
        /// 规则生效前内核中已存在完全相同的路由（例如 VPN 自己的路由），删除规则时保留
        var adopted: Bool?

        /// 内核中的这条路由是否仍是我们添加的
        func owns(_ entry: RouteEntry) -> Bool {
            if let gateway { return entry.gateway == gateway }
            return entry.gateway == nil && entry.interface == interface
        }
    }

    struct DNSRecord: Codable, Equatable {
        /// IP -> 最近一次出现在解析结果中的时间
        var addresses: [String: Date] = [:]
        var resolvedAt: Date?
        var lastError: String?
        var retryAfter: Date?

        var currentAddresses: [String] {
            guard let resolvedAt else { return [] }
            return addresses.filter { $0.value >= resolvedAt }.map(\.key).sorted(by: ipLess)
        }

        var retainedAddresses: [String] {
            addresses.filter { resolvedAt == nil || $0.value < resolvedAt! }.map(\.key).sorted(by: ipLess)
        }
    }

    public let workQueue = DispatchQueue(label: "com.hyperits.app.MacOSRoute.engine")
    private let system: RouteSystem
    private let storageDirectory: URL
    private let now: () -> Date

    // 仅在 workQueue 上访问
    private var config: HelperConfig
    private var applied: [String: AppliedRoute]
    private var dns: [String: DNSRecord]
    private var pendingReconcile: DispatchWorkItem?
    private var pendingForceResolve = false
    /// removeAllRoutes 之后暂停同步（卸载流程），直到配置更新或手动重新应用
    private var suspended = false
    private var networkMonitor: NetworkChangeMonitor?
    private var routingMonitor: RoutingTableMonitor?
    private var timer: DispatchSourceTimer?

    // 受 lock 保护
    private let lock = NSLock()
    private var snapshot: HelperState

    private static let maxLogs = 500
    private static let maxAddressesPerDomain = 64
    private static let dnsRetryInterval: TimeInterval = 60

    public init(storageDirectory: URL, system: RouteSystem, now: @escaping () -> Date = Date.init) {
        self.storageDirectory = storageDirectory
        self.system = system
        self.now = now
        config = Self.load(HelperConfig.self, from: storageDirectory.appendingPathComponent("config.json")) ?? HelperConfig()
        applied = Self.load([String: AppliedRoute].self, from: storageDirectory.appendingPathComponent("applied.json")) ?? [:]
        dns = Self.load([String: DNSRecord].self, from: storageDirectory.appendingPathComponent("dns.json")) ?? [:]
        snapshot = HelperState(version: RouteConstants.helperVersion, config: config)
    }

    public func start() {
        workQueue.async { [self] in
            log(.info, "Helper \(RouteConstants.helperVersion) 启动，规则 \(config.rules.count) 条，已记录路由 \(applied.count) 条")
            networkMonitor = NetworkChangeMonitor(queue: workQueue) { [weak self] in
                self?.scheduleReconcile(reason: "网络状态变化", delay: 2, forceResolve: true)
            }
            routingMonitor = RoutingTableMonitor(queue: workQueue) { [weak self] in
                self?.scheduleReconcile(reason: nil, delay: 2, forceResolve: false)
            }
            // 兜底定时校验：处理漏掉的事件，并按间隔刷新域名解析
            let timer = DispatchSource.makeTimerSource(queue: workQueue)
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { [weak self] in self?.reconcile(reason: nil, forceResolve: false) }
            timer.resume()
            self.timer = timer
            reconcile(reason: "启动", forceResolve: false)
        }
    }

    // MARK: - 外部接口（任意线程调用）

    public func currentState() -> HelperState {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func updateConfig(_ newConfig: HelperConfig, completion: @escaping (_ error: String?, _ conflict: Bool) -> Void) {
        workQueue.async { [self] in
            guard newConfig.revision == config.revision else {
                completion(nil, true)
                return
            }
            var next = newConfig
            next.sanitize()
            next.revision = config.revision + 1
            do {
                try save(next, to: "config.json")
            } catch {
                log(.error, "保存配置失败: \(error.localizedDescription)")
                completion("保存配置失败: \(error.localizedDescription)", false)
                return
            }
            let reason = next.paused != config.paused ? (next.paused ? "已暂停" : "已恢复") : "配置变更"
            config = next
            suspended = false
            lock.lock()
            snapshot.config = next
            lock.unlock()
            completion(nil, false)
            reconcile(reason: reason, forceResolve: false)
        }
    }

    public func reapplyAll(completion: @escaping (String?) -> Void) {
        workQueue.async { [self] in
            suspended = false
            for key in dns.keys {
                dns[key]?.resolvedAt = nil
                dns[key]?.retryAfter = nil
            }
            reconcile(reason: "手动重新应用", forceResolve: true)
            completion(nil)
        }
    }

    public func removeAllRoutes(completion: @escaping (String?) -> Void) {
        workQueue.async { [self] in
            suspended = true
            pendingReconcile?.cancel()
            let table = system.routingTable()
            var failures: [String] = []
            for address in applied.keys.sorted() {
                if let error = removeManagedRoute(address, table: table) {
                    failures.append("\(address): \(error)")
                }
            }
            log(.info, "已删除由 MacOSRoute 添加的路由，同步已暂停")
            publish(statuses: [:], network: system.networkSnapshot(preferredInterface: config.interface), applyDate: nil)
            completion(failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }
    }

    public func deleteSystemRoutes(_ addresses: [String], completion: @escaping (String?) -> Void) {
        workQueue.async { [self] in
            let table = system.routingTable()
            var failures: [String] = []
            for address in addresses {
                guard applied[address] == nil else {
                    failures.append("\(address): 由 MacOSRoute 管理，请删除对应规则")
                    continue
                }
                guard let entry = RoutingTable.exactRoute(for: address, in: table), entry.isStatic else {
                    failures.append("\(address): 不是静态路由或已不存在")
                    continue
                }
                switch system.deleteRoute(address) {
                case .success:
                    log(.info, "已删除系统路由 \(address) → \(entry.gateway ?? entry.interface)")
                case .failure(let error):
                    failures.append("\(address): \(error)")
                }
            }
            completion(failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }
    }

    /// 测试用：同步执行一次同步
    func reconcileNow(reason: String? = nil, forceResolve: Bool = false) {
        workQueue.sync { reconcile(reason: reason, forceResolve: forceResolve) }
    }

    // MARK: - 同步逻辑

    private func scheduleReconcile(reason: String?, delay: TimeInterval, forceResolve: Bool) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        pendingReconcile?.cancel()
        pendingForceResolve = pendingForceResolve || forceResolve
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconcile(reason: reason, forceResolve: self.pendingForceResolve)
        }
        pendingReconcile = item
        workQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reconcile(reason: String?, forceResolve: Bool) {
        dispatchPrecondition(condition: .onQueue(workQueue))
        pendingReconcile?.cancel()
        pendingReconcile = nil
        pendingForceResolve = false
        guard !suspended else { return }

        let network = system.networkSnapshot(preferredInterface: config.interface)
        let previous = currentState().gateway
        if network.physical?.interface != previous?.interface || network.physical?.router != previous?.router {
            if let gw = network.physical {
                log(.info, "物理网关: \(gw.interface) → \(gw.router)")
            } else {
                log(.warning, config.interface == HelperConfig.automaticInterface ? "未找到可用的物理网关" : "网卡 \(config.interface) 没有可用网关")
            }
        }
        if let reason { log(.info, "同步路由（\(reason)）") }

        if !config.paused {
            resolveDomains(force: forceResolve, network: network)
        }

        // 1. 计算期望状态
        var statuses: [String: RuleStatus] = [:]
        var desired: [String: (hop: NextHop, rule: RouteRule)] = [:]
        var keep = Set<String>()
        for rule in config.rules {
            var status = RuleStatus()
            switch TargetParser.parse(rule.target) {
            case nil:
                status.error = "无效的目标"
            case .host(let ip):
                status.addresses = [ip]
            case .network(let net, let prefix):
                status.addresses = ["\(net)/\(prefix)"]
            case .domain(let domain):
                if let record = dns[domain] {
                    status.retainedAddresses = record.retainedAddresses
                    status.addresses = record.currentAddresses + record.retainedAddresses
                    status.resolvedAt = record.resolvedAt
                    if let error = record.lastError {
                        if status.addresses.isEmpty { status.error = error } else { status.warning = "\(error)，沿用上次结果" }
                    }
                }
            }

            if rule.enabled, !config.paused, !status.addresses.isEmpty {
                switch nextHop(for: rule.via, network: network) {
                case .failure(let failure):
                    status.error = failure.message
                    keep.formUnion(status.addresses)
                case .success(let hop):
                    status.nextHop = hop.label
                    for address in status.addresses {
                        if let owner = desired[address] {
                            if owner.hop != hop {
                                status.warning = "\(address) 与规则「\(owner.rule.target)」的出口冲突，以排在前面的规则为准"
                            }
                        } else {
                            desired[address] = (hop, rule)
                        }
                    }
                }
            }
            statuses[rule.id.uuidString] = status
        }

        // 2. 删除不再需要的路由
        var table = system.routingTable()
        var changed = false
        for address in applied.keys.sorted() where desired[address] == nil && !keep.contains(address) {
            _ = removeManagedRoute(address, table: table)
            changed = true
        }

        // 3. 添加 / 修正路由
        var failed: [String: String] = [:]
        for address in desired.keys.sorted(by: ipLess) {
            let want = desired[address]!.hop
            let existing = RoutingTable.exactRoute(for: address, in: table)
            if let existing, want.isSatisfied(by: existing) {
                if applied[address]?.gateway != want.gateway || applied[address]?.interface != want.interface {
                    var record = applied[address] ?? AppliedRoute(adopted: true)
                    record.gateway = want.gateway
                    record.interface = want.interface
                    applied[address] = record
                    saveApplied()
                }
                continue
            }

            var record = applied[address] ?? AppliedRoute()
            if applied[address] == nil, let existing, existing.isStatic, existing.hasGateway, !existing.isCloned,
               existing.gateway != want.gateway, isReachable(existing.gateway, network: network) {
                record.restoreGateway = existing.gateway
            }
            record.adopted = nil
            record.gateway = want.gateway
            record.interface = want.interface
            applied[address] = record
            saveApplied() // 先记录意图，再修改内核

            changed = true
            // 使用“删除 + 添加”而不是 route change：网络切换后 change 可能保留旧的源地址（ifa）
            if existing != nil { _ = system.deleteRoute(address) }
            var result = system.addRoute(address, via: want)
            if case .failure = result, existing == nil, case .success = system.deleteRoute(address) {
                result = system.addRoute(address, via: want) // 可能存在未识别的等价路由，删除后重试
            }
            switch result {
            case .success:
                if let existing {
                    log(.info, "已修正路由 \(address) → \(want.label)（原为 \(existing.gateway ?? existing.interface)）")
                } else {
                    log(.info, "已添加路由 \(address) → \(want.label)")
                }
            case .failure(let error):
                failed[address] = error.message
                log(.error, "设置路由 \(address) 失败: \(error)")
                if existing != nil, let restore = record.restoreGateway {
                    _ = system.addRoute(address, via: NextHop(gateway: restore, interface: nil))
                }
                applied[address] = nil
                saveApplied()
            }
        }

        // 4. 以内核实际状态校验结果
        if changed { table = system.routingTable() }
        for (key, var status) in statuses {
            status.appliedAddresses = status.addresses.filter { address in
                guard let want = desired[address], failed[address] == nil,
                      let entry = RoutingTable.exactRoute(for: address, in: table) else { return false }
                return want.hop.isSatisfied(by: entry)
            }
            if status.error == nil, let failure = status.addresses.compactMap({ failed[$0] }).first {
                status.error = failure
            }
            statuses[key] = status
        }
        publish(statuses: statuses, network: network, applyDate: now())
    }

    /// 删除一条由我们管理的路由；如果内核中的路由已被其他程序修改则只移除记录。返回错误信息。
    private func removeManagedRoute(_ address: String, table: [RouteEntry]) -> String? {
        guard let record = applied[address] else { return nil }
        if record.adopted == true {
            log(.info, "规则已移除，保留原本就存在的路由 \(address)")
        } else if let entry = RoutingTable.exactRoute(for: address, in: table), record.owns(entry) {
            if case .failure(let error) = system.deleteRoute(address) {
                log(.error, "删除路由 \(address) 失败: \(error)")
                return error.message // 保留记录，下次同步重试
            }
            if let restore = record.restoreGateway {
                if case .failure(let error) = system.addRoute(address, via: NextHop(gateway: restore, interface: nil)) {
                    log(.warning, "已删除路由 \(address)，但恢复原网关 \(restore) 失败: \(error)")
                } else {
                    log(.info, "已删除路由 \(address)，并恢复原有网关 \(restore)")
                }
            } else {
                log(.info, "已删除路由 \(address)")
            }
        }
        applied[address] = nil
        saveApplied()
        return nil
    }

    /// 网关是否位于当前某个网络的子网内
    private func isReachable(_ gateway: String?, network: GatewayDetector.Snapshot) -> Bool {
        guard let gateway else { return false }
        return network.interfaces.contains { i in
            guard let local = i.localAddress, let mask = i.subnetMask else { return false }
            return TargetParser.sameSubnet(gateway, local, mask: mask)
        }
    }

    private func nextHop(for via: RouteVia, network: GatewayDetector.Snapshot) -> Result<NextHop, RouteToolError> {
        switch via {
        case .physical:
            guard let gw = network.physical else {
                return .failure(RouteToolError(message: config.interface == HelperConfig.automaticInterface
                    ? "未找到物理网关，保留现有路由" : "网卡 \(config.interface) 没有网关，保留现有路由"))
            }
            return .success(NextHop(gateway: gw.router, interface: gw.interface, localAddress: gw.localAddress))
        case .interface(let name):
            guard let info = network.interfaces.first(where: { $0.name == name }) else {
                return .failure(RouteToolError(message: "网卡 \(name) 未连接，保留现有路由"))
            }
            if let router = info.router, !info.isVirtual {
                return .success(NextHop(gateway: router, interface: name, localAddress: info.localAddress))
            }
            return .success(NextHop(gateway: nil, interface: name))
        case .gateway(let ip):
            guard TargetParser.ipv4Value(ip) != nil else { return .failure(RouteToolError(message: "无效的网关 \(ip)")) }
            let info = network.interfaces.first { i in
                guard let local = i.localAddress, let mask = i.subnetMask else { return false }
                return TargetParser.sameSubnet(ip, local, mask: mask)
            }
            guard let info else { return .failure(RouteToolError(message: "网关 \(ip) 不在任何当前网络中，保留现有路由")) }
            return .success(NextHop(gateway: ip, interface: info.name, localAddress: info.localAddress))
        }
    }

    // MARK: - DNS

    private func resolveDomains(force: Bool, network: GatewayDetector.Snapshot) {
        let current = now()
        var allDomains = Set<String>()
        var enabledDomains = Set<String>()
        for rule in config.rules {
            guard case .domain(let domain) = TargetParser.parse(rule.target) else { continue }
            allDomains.insert(domain)
            if rule.enabled { enabledDomains.insert(domain) }
        }
        var dirty = false
        for key in dns.keys where !allDomains.contains(key) {
            dns[key] = nil
            dirty = true
        }

        let refresh = TimeInterval(config.dnsRefreshMinutes * 60)
        let due = enabledDomains.filter { domain in
            guard let record = dns[domain] else { return true }
            if force { return true }
            if let retry = record.retryAfter { return current >= retry }
            return record.resolvedAt.map { current.timeIntervalSince($0) >= refresh } ?? true
        }.sorted()

        let physical = network.physicalInterface
        if !due.isEmpty, config.dnsMode == .system || physical != nil {
            final class Results: @unchecked Sendable {
                var values: [Result<[String], ResolveError>?]
                let lock = NSLock()
                init(count: Int) { values = Array(repeating: nil, count: count) }
            }
            let results = Results(count: due.count)
            let mode = config.dnsMode
            let servers = config.customDNSServers
            let system = self.system
            DispatchQueue.concurrentPerform(iterations: due.count) { i in
                let result = system.resolve(due[i], mode: mode, customServers: servers, physical: physical)
                results.lock.lock()
                results.values[i] = result
                results.lock.unlock()
            }

            for (domain, result) in zip(due, results.values) {
                var record = dns[domain] ?? DNSRecord()
                switch result {
                case .success(let ips)?:
                    let previous = Set(record.currentAddresses)
                    for ip in ips { record.addresses[ip] = current }
                    record.resolvedAt = current
                    record.lastError = nil
                    record.retryAfter = nil
                    if previous != Set(ips) {
                        log(.info, "\(domain) 解析为 \(ips.joined(separator: ", "))")
                    }
                case .failure(let error)?:
                    if record.lastError != error.description {
                        log(.warning, "\(domain) \(error)")
                    }
                    record.lastError = error.description
                    record.retryAfter = current.addingTimeInterval(Self.dnsRetryInterval)
                case nil:
                    continue
                }
                dns[domain] = record
            }
            dirty = true
        }

        // 清理超过保留期的旧地址
        let retention = TimeInterval(config.dnsRetentionHours * 3600)
        for domain in dns.keys {
            guard var record = dns[domain], let resolvedAt = record.resolvedAt else { continue }
            let before = record.addresses.count
            record.addresses = record.addresses.filter { $0.value >= resolvedAt || current.timeIntervalSince($0.value) < retention }
            if record.addresses.count > Self.maxAddressesPerDomain {
                let newest = record.addresses.sorted { $0.value > $1.value }.prefix(Self.maxAddressesPerDomain)
                record.addresses = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
            }
            if record.addresses.count != before {
                dns[domain] = record
                dirty = true
            }
        }
        if dirty { saveDNS() }
    }

    // MARK: - 状态发布与持久化

    private func publish(statuses: [String: RuleStatus], network: GatewayDetector.Snapshot, applyDate: Date?) {
        let managed = applied.keys.sorted(by: ipLess).map { ManagedRoute(address: $0, gateway: applied[$0]?.gateway, interface: applied[$0]?.interface) }
        lock.lock(); defer { lock.unlock() }
        snapshot.config = config
        snapshot.statuses = statuses
        snapshot.gateway = network.physical
        snapshot.interfaces = network.interfaces
        snapshot.managedRoutes = managed
        if let applyDate { snapshot.lastApplyAt = applyDate }
    }

    private func log(_ level: LogEntry.Level, _ message: String) {
        let entry = LogEntry(level: level, message: message)
        FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: entry.date)) [\(level.rawValue)] \(message)\n".utf8))
        lock.lock(); defer { lock.unlock() }
        snapshot.logs.append(entry)
        if snapshot.logs.count > Self.maxLogs {
            snapshot.logs.removeFirst(snapshot.logs.count - Self.maxLogs)
        }
    }

    private func saveApplied() {
        do { try save(applied, to: "applied.json") } catch { log(.error, "保存路由记录失败: \(error.localizedDescription)") }
    }

    private func saveDNS() {
        do { try save(dns, to: "dns.json") } catch { log(.error, "保存 DNS 缓存失败: \(error.localizedDescription)") }
    }

    private func save<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let data = try RouteJSON.encoder().encode(value)
        try data.write(to: storageDirectory.appendingPathComponent(name), options: .atomic)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? RouteJSON.decoder().decode(type, from: data)
    }
}

/// 按数值顺序比较 IP / CIDR 字符串
func ipLess(_ a: String, _ b: String) -> Bool {
    func key(_ s: String) -> (UInt32, Int) {
        let parts = s.split(separator: "/")
        return (TargetParser.ipv4Value(String(parts[0])) ?? 0, parts.count == 2 ? Int(parts[1]) ?? 32 : 32)
    }
    return key(a) < key(b)
}

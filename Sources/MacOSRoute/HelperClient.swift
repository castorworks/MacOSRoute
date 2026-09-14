import Foundation
import RouteShared

/// 与 root Helper 通信，维护界面所需的状态
@MainActor
final class HelperClient: ObservableObject {
    enum Status: Equatable {
        case checking
        case notInstalled
        case running
        case outdated(installed: String)
        case unreachable(String)
    }

    @Published private(set) var state: HelperState?
    @Published private(set) var status: Status = .checking
    @Published private(set) var isBusy = false
    @Published var alertMessage: String?

    /// 开发调试：连接用户域（launchctl gui/<uid>）中的 Helper，而不是系统 LaunchDaemon
    private let useDevAgent = ProcessInfo.processInfo.environment["MACOSROUTE_DEV_AGENT"] == "1"
    private var connection: NSXPCConnection?
    private var timer: Timer?
    /// 每次本地修改配置时递增，用于丢弃修改前发出的 fetch 结果，防止界面闪回
    private var configGeneration = 0

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// 只有版本匹配的 Helper 才能修改配置（协议可能已变化）
    var canModify: Bool { status == .running }
    var config: HelperConfig? { state?.config }
    var rules: [RouteRule] { state?.config.rules ?? [] }
    var groups: [String] { state?.config.groups ?? [] }
    var isPaused: Bool { state?.config.paused ?? false }

    func status(for rule: RouteRule) -> RuleStatus? {
        state?.statuses[rule.id.uuidString]
    }

    var isInstalled: Bool {
        useDevAgent || FileManager.default.fileExists(atPath: RouteConstants.launchDaemonPlistPath)
    }

    // MARK: - 读取

    func refresh() {
        guard isInstalled else {
            // 旧标识的 Helper 无法通过新的 Mach 服务名连接，提示更新以完成迁移
            status = HelperInstaller.legacyHelperInstalled ? .outdated(installed: "旧版") : .notInstalled
            state = nil
            return
        }
        let generation = configGeneration
        remote { [weak self] error in
            self?.status = .unreachable(error)
        }?.fetchState { data, error in
            let decoded = data.flatMap { try? RouteJSON.decoder().decode(HelperState.self, from: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.configGeneration else { return }
                self.apply(decoded, error: error)
            }
        }
    }

    private func apply(_ decoded: HelperState?, error: String?) {
        guard let decoded else {
            status = .unreachable(error ?? "无法读取后台服务状态")
            return
        }
        state = decoded
        status = decoded.version == RouteConstants.helperVersion ? .running : .outdated(installed: decoded.version)
    }

    // MARK: - 修改规则

    /// 返回无法识别的输入
    @discardableResult
    func addTargets(from text: String, note: String = "", group: String = "", via: RouteVia = .physical) -> [String] {
        let inputs = TargetParser.splitInput(text)
        let invalid = inputs.filter { TargetParser.parse($0) == nil }
        let valid = inputs.filter { TargetParser.parse($0) != nil }
        guard !valid.isEmpty else { return invalid }
        mutateConfig { config in
            var existing = Set(config.rules.map { $0.target.lowercased() })
            for target in valid where !existing.contains(target.lowercased()) {
                existing.insert(target.lowercased())
                config.rules.append(RouteRule(target: target, note: note, group: group, via: via))
            }
        }
        return invalid
    }

    func setEnabled(_ enabled: Bool, for ids: Set<RouteRule.ID>) {
        mutateRules(ids) { $0.enabled = enabled }
    }

    func setGroup(_ group: String, for ids: Set<RouteRule.ID>) {
        mutateRules(ids) { $0.group = group }
    }

    func setVia(_ via: RouteVia, for ids: Set<RouteRule.ID>) {
        mutateRules(ids) { $0.via = via }
    }

    func setGroupEnabled(_ group: String, enabled: Bool) {
        mutateConfig { config in
            for i in config.rules.indices where config.rules[i].group == group {
                config.rules[i].enabled = enabled
            }
        }
    }

    func renameGroup(_ group: String, to newName: String) {
        mutateConfig { config in
            for i in config.rules.indices where config.rules[i].group == group {
                config.rules[i].group = newName
            }
        }
    }

    func updateRule(_ rule: RouteRule) {
        mutateConfig { config in
            if let i = config.rules.firstIndex(where: { $0.id == rule.id }) {
                config.rules[i] = rule
            }
        }
    }

    func removeRules(_ ids: Set<RouteRule.ID>) {
        mutateConfig { $0.rules.removeAll { ids.contains($0.id) } }
    }

    /// 规则顺序决定出口冲突时的优先级
    func moveRules(_ ids: Set<RouteRule.ID>, toTop: Bool) {
        mutateConfig { config in
            let moved = config.rules.filter { ids.contains($0.id) }
            let others = config.rules.filter { !ids.contains($0.id) }
            config.rules = toTop ? moved + others : others + moved
        }
    }

    func setPaused(_ paused: Bool) {
        mutateConfig { $0.paused = paused }
    }

    private func mutateRules(_ ids: Set<RouteRule.ID>, _ body: @escaping (inout RouteRule) -> Void) {
        mutateConfig { config in
            for i in config.rules.indices where ids.contains(config.rules[i].id) {
                body(&config.rules[i])
            }
        }
    }

    /// 基于最新配置修改并提交。若其他窗口 / 实例已先修改（revision 冲突），拉取最新状态后重放本次修改。
    func mutateConfig(_ body: @escaping (inout HelperConfig) -> Void) {
        guard canModify, let base = state?.config else {
            alertMessage = status == .running ? "后台服务未就绪" : "请先安装或更新后台服务"
            return
        }
        var config = base
        body(&config)
        guard config != base else { return }
        state?.config = config
        configGeneration += 1
        submit(config, body: body, attemptsLeft: 3)
    }

    private func submit(_ config: HelperConfig, body: @escaping (inout HelperConfig) -> Void, attemptsLeft: Int) {
        guard let data = try? RouteJSON.encoder().encode(config) else { return }
        remote { [weak self] error in
            self?.alertMessage = "保存失败: \(error)"
            self?.configGeneration += 1
            self?.refresh()
        }?.updateConfig(data) { error, conflict in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if conflict, attemptsLeft > 0 {
                    self.retryAfterConflict(body: body, attemptsLeft: attemptsLeft - 1)
                    return
                }
                self.configGeneration += 1
                if conflict { self.alertMessage = "配置已被其他窗口修改，请重试" }
                if let error { self.alertMessage = error }
                self.refresh()
            }
        }
    }

    private func retryAfterConflict(body: @escaping (inout HelperConfig) -> Void, attemptsLeft: Int) {
        remote { [weak self] error in
            self?.alertMessage = error
        }?.fetchState { data, _ in
            let decoded = data.flatMap { try? RouteJSON.decoder().decode(HelperState.self, from: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, var latest = decoded?.config else { return }
                body(&latest)
                self.state?.config = latest
                self.configGeneration += 1
                self.submit(latest, body: body, attemptsLeft: attemptsLeft)
            }
        }
    }

    func reapply() {
        isBusy = true
        remote { [weak self] error in
            self?.isBusy = false
            self?.alertMessage = error
        }?.reapplyAll { error in
            DispatchQueue.main.async { [weak self] in
                self?.isBusy = false
                if let error { self?.alertMessage = error }
                self?.refresh()
            }
        }
    }

    func deleteSystemRoutes(_ addresses: [String], completion: @escaping @MainActor () -> Void = {}) {
        guard canModify else { return }
        isBusy = true
        remote { [weak self] error in
            self?.isBusy = false
            self?.alertMessage = error
        }?.deleteSystemRoutes(addresses) { error in
            DispatchQueue.main.async { [weak self] in
                self?.isBusy = false
                if let error { self?.alertMessage = "部分路由未删除：\n\(error)" }
                completion()
            }
        }
    }

    // MARK: - 安装 / 卸载

    func installHelper() {
        isBusy = true
        Task {
            do {
                try await HelperInstaller.install()
                resetConnection()
                try? await Task.sleep(nanoseconds: 800_000_000)
            } catch HelperInstaller.InstallError.cancelled {
            } catch {
                alertMessage = "安装失败: \(error.localizedDescription)"
            }
            isBusy = false
            refresh()
        }
    }

    func uninstallHelper() {
        isBusy = true
        let finish: @MainActor () -> Void = { [weak self] in
            Task { @MainActor in
                do {
                    try await HelperInstaller.uninstall()
                    self?.resetConnection()
                } catch HelperInstaller.InstallError.cancelled {
                    // 用户取消：恢复同步
                    self?.reapply()
                } catch {
                    self?.alertMessage = "卸载失败: \(error.localizedDescription)"
                }
                self?.isBusy = false
                self?.refresh()
            }
        }
        guard canModify, let proxy = remote({ _ in finish() }) else {
            finish()
            return
        }
        // 先让 Helper 清理自己添加的路由
        proxy.removeAllRoutes { _ in
            DispatchQueue.main.async { finish() }
        }
    }

    // MARK: - XPC

    private func resetConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func remote(_ onError: @escaping @MainActor (String) -> Void) -> RouteHelperProtocol? {
        let connection = self.connection ?? makeConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async { onError(error.localizedDescription) }
        }
        return proxy as? RouteHelperProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: RouteConstants.machServiceName, options: useDevAgent ? [] : .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: RouteHelperProtocol.self)
        let reset: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        c.invalidationHandler = reset
        c.interruptionHandler = reset
        c.resume()
        connection = c
        return c
    }
}

/// 跨视图导航（例如从规则或路由表跳转到诊断）
@MainActor
final class AppNavigation: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case rules = "路由规则"
        case routeTable = "系统路由表"
        case diagnostics = "诊断"
        case logs = "日志"
        case settings = "设置"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .rules: return "arrow.triangle.branch"
            case .routeTable: return "tablecells"
            case .diagnostics: return "stethoscope"
            case .logs: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var section: Section? = .rules
    @Published var diagnosticsTarget = ""
    /// 递增以触发诊断视图自动开始
    @Published var diagnosticsRequest = 0

    func diagnose(_ target: String) {
        diagnosticsTarget = target
        section = .diagnostics
        diagnosticsRequest += 1
    }
}

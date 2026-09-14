import Darwin
import Foundation
import RouteHelperCore
import Security
import RouteShared

final class HelperService: NSObject, RouteHelperProtocol {
    private let engine: RouteEngine

    init(engine: RouteEngine) {
        self.engine = engine
    }

    func fetchState(withReply reply: @escaping (Data?, String?) -> Void) {
        do {
            reply(try RouteJSON.encoder().encode(engine.currentState()), nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func updateConfig(_ configData: Data, withReply reply: @escaping (String?, Bool) -> Void) {
        guard let config = try? RouteJSON.decoder().decode(HelperConfig.self, from: configData) else {
            reply("配置格式无效", false)
            return
        }
        engine.updateConfig(config, completion: reply)
    }

    func reapplyAll(withReply reply: @escaping (String?) -> Void) {
        engine.reapplyAll(completion: reply)
    }

    func removeAllRoutes(withReply reply: @escaping (String?) -> Void) {
        engine.removeAllRoutes(completion: reply)
    }

    func deleteSystemRoutes(_ addresses: [String], withReply reply: @escaping (String?) -> Void) {
        engine.deleteSystemRoutes(addresses, completion: reply)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService
    private let requireSignedClient: Bool

    init(service: HelperService, requireSignedClient: Bool) {
        self.service = service
        self.requireSignedClient = requireSignedClient
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 只允许管理员账户（本来就能 sudo 修改路由）连接
        guard isAdministrator(uid: connection.effectiveUserIdentifier) else {
            FileHandle.standardError.write(Data("拒绝非管理员连接 uid=\(connection.effectiveUserIdentifier)\n".utf8))
            return false
        }
        if requireSignedClient {
            connection.setCodeSigningRequirement(Self.clientRequirement)
        }
        connection.exportedInterface = NSXPCInterface(with: RouteHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    /// 客户端必须是 MacOSRoute App；Helper 本身由开发者证书签名时，还要求客户端属于同一 Team，
    /// 防止任意程序通过 ad-hoc 签名伪造 Bundle ID 来控制 root 服务
    static let clientRequirement: String = {
        var requirement = "identifier \"\(RouteConstants.appBundleID)\""
        if let team = ownTeamIdentifier() {
            requirement += " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        return requirement
    }()

    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func isAdministrator(uid: uid_t) -> Bool {
        if uid == 0 { return true }
        guard let pw = getpwuid(uid), let admin = getgrnam("admin") else { return false }
        let adminGID = admin.pointee.gr_gid
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        if getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count) != -1,
           groups.prefix(Int(count)).contains(Int32(bitPattern: adminGID)) {
            return true
        }
        let name = String(cString: pw.pointee.pw_name)
        var member = admin.pointee.gr_mem
        while let m = member?.pointee {
            if String(cString: m) == name { return true }
            member = member?.advanced(by: 1)
        }
        return false
    }
}

let arguments = CommandLine.arguments

if arguments.contains("--print-client-requirement") {
    print(ListenerDelegate.clientRequirement)
    exit(0)
}

if arguments.contains("--print-gateway") {
    let preferred = arguments.firstIndex(of: "--interface").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? HelperConfig.automaticInterface
    let snapshot = GatewayDetector.snapshot(preferredInterface: preferred)
    for info in snapshot.interfaces {
        print("\(info.name)\t router=\(info.router ?? "-") address=\(info.localAddress ?? "-") dns=\(info.dnsServers.joined(separator: ",")) virtual=\(info.isVirtual)")
    }
    if let gw = snapshot.physical {
        print("physical: interface=\(gw.interface) router=\(gw.router)")
        exit(0)
    }
    print("未找到物理网关")
    exit(1)
}

if let index = arguments.firstIndex(of: "--resolve"), arguments.indices.contains(index + 1) {
    let physical = GatewayDetector.snapshot(preferredInterface: HelperConfig.automaticInterface).physicalInterface
    let servers = arguments.firstIndex(of: "--server").flatMap { arguments.indices.contains($0 + 1) ? [arguments[$0 + 1]] : nil } ?? []
    for mode in DNSMode.allCases where mode != .custom || !servers.isEmpty {
        let result = DNSResolver.resolve(arguments[index + 1], mode: mode, customServers: servers, physical: physical)
        switch result {
        case .success(let ips): print("\(mode.rawValue): \(ips.joined(separator: ", "))")
        case .failure(let error): print("\(mode.rawValue): \(error)")
        }
    }
    exit(0)
}

let isRoot = getuid() == 0
// 开发调试：非 root 运行时存到临时目录并跳过 route 命令
let storage = isRoot
    ? URL(fileURLWithPath: RouteConstants.supportDirectory)
    : FileManager.default.temporaryDirectory.appendingPathComponent("MacOSRouteHelperDev")

let engine = RouteEngine(storageDirectory: storage, system: LiveRouteSystem(dryRun: !isRoot))
engine.start()

let delegate = ListenerDelegate(service: HelperService(engine: engine), requireSignedClient: !arguments.contains("--allow-unsigned-clients"))
let listener = NSXPCListener(machServiceName: RouteConstants.machServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()

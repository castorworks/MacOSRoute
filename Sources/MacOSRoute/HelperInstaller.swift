import Foundation
import RouteShared

/// 通过 macOS 管理员授权对话框安装 / 卸载 root LaunchDaemon
enum HelperInstaller {
    enum InstallError: LocalizedError {
        case cancelled
        case missingResource(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "用户取消了授权"
            case .missingResource(let name): return "App 包中缺少 \(name)，请用 Xcode 的 MacOSRoute Scheme 构建"
            case .failed(let message): return message
            }
        }
    }

    static func install() async throws {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: RouteConstants.helperLabel) else {
            throw InstallError.missingResource(RouteConstants.helperLabel)
        }
        guard let plist = Bundle.main.url(forResource: RouteConstants.helperLabel, withExtension: "plist")
                ?? Bundle.main.url(forResource: RouteConstants.helperLabel, withExtension: "plist", subdirectory: "Resources") else {
            throw InstallError.missingResource("\(RouteConstants.helperLabel).plist")
        }
        let label = RouteConstants.helperLabel
        let script = """
        set -e
        \(legacyCleanupScript)
        /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
        /bin/mkdir -p /Library/PrivilegedHelperTools \(q(RouteConstants.supportDirectory)) \(q((RouteConstants.helperLogPath as NSString).deletingLastPathComponent))
        /bin/cp -f \(q(helper.path)) \(q(RouteConstants.helperInstallPath))
        /usr/sbin/chown root:wheel \(q(RouteConstants.helperInstallPath))
        /bin/chmod 755 \(q(RouteConstants.helperInstallPath))
        /bin/cp -f \(q(plist.path)) \(q(RouteConstants.launchDaemonPlistPath))
        /usr/sbin/chown root:wheel \(q(RouteConstants.launchDaemonPlistPath))
        /bin/chmod 644 \(q(RouteConstants.launchDaemonPlistPath))
        for i in 1 2 3 4 5; do
          /bin/launchctl bootstrap system \(q(RouteConstants.launchDaemonPlistPath)) 2>/dev/null && break
          sleep 1
        done
        /bin/launchctl print system/\(label) >/dev/null
        """
        try await runPrivileged(script)
    }

    /// 卸载 Helper，保留 /Library/Application Support/MacOSRoute 中的规则配置
    static func uninstall() async throws {
        let script = """
        \(legacyCleanupScript)
        /bin/launchctl bootout system/\(RouteConstants.helperLabel) >/dev/null 2>&1 || true
        /bin/rm -f \(q(RouteConstants.launchDaemonPlistPath)) \(q(RouteConstants.helperInstallPath))
        """
        try await runPrivileged(script)
    }

    /// 停止并删除旧标识的 Helper。规则配置目录与标识无关，新 Helper 会直接接管。
    private static var legacyCleanupScript: String {
        RouteConstants.legacyHelperLabels.map { label in
            """
            /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
            /bin/rm -f \(q("/Library/LaunchDaemons/\(label).plist")) \(q("/Library/PrivilegedHelperTools/\(label)"))
            """
        }.joined(separator: "\n")
    }

    /// 是否仍安装着旧标识的 Helper
    static var legacyHelperInstalled: Bool {
        RouteConstants.legacyHelperLabels.contains { FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\($0).plist") }
    }

    private static func runPrivileged(_ shellScript: String) async throws {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with prompt \"MacOSRoute 需要安装后台服务以管理系统路由。\" with administrator privileges"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            process.terminationHandler = { p in
                let message = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else if message.contains("-128") {
                    continuation.resume(throwing: InstallError.cancelled)
                } else {
                    continuation.resume(throwing: InstallError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// shell 单引号转义
    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

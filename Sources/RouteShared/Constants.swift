import Foundation

public enum RouteConstants {
    public static let appBundleID = "com.hyperits.app.MacOSRoute"
    public static let helperLabel = "com.hyperits.app.MacOSRoute.helper"
    public static let machServiceName = helperLabel
    /// 旧版本使用过的 Helper 标识，安装 / 卸载时一并清理
    public static let legacyHelperLabels = ["com.castorworks.macosroute.helper"]

    /// 修改 Helper 行为后递增，App 会提示用户更新已安装的 Helper。
    public static let helperVersion = "1.2.0"

    public static let helperInstallPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let supportDirectory = "/Library/Application Support/MacOSRoute"
    public static let helperLogPath = "/Library/Logs/MacOSRoute/helper.log"
}

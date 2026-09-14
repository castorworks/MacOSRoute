import Darwin
import Foundation
import SystemConfiguration

/// 监听 IPv4 网络状态变化（切换 Wi-Fi、插拔网线、睡眠唤醒、DHCP 续租等）
public final class NetworkChangeMonitor {
    private var store: SCDynamicStore?
    private let onChange: () -> Void

    public init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkChangeMonitor>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let store = SCDynamicStoreCreate(nil, "MacOSRouteMonitor" as CFString, callback, &context) else { return }
        let keys = ["State:/Network/Global/IPv4"] as CFArray
        let patterns = ["State:/Network/Service/[^/]+/IPv4", "State:/Network/Service/[^/]+/DNS", "State:/Network/Interface/[^/]+/Link"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }
}

/// 监听内核路由表变化（例如 VPN 客户端连接时清掉或覆盖了我们的路由）
public final class RoutingTableMonitor {
    private var source: DispatchSourceRead?

    public init?(queue: DispatchQueue, onChange: @escaping () -> Void) {
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var relevant = false
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                // rt_msghdr: u_short rtm_msglen; u_char rtm_version; u_char rtm_type
                guard n >= 4 else { continue }
                switch Int32(buffer[3]) {
                case RTM_ADD, RTM_DELETE, RTM_CHANGE: relevant = true
                default: break
                }
            }
            if relevant { onChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}

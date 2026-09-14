import Foundation

/// App 与 root Helper 之间的 XPC 协议。复杂数据以 JSON Data 传递，避免 NSSecureCoding 样板代码。
/// 修改协议时必须同步递增 RouteConstants.helperVersion。
@objc(RouteHelperProtocol)
public protocol RouteHelperProtocol {
    /// 返回 JSON 编码的 HelperState
    func fetchState(withReply reply: @escaping (Data?, String?) -> Void)
    /// 传入 JSON 编码的 HelperConfig。其 revision 必须等于 Helper 当前的 revision，
    /// 否则不保存并返回 conflict = true，调用方应基于最新状态重试。
    /// 保存后立即返回，路由同步在后台进行。
    func updateConfig(_ configData: Data, withReply reply: @escaping (_ error: String?, _ conflict: Bool) -> Void)
    /// 重新探测网关、重新解析域名并应用全部路由（同步完成后返回）
    func reapplyAll(withReply reply: @escaping (String?) -> Void)
    /// 删除 Helper 添加的全部路由并暂停同步（卸载前调用）
    func removeAllRoutes(withReply reply: @escaping (String?) -> Void)
    /// 删除系统中非 MacOSRoute 管理的静态路由（用于清理失效路由）
    func deleteSystemRoutes(_ addresses: [String], withReply reply: @escaping (String?) -> Void)
}

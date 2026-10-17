import Foundation

/// 解析自己广播的 Bonjour 服务，得到设备在局域网中的 `.local` 主机名。
/// iOS 17 起系统不再向 App 直接提供主机名，这是目前唯一可行的办法；解析失败时返回 nil。
final class BonjourHostResolver: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var completion: ((String?) -> Void)?

    /// 必须在主线程调用，回调也在主线程
    func resolve(serviceName: String, completion: @escaping (String?) -> Void) {
        cancel()
        self.completion = completion
        let service = NetService(domain: "local.", type: "_http._tcp.", name: serviceName)
        service.delegate = self
        self.service = service
        service.resolve(withTimeout: 8)
    }

    func cancel() {
        service?.stop()
        service?.delegate = nil
        service = nil
        completion = nil
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var host = sender.hostName ?? ""
        if host.hasSuffix(".") {
            host.removeLast()
        }
        let valid = !host.isEmpty && !host.lowercased().hasPrefix("localhost")
        finish(valid ? host : nil)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(nil)
    }

    private func finish(_ host: String?) {
        let completion = self.completion
        cancel()
        completion?(host)
    }
}

import Foundation
import Network

struct RequestLog: Identifiable {
    let id = UUID()
    let date: Date
    let method: String
    let path: String
    let status: Int
    let client: String
}

/// 基于 Network.framework 的静态文件 HTTP 服务器
final class HTTPServer {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    /// 以下回调都在服务器内部队列上触发
    var onStateChange: (@Sendable (State) -> Void)?
    var onRequest: (@Sendable (RequestLog) -> Void)?
    var onFilesChanged: (@Sendable () -> Void)?
    /// Bonjour 服务注册成功时回调实际使用的服务名（重名时系统会自动改名），取消注册时为 nil
    var onServiceRegistered: (@Sendable (String?) -> Void)?

    private let queue = DispatchQueue(label: "LocalServer.http")
    private let router: Router
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    init(rootURL: URL, config: Router.Config) {
        router = Router(rootURL: rootURL, config: config)
        router.onFilesChanged = { [weak self] in
            self?.onFilesChanged?()
        }
    }

    func updateConfig(_ config: Router.Config) {
        queue.async {
            self.router.config = config
        }
    }

    func start(port: UInt16, localOnly: Bool, bonjourName: String? = nil) {
        queue.async {
            self.startOnQueue(port: port, localOnly: localOnly, bonjourName: bonjourName)
        }
    }

    func stop() {
        queue.async {
            self.stopOnQueue()
            self.emit(.stopped)
        }
    }

    // MARK: - 私有

    private func startOnQueue(port: UInt16, localOnly: Bool, bonjourName: String?) {
        stopOnQueue()
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            emit(.failed("无效的端口号"))
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            if localOnly {
                // 只绑定回环地址，局域网中的其他设备无法访问
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: nwPort)
            }
        } catch {
            emit(.failed(Self.message(for: error, port: port)))
            return
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                self.emit(.running(port: listener.port?.rawValue ?? port))
            case .waiting(let error):
                self.emit(.failed(Self.message(for: error, port: port)))
            case .failed(let error):
                self.stopOnQueue()
                self.emit(.failed(Self.message(for: error, port: port)))
            default:
                break
            }
        }
        if let bonjourName, !localOnly {
            listener.service = NWListener.Service(name: bonjourName, type: "_http._tcp")
            listener.serviceRegistrationUpdateHandler = { [weak self, weak listener] change in
                // 忽略已被替换的旧 listener 迟到的回调
                guard let self, let listener, listener === self.listener else { return }
                switch change {
                case .add(let endpoint):
                    if case let .service(name, _, _, _) = endpoint {
                        self.onServiceRegistered?(name)
                    }
                case .remove:
                    self.onServiceRegistered?(nil)
                @unknown default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        emit(.starting)
        listener.start(queue: queue)
    }

    private func stopOnQueue() {
        let current = listener
        listener = nil
        current?.cancel()
        if current?.service != nil {
            onServiceRegistered?(nil)
        }
        for connection in Array(connections.values) {
            connection.close()
        }
        connections.removeAll()
    }

    private func accept(_ nwConnection: NWConnection) {
        let router = self.router
        let connection = HTTPConnection(
            connection: nwConnection,
            queue: queue,
            handler: { request in router.handle(request) },
            onResponse: { [weak self] request, response in
                // Live Reload 每秒轮询一次，不记录到日志里
                guard !LiveReload.handles(request.path) else { return }
                self?.onRequest?(RequestLog(
                    date: Date(),
                    method: request.method,
                    path: request.path + (request.rawQuery.isEmpty ? "" : "?" + request.rawQuery),
                    status: response.status,
                    client: request.remoteAddress
                ))
            },
            onClose: { [weak self] connection in
                self?.connections[ObjectIdentifier(connection)] = nil
            }
        )
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    private func emit(_ state: State) {
        onStateChange?(state)
    }

    private static func message(for error: Error, port: UInt16) -> String {
        if let error = error as? NWError, case .posix(let code) = error {
            switch code {
            case .EADDRINUSE:
                return "端口 \(port) 已被占用，请换一个端口"
            case .EACCES:
                return "没有权限使用端口 \(port)，请使用 1024 以上的端口"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

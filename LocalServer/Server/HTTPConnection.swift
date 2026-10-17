import Foundation
import Network

/// 单个 TCP 连接上的 HTTP/1.1 会话：解析请求、支持 keep-alive，文件按块流式发送。
/// 所有方法都只在服务器的串行队列上调用。
final class HTTPConnection {
    /// 处理请求并通过回调返回响应；回调可以在任意线程、稍后调用（例如 Live Reload 长轮询）
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maxHeaderSize = 64 * 1024
    /// 超过该大小的请求体写入临时文件，避免占用大量内存
    private static let memoryBodyLimit: Int64 = 1024 * 1024
    private static let maxBodySize: Int64 = 8 * 1024 * 1024 * 1024
    private static let chunkSize = 256 * 1024
    private static let idleTimeout: TimeInterval = 30

    let remoteAddress: String

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: Handler
    private let onResponse: (HTTPRequest, HTTPResponse) -> Void
    private let onClose: (HTTPConnection) -> Void

    private var buffer = Data()
    private var pendingHead: HTTPRequestHead?
    private var bodyRemaining: Int64 = 0
    private var bodyData = Data()
    private var bodyFile: FileHandle?
    private var bodyFileURL: URL?
    private var peerClosed = false
    private var closed = false
    private var idleTimer: DispatchWorkItem?

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        handler: @escaping Handler,
        onResponse: @escaping (HTTPRequest, HTTPResponse) -> Void,
        onClose: @escaping (HTTPConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onResponse = onResponse
        self.onClose = onClose
        self.remoteAddress = Self.address(of: connection.endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        readMore()
    }

    func close() {
        guard !closed else { return }
        closed = true
        idleTimer?.cancel()
        discardBodyFile()
        connection.cancel()
        onClose(self)
    }

    // MARK: - 读取

    private func readMore() {
        guard !closed else { return }
        if pendingHead == nil && buffer.isEmpty {
            scheduleIdleTimeout()
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            self.idleTimer?.cancel()
            if let data, !data.isEmpty {
                self.receive(data)
            }
            if isComplete {
                self.peerClosed = true
            }
            if error != nil {
                self.close()
                return
            }
            self.process()
        }
    }

    private func receive(_ data: Data) {
        // 正在接收请求体且缓冲区为空时直接写入，避免大文件上传时反复拷贝缓冲区
        guard pendingHead != nil, bodyRemaining > 0, buffer.isEmpty else {
            buffer.append(data)
            return
        }
        let count = Int(min(bodyRemaining, Int64(data.count)))
        if count == data.count {
            if writeBody(data) {
                bodyRemaining -= Int64(count)
            }
        } else {
            if writeBody(data.prefix(count)) {
                bodyRemaining -= Int64(count)
            }
            buffer = Data(data.dropFirst(count))
        }
    }

    /// 写入请求体，失败时返回错误响应并关闭连接
    private func writeBody(_ chunk: Data) -> Bool {
        if let file = bodyFile {
            do {
                try file.write(contentsOf: chunk)
            } catch {
                respondAndClose(.error(507, "写入失败：\(error.localizedDescription)"))
                return false
            }
        } else {
            bodyData.append(chunk)
        }
        return true
    }

    private func needMore() {
        if peerClosed {
            close()
        } else {
            readMore()
        }
    }

    private func process() {
        guard !closed else { return }

        if pendingHead == nil {
            guard let range = buffer.range(of: Self.headerTerminator) else {
                if buffer.count > Self.maxHeaderSize {
                    respondAndClose(.error(431))
                } else if buffer.isEmpty && peerClosed {
                    close()
                } else {
                    needMore()
                }
                return
            }
            let headData = Data(buffer[buffer.startIndex..<range.lowerBound])
            consume(upTo: range.upperBound)

            guard let head = HTTPRequestHead(data: headData) else {
                respondAndClose(.error(400))
                return
            }
            if let encoding = head.header("transfer-encoding"), encoding.lowercased() != "identity" {
                respondAndClose(.error(411, "不支持分块传输的请求体，请提供 Content-Length"))
                return
            }
            guard let length = Int64(head.header("content-length") ?? "0"), length >= 0 else {
                respondAndClose(.error(400, "Content-Length 无效"))
                return
            }
            guard length <= Self.maxBodySize else {
                respondAndClose(.error(413))
                return
            }

            pendingHead = head
            bodyRemaining = length
            bodyData = Data()
            if length > Self.memoryBodyLimit {
                guard openBodyFile() else {
                    respondAndClose(.error(500, "无法创建临时文件"))
                    return
                }
            }
            if length > 0, head.header("expect")?.lowercased() == "100-continue" {
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
        }

        if bodyRemaining > 0 && !buffer.isEmpty {
            let count = Int(min(bodyRemaining, Int64(buffer.count)))
            guard writeBody(buffer.prefix(count)) else { return }
            consume(count: count)
            bodyRemaining -= Int64(count)
        }

        if bodyRemaining > 0 {
            needMore()
            return
        }

        dispatchRequest()
    }

    private func dispatchRequest() {
        guard let head = pendingHead else { return }
        pendingHead = nil

        let body: HTTPBody
        if let file = bodyFile, let url = bodyFileURL {
            try? file.close()
            body = .file(url)
        } else if !bodyData.isEmpty {
            body = .data(bodyData)
        } else {
            body = .none
        }
        bodyFile = nil
        bodyFileURL = nil
        bodyData = Data()

        let request = HTTPRequest(head: head, body: body, remoteAddress: remoteAddress)
        // 处理器在服务器的并发队列上运行；在等待响应期间不再读取新数据
        handler(request) { [weak self] response in
            if case .file(let url) = body {
                // 处理器可能已经把临时文件移走了，这里失败无妨
                try? FileManager.default.removeItem(at: url)
            }
            guard let self else {
                if let url = response.cleanupURL { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.queue.async {
                guard !self.closed else {
                    if let url = response.cleanupURL { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.onResponse(request, response)
                let keepAlive = head.wantsKeepAlive && !self.peerClosed
                self.send(response, isHead: head.method == "HEAD", keepAlive: keepAlive)
            }
        }
    }

    // MARK: - 发送

    private func respondAndClose(_ response: HTTPResponse) {
        pendingHead = nil
        discardBodyFile()
        send(response, isHead: false, keepAlive: false)
    }

    private func send(_ response: HTTPResponse, isHead: Bool, keepAlive: Bool) {
        var response = response
        var fileHandle: FileHandle?

        if case .file(let url, let offset, let length) = response.body, !isHead, length > 0, response.allowsBody {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.seek(toOffset: offset)
                fileHandle = handle
            } catch {
                response = .error(500, "无法读取文件")
            }
        }

        response.setHeader("Connection", keepAlive ? "keep-alive" : "close")
        if response.allowsBody {
            response.setHeader("Content-Length", String(response.contentLength))
        }

        let head = response.serializedHead()
        let cleanupURL = response.cleanupURL
        let finish: (Bool) -> Void = { [weak self] success in
            if let cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
            self?.finishResponse(success: success, keepAlive: keepAlive)
        }

        if isHead || !response.allowsBody {
            sendData(head, completion: finish)
            return
        }

        switch response.body {
        case .empty:
            sendData(head, completion: finish)
        case .data(let data):
            sendData(head + data, completion: finish)
        case .file(_, _, let length):
            guard let handle = fileHandle else {
                sendData(head, completion: finish)
                return
            }
            sendData(head) { [weak self] success in
                guard let self, success else {
                    try? handle.close()
                    finish(false)
                    return
                }
                self.streamFile(handle, remaining: length, completion: finish)
            }
        }
    }

    private func sendData(_ data: Data, completion: @escaping (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    private func streamFile(_ handle: FileHandle, remaining: UInt64, completion: @escaping (Bool) -> Void) {
        guard !closed else {
            try? handle.close()
            completion(false)
            return
        }
        if remaining == 0 {
            try? handle.close()
            completion(true)
            return
        }
        let count = Int(min(UInt64(Self.chunkSize), remaining))
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: count) ?? Data()
        } catch {
            try? handle.close()
            completion(false)
            return
        }
        guard !chunk.isEmpty else {
            // 文件在发送过程中被截断，只能断开连接
            try? handle.close()
            completion(false)
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                completion(false)
                return
            }
            self.streamFile(handle, remaining: remaining - UInt64(chunk.count), completion: completion)
        })
    }

    private func finishResponse(success: Bool, keepAlive: Bool) {
        guard success, keepAlive, !closed else {
            close()
            return
        }
        // 继续处理同一连接上的下一个请求（可能已在缓冲区中）
        process()
    }

    // MARK: - 工具

    private func consume(upTo index: Data.Index) {
        buffer = index >= buffer.endIndex ? Data() : Data(buffer[index...])
    }

    private func consume(count: Int) {
        buffer = count >= buffer.count ? Data() : Data(buffer.dropFirst(count))
    }

    private func openBodyFile() -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            return false
        }
        bodyFile = handle
        bodyFileURL = url
        return true
    }

    private func discardBodyFile() {
        if let file = bodyFile {
            try? file.close()
        }
        if let url = bodyFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        bodyFile = nil
        bodyFileURL = nil
    }

    private func scheduleIdleTimeout() {
        idleTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.close()
        }
        idleTimer = item
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: item)
    }

    /// 连接对方的 IP 地址（去掉 IPv6 区域标识和 IPv4 映射前缀）
    static func address(of endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else {
            return "\(endpoint)"
        }
        var address = "\(host)"
        if let percent = address.firstIndex(of: "%") {
            address = String(address[..<percent])
        }
        if address.hasPrefix("::ffff:") {
            address = String(address.dropFirst("::ffff:".count))
        }
        return address
    }
}

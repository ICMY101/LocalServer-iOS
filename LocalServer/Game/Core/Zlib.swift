import Foundation
import Compression

/// zlib 流解压。
///
/// Ren'Py 的归档（.rpa）里，索引和每个文件的内容都是 zlib 流（RFC 1950：
/// 2 字节头 + deflate 数据 + 4 字节 ADLER32 校验）。系统的 libcompression 只提供
/// 裸 deflate（COMPRESSION_ZLIB），所以这里需要先剥掉头尾再用它解压。
enum Zlib {
    /// 解压一个 zlib 流；输入不是合法的 zlib 流时返回 nil
    static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        if let payload = zlibPayload(in: data), let result = rawInflate(payload) {
            return result
        }
        // 有些工具写出的流没有 ADLER32 尾部，退化为按整段解压
        if hasZlibHeader(data), let result = rawInflate(data.dropFirst(2)) {
            return result
        }
        // 兜底：当作裸 deflate
        return rawInflate(data)
    }

    /// 归档成员可能压缩也可能没压缩：是 zlib 流就解压，否则原样返回
    static func inflateIfNeeded(_ data: Data) -> Data {
        guard hasZlibHeader(data), let inflated = inflate(data) else { return data }
        return inflated
    }

    /// 是否看起来是 zlib 流（CMF 低 4 位为 8，且头两字节能被 31 整除）
    private static func hasZlibHeader(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let cmf = data[data.startIndex]
        let flg = data[data.startIndex + 1]
        return (cmf & 0x0f) == 8 && (Int(cmf) << 8 | Int(flg)) % 31 == 0
    }

    /// 剥掉 2 字节头和 4 字节 ADLER32 尾
    private static func zlibPayload(in data: Data) -> Data? {
        guard hasZlibHeader(data), data.count > 6 else { return nil }
        return data.subdata(in: (data.startIndex + 2)..<(data.startIndex + data.count - 4))
    }

    /// 裸 deflate 解压；输出长度未知，按块边解边收
    private static func rawInflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var stream = compression_stream()
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            return nil
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 256 * 1024
        var output = [UInt8](repeating: 0, count: chunkSize)
        var result = Data()
        result.reserveCapacity(data.count * 4)

        let status = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> compression_status in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else {
                return COMPRESSION_STATUS_ERROR
            }
            stream.src_ptr = base
            stream.src_size = source.count

            while true {
                var written = 0
                let stepStatus = output.withUnsafeMutableBytes { raw -> compression_status in
                    stream.dst_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = chunkSize
                    // 每次都给 FINALIZE，让解码器在数据结束时完成收尾
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    written = chunkSize - stream.dst_size
                    return status
                }
                if written > 0 {
                    result.append(contentsOf: output[0..<written])
                }
                switch stepStatus {
                case COMPRESSION_STATUS_END:
                    return COMPRESSION_STATUS_OK
                case COMPRESSION_STATUS_ERROR:
                    return COMPRESSION_STATUS_ERROR
                default:
                    // 输出缓冲被填满则继续；输入耗尽但没收到 END 说明数据不完整
                    if stream.dst_size != 0 { return COMPRESSION_STATUS_OK }
                    if stream.src_size == 0 { return COMPRESSION_STATUS_ERROR }
                }
            }
        }
        return status == COMPRESSION_STATUS_OK ? result : nil
    }
}

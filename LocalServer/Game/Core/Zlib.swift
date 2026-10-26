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

        let chunkSize = 256 * 1024
        var output = [UInt8](repeating: 0, count: chunkSize)

        return data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Data? in
            guard let input = source.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Data? in
                guard let outputBase = destination.bindMemory(to: UInt8.self).baseAddress else { return nil }
                var stream = compression_stream(dst_ptr: outputBase, dst_size: chunkSize,
                                               src_ptr: input, src_size: source.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                        != COMPRESSION_STATUS_ERROR else { return nil }
                defer { compression_stream_destroy(&stream) }

                var result = Data()
                result.reserveCapacity(data.count * 4)

                while true {
                    stream.dst_size = chunkSize
                    // 每次都给 FINALIZE，让解码器在数据结束时完成收尾
                    let stepStatus = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let filled = chunkSize - stream.dst_size
                    if filled > 0 {
                        result.append(contentsOf: UnsafeBufferPointer(start: outputBase, count: filled))
                    }
                    if stepStatus == COMPRESSION_STATUS_END { return result }
                    if stepStatus == COMPRESSION_STATUS_ERROR { return nil }
                    // 输出没写满却没收到 END、或输入已耗尽都没走完，说明数据不完整
                    if stream.dst_size != 0 || stream.src_size == 0 { return nil }
                }
            }
        }
    }
}

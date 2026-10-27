import Foundation

/// zlib 流解压。
///
/// Ren'Py 的归档（.rpa）和编译脚本（.rpyc）里，索引和每段内容都是 zlib 流
/// （RFC 1950：2 字节头 + deflate 数据 + 4 字节 ADLER32）。这里自己实现 RFC 1951
/// 的解码，不依赖 Compression.framework 的流式接口在模拟器上的行为差异。
enum Zlib {
    /// 解压一个 zlib 流；输入不是合法的 zlib 流时返回 nil
    static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        // 标准 zlib：剥掉 2 字节头和 4 字节 ADLER32
        if hasZlibHeader(data), data.count > 6 {
            let body = data.subdata(in: (data.startIndex + 2)..<(data.startIndex + data.count - 4))
            if let result = Inflate.decode(body) { return result }
        }
        // 有些工具写出的流没有 ADLER32 尾部
        if hasZlibHeader(data), let result = Inflate.decode(Data(data.dropFirst(2))) {
            return result
        }
        // 兜底：当作裸 deflate
        return Inflate.decode(data)
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
}

/// 裸 deflate（RFC 1951）解码器
private enum Inflate {
    /// 单次解压的输出上限，防御压缩炸弹
    static let maxOutput = 256 * 1024 * 1024

    static func decode(_ data: Data) -> Data? {
        var bits = BitReader(Array(data))
        var output: [UInt8] = []
        output.reserveCapacity(data.count * 3)

        while true {
            guard let final = bits.read(1), let type = bits.read(2) else { return nil }
            switch type {
            case 0:
                guard bits.align(), appendStored(&bits, to: &output) else { return nil }
            case 1:
                guard appendCompressed(&bits, to: &output, literal: fixedLiteral, distance: fixedDistance) else {
                    return nil
                }
            case 2:
                guard let tables = dynamicTables(&bits),
                      appendCompressed(&bits, to: &output, literal: tables.literal, distance: tables.distance) else {
                    return nil
                }
            default:
                return nil
            }
            if final == 1 { return Data(output) }
        }
    }

    // MARK: - 块

    private static func appendStored(_ bits: inout BitReader, to output: inout [UInt8]) -> Bool {
        guard let low = bits.byte(), let high = bits.byte() else { return false }
        let length = low | high << 8
        guard let lowInverse = bits.byte(), let highInverse = bits.byte() else { return false }
        let inverse = lowInverse | highInverse << 8
        guard length == (~inverse & 0xffff) else { return false }
        guard output.count + length <= maxOutput else { return false }
        for _ in 0..<length {
            guard let byte = bits.byte() else { return false }
            output.append(byte)
        }
        return true
    }

    private static func appendCompressed(_ bits: inout BitReader, to output: inout [UInt8],
                                         literal: Huffman, distance: Huffman) -> Bool {
        while true {
            guard let symbol = decode(bits: &bits, using: literal) else { return false }
            if symbol < 256 {
                output.append(UInt8(symbol))
                guard output.count <= maxOutput else { return false }
                continue
            }
            if symbol == 256 { return true }
            guard symbol >= 257, symbol <= 285 else { return false }

            let lengthIndex = symbol - 257
            guard let lengthExtra = bits.read(lengthExtraBits[lengthIndex]) else { return false }
            let length = lengthBase[lengthIndex] + lengthExtra

            guard let distanceSymbol = decode(bits: &bits, using: distance), distanceSymbol < 30,
                  let distanceExtra = bits.read(distanceExtraBits[distanceSymbol]) else { return false }
            let offset = distanceBase[distanceSymbol] + distanceExtra
            guard offset > 0, offset <= output.count, output.count + length <= maxOutput else { return false }

            var index = output.count - offset
            for _ in 0..<length {
                output.append(output[index])
                index += 1
            }
        }
    }

    // MARK: - Huffman

    private struct Huffman {
        /// counts[长度] = 该长度的码数量
        var counts: [Int]
        /// 按 (长度, 符号) 排序后的符号表
        var symbols: [Int]
    }

    private static func table(_ lengths: [Int]) -> Huffman? {
        var counts = [Int](repeating: 0, count: 16)
        for length in lengths where length > 0 {
            guard length <= 15 else { return nil }
            counts[length] += 1
        }
        // 检查码是否超订；允许不完整（单个距离码的情况）
        var left = 1
        for length in 1...15 {
            left <<= 1
            left -= counts[length]
            if left < 0 { return nil }
        }

        var offsets = [Int](repeating: 0, count: 16)
        for length in 1..<15 { offsets[length + 1] = offsets[length] + counts[length] }
        var symbols = [Int](repeating: 0, count: counts.reduce(0, +))
        for (symbol, length) in lengths.enumerated() where length > 0 {
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }
        return Huffman(counts: counts, symbols: symbols)
    }

    /// 逐位比较 canonical 码
    private static func decode(bits: inout BitReader, using table: Huffman) -> Int? {
        var code = 0
        var first = 0
        var index = 0
        for length in 1...15 {
            guard let bit = bits.read(1) else { return nil }
            code |= bit
            let count = table.counts[length]
            if code - first < count {
                let position = index + code - first
                guard position < table.symbols.count else { return nil }
                return table.symbols[position]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        return nil
    }

    private static let fixedLiteral: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        return table(lengths)!
    }()

    private static let fixedDistance: Huffman = {
        table([Int](repeating: 5, count: 32))!
    }()

    private static func dynamicTables(_ bits: inout BitReader) -> (literal: Huffman, distance: Huffman)? {
        guard let hlit = bits.read(5), let hdist = bits.read(5), let hclen = bits.read(4) else { return nil }
        let literalCount = hlit + 257
        let distanceCount = hdist + 1
        let codeCount = hclen + 4

        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeCount {
            guard let length = bits.read(3) else { return nil }
            codeLengths[order[index]] = length
        }
        guard let lengthTable = table(codeLengths) else { return nil }

        var lengths: [Int] = []
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            guard let symbol = decode(bits: &bits, using: lengthTable) else { return nil }
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last, let extra = bits.read(2) else { return nil }
                lengths.append(contentsOf: repeatElement(previous, count: 3 + extra))
            case 17:
                guard let extra = bits.read(3) else { return nil }
                lengths.append(contentsOf: repeatElement(0, count: 3 + extra))
            case 18:
                guard let extra = bits.read(7) else { return nil }
                lengths.append(contentsOf: repeatElement(0, count: 11 + extra))
            default:
                return nil
            }
        }
        guard lengths.count >= literalCount + distanceCount else { return nil }
        if lengths.count > literalCount + distanceCount {
            lengths.removeLast(lengths.count - literalCount - distanceCount)
        }

        guard let literal = table(Array(lengths[0..<literalCount])) else { return nil }
        var distanceLengths = Array(lengths[literalCount...])
        // 没有距离码时补一个占位，保证后面解码不会越界
        if distanceLengths.allSatisfy({ $0 == 0 }) { distanceLengths = [1, 1] }
        guard let distance = table(distanceLengths) else { return nil }
        return (literal, distance)
    }

    // MARK: - 常量表

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                     35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtraBits = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                          3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                       257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                       8193, 12289, 16385, 24577]
    private static let distanceExtraBits = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                            7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
}

/// 低位在前的位流读取器
private struct BitReader {
    private let bytes: [UInt8]
    private var index = 0
    private var bit = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// 读 count 位（最多 16 位），低位先出
    mutating func read(_ count: Int) -> Int? {
        guard count >= 0, count <= 16 else { return nil }
        var value = 0
        for position in 0..<count {
            guard index < bytes.count else { return nil }
            let current = (Int(bytes[index]) >> bit) & 1
            value |= current << position
            bit += 1
            if bit == 8 {
                bit = 0
                index += 1
            }
        }
        return value
    }

    /// 丢弃当前字节里剩下的位
    mutating func align() -> Bool {
        if bit != 0 {
            bit = 0
            index += 1
        }
        return index <= bytes.count
    }

    /// 读整字节（只在字节边界上使用，stored 块和长度之前已经 align）
    mutating func byte() -> Int? {
        guard bit == 0, index < bytes.count else { return nil }
        let value = Int(bytes[index])
        index += 1
        return value
    }
}

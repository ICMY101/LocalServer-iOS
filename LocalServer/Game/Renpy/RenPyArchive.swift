import Foundation

/// Ren'Py 归档（.rpa）的读取。
///
/// 对照 renpy/loader.py 的 archive_handlers，支持三种索引：
/// - `RPA-3.0 `：头 40 字节为 `RPA-3.0 <16 位十六进制索引偏移> <8 位十六进制混淆密钥>`，
///   索引 zlib 压缩后以 pickle 存放，每个 (偏移, 长度) 都要与密钥异或还原；
/// - `RPA-2.0 `：头 24 字节，索引同样 zlib + pickle，但不混淆；
/// - 旧版：文件以「索引长度 + 空格」开头，索引是 Python 字面量 repr。
///
/// 成员是否压缩取决于打包时的 Ren'Py 版本（新版原样存放，旧版是 zlib 流），
/// 所以读取时按内容嗅探，不假设。
final class RenPyArchive {
    struct Placement {
        enum Part {
            /// 直接存在索引里的字面量片段
            case literal(Data)
            /// 归档文件中的一个区间
            case region(offset: Int, length: Int)
        }

        var parts: [Part]
    }

    let url: URL
    private var placements: [String: Placement] = [:]
    private var handle: FileHandle?
    private let lock = NSLock()

    static func open(url: URL) -> RenPyArchive? {
        let archive = RenPyArchive(url: url)
        guard archive.loadIndex() else { return nil }
        return archive
    }

    private init(url: URL) {
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    // MARK: - 查询

    /// 路径按大小写不敏感匹配，与 Ren'Py 的 `lower_map` 一致
    static func key(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    func contains(_ name: String) -> Bool {
        placements[Self.key(name)] != nil
    }

    var memberCount: Int { placements.count }

    func memberNames() -> [String] {
        placements.keys.sorted()
    }

    /// 读取成员；不存在或区间越界时返回 nil
    func data(for name: String) -> Data? {
        guard let placement = placements[Self.key(name)] else { return nil }
        if placement.parts.count == 1, case .region(let offset, let length) = placement.parts[0] {
            return read(offset: offset, length: length)
        }
        var result = Data()
        for part in placement.parts {
            switch part {
            case .literal(let bytes):
                result.append(bytes)
            case .region(let offset, let length):
                guard let chunk = read(offset: offset, length: length) else { return nil }
                result.append(chunk)
            }
        }
        return result
    }

    func string(for name: String) -> String? {
        guard let data = data(for: name) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func read(offset: Int, length: Int) -> Data? {
        guard length >= 0, offset >= 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            handle = try? FileHandle(forReadingFrom: url)
        }
        guard let handle else { return nil }
        handle.seek(toFileOffset: UInt64(offset))
        let raw = handle.readData(ofLength: length)
        guard raw.count == length else { return nil }
        return Zlib.inflateIfNeeded(raw)
    }

    // MARK: - 索引

    private func loadIndex() -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 8 else { return false }
        guard let reader = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? reader.close() }

        guard let head = readHead(reader, count: min(40, size)) else { return false }
        let ascii = String(decoding: head, as: UTF8.self)

        if ascii.hasPrefix("RPA-3.0 ") {
            reader.seek(toFileOffset: 0)
            guard let index = readZlibPickledIndex(reader: reader, header: head, offsetRange: 8 ..< 24) else {
                return false
            }
            let xorKey = Self.hexValue(ascii, in: 25 ..< 33) ?? 0
            return applyDictionary(index, fileEnd: size, xorKey: xorKey)
        }

        if ascii.hasPrefix("RPA-2.0 ") {
            reader.seek(toFileOffset: 0)
            guard let index = readZlibPickledIndex(reader: reader, header: head, offsetRange: 8 ..< 24) else {
                return false
            }
            return applyDictionary(index, fileEnd: size, xorKey: nil)
        }

        if let first = ascii.utf8.first, first >= 0x30, first <= 0x39 {
            return applyLegacyIndex(reader: reader, ascii: ascii, size: size)
        }
        return false
    }

    private func readHead(_ reader: FileHandle, count: Int) -> Data? {
        try? reader.read(upToCount: count)
    }

    /// 头部给出索引偏移，索引是 zlib 压缩后的 pickle
    private func readZlibPickledIndex(reader: FileHandle, header: Data, offsetRange: Range<Int>) -> PyValue? {
        let ascii = String(decoding: header, as: UTF8.self)
        guard let indexOffset = Self.hexValue(ascii, in: offsetRange), indexOffset > 0 else { return nil }

        reader.seek(toFileOffset: UInt64(indexOffset))
        guard let blob = try? reader.readToEnd(), !blob.isEmpty, let plain = Zlib.inflate(blob) else { return nil }
        guard let index = PickleReader.load(plain)
                ?? PythonLiteral.parsePrefix(String(decoding: plain, as: UTF8.self)) else { return nil }
        if let array = index.arrayValue {
            // 少数工具把索引写成列表，转成字典统一处理
            return convertLegacyList(array)
        }
        return index
    }

    /// 旧版索引：`<索引长度> <repr 文本>`，之后的数据区偏移按版本解释
    private func applyLegacyIndex(reader: FileHandle, ascii: String, size: Int) -> Bool {
        guard let space = ascii.firstIndex(of: " ") else { return false }
        let lengthText = String(ascii[ascii.startIndex ..< space])
        guard let indexLength = Int(lengthText.trimmingCharacters(in: .whitespaces)), indexLength > 0 else { return false }
        let indexStart = lengthText.count + 1
        guard indexStart + indexLength <= size else { return false }

        reader.seek(toFileOffset: UInt64(indexStart))
        guard let blob = try? reader.read(upToCount: indexLength), blob.count == indexLength else { return false }
        let text = String(decoding: blob, as: UTF8.self)
        guard let index = PythonLiteral.parse(text) ?? PickleReader.load(blob),
              let entries = index.arrayValue, !entries.isEmpty else { return false }

        // 首元素是头部 (版本, ...)
        let version = entries[0].arrayValue?.first?.intValue ?? 1
        let dataStart = indexStart + indexLength + 1
        return applyListEntries(
            Array(entries.dropFirst()),
            baseOffset: version == 1 ? 0 : dataStart,
            xorKey: nil
        )
    }

    /// RPA-2.0/3.0 的索引：`{名字: [(偏移, 长度), ...]}`
    private func applyDictionary(_ index: PyValue, fileEnd: Int, xorKey: Int?) -> Bool {
        guard case .dictionary(let pairs)? = index, !pairs.isEmpty else { return false }
        var count = 0
        for (rawName, rawEntries) in pairs {
            guard let name = Self.name(from: rawName), let entries = rawEntries.arrayValue else { continue }
            guard let placement = placement(from: entries, xorKey: xorKey, fileEnd: fileEnd) else { continue }
            placements[Self.key(name)] = placement
            count += 1
        }
        return count > 0
    }

    /// 旧版索引：`[(名字, 偏移, 长度), ...]`
    private func convertLegacyList(_ entries: [PyValue]) -> PyValue? {
        guard entries.count > 1 else { return nil }
        var pairs: [(PyValue, PyValue)] = []
        for entry in entries.dropFirst() {
            guard let parts = entry.arrayValue, parts.count >= 3, let name = Self.name(from: parts[0]) else { continue }
            pairs.append((.string(name), .array(Array(parts.dropFirst()))))
        }
        return pairs.isEmpty ? nil : .dictionary(pairs)
    }

    private func applyListEntries(_ entries: [PyValue], baseOffset: Int, xorKey: Int?) -> Bool {
        var count = 0
        for entry in entries {
            guard let parts = entry.arrayValue, parts.count >= 3, let name = Self.name(from: parts[0]) else { continue }
            guard let placement = placement(from: Array(parts.dropFirst()), baseOffset: baseOffset, xorKey: xorKey) else {
                continue
            }
            placements[Self.key(name)] = placement
            count += 1
        }
        return count > 0
    }

    /// 每个条目可能是 (偏移, 长度)、(字面量,) 或 (偏移, 长度, 字面量)
    private func placement(from entries: [PyValue], baseOffset: Int = 0, xorKey: Int? = nil, fileEnd: Int? = nil) -> Placement? {
        var parts: [Placement.Part] = []
        for entry in entries {
            guard let values = entry.arrayValue else { return nil }
            switch values.count {
            case 1:
                guard case .bytes(let data) = values[0] else { return nil }
                parts.append(.literal(data))
            case 2, 3:
                guard var offset = values[0].intValue, var length = values[1].intValue else { return nil }
                if let key = xorKey {
                    offset ^= key
                    length ^= key
                }
                offset += baseOffset
                guard offset >= 0, length >= 0 else { return nil }
                if let end = fileEnd, offset + length > end { return nil }
                if values.count == 3, case .bytes(let start) = values[2] {
                    // 分段文件：字面量前缀先入结果
                    parts.append(.literal(start))
                }
                parts.append(.region(offset: offset, length: length))
            default:
                return nil
            }
        }
        return parts.isEmpty ? nil : Placement(parts: parts)
    }

    /// 文件名可能是 str、bytes 或 (目录, 文件名)
    private static func name(from value: PyValue) -> String? {
        switch value {
        case .array(let parts):
            let texts = parts.compactMap { $0.textValue }
            guard texts.count == parts.count, !texts.isEmpty else { return nil }
            return texts.joined(separator: "/")
        default:
            return value.textValue
        }
    }

    /// 十六进制字段；越界或非法时返回 nil
    static func hexValue(_ text: String, in range: Range<Int>) -> Int? {
        let characters = Array(text)
        guard range.upperBound <= characters.count else { return nil }
        let slice = String(characters[range.lowerBound ..< range.upperBound])
        let trimmed = slice.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed, radix: 16)
    }
}

import Foundation

/// 测试用的极简 zip 生成器（不压缩），可以精确控制文件名字节、UTF-8 标志和文件类型，
/// 用来构造 GBK 文件名、`../` 越界路径、符号链接等特殊情况。
enum TestZip {
    struct Entry {
        enum Kind {
            case file
            case directory
            case symlink
        }

        var name: [UInt8]
        var data: Data
        var utf8Flag: Bool
        var kind: Kind

        static func file(_ name: String, _ content: String) -> Entry {
            Entry(name: Array(name.utf8), data: Data(content.utf8), utf8Flag: true, kind: .file)
        }

        static func directory(_ name: String) -> Entry {
            Entry(name: Array(name.utf8), data: Data(), utf8Flag: true, kind: .directory)
        }

        static func symlink(_ name: String, target: String) -> Entry {
            Entry(name: Array(name.utf8), data: Data(target.utf8), utf8Flag: true, kind: .symlink)
        }
    }

    static func make(_ entries: [Entry]) -> Data {
        var archive = Data()
        var central = Data()

        for entry in entries {
            let offset = UInt32(archive.count)
            let crc = crc32(entry.data)
            let flags: UInt16 = entry.utf8Flag ? 1 << 11 : 0
            let size = UInt32(entry.data.count)
            let mode: UInt32
            switch entry.kind {
            case .file: mode = 0o100644
            case .directory: mode = 0o040755
            case .symlink: mode = 0o120777
            }

            // 本地文件头
            archive.appendLE(UInt32(0x0403_4B50))
            archive.appendLE(UInt16(20))        // 解压所需版本
            archive.appendLE(flags)
            archive.appendLE(UInt16(0))         // 不压缩
            archive.appendLE(UInt16(0))         // 修改时间
            archive.appendLE(UInt16(33))        // 修改日期 1980-01-01
            archive.appendLE(crc)
            archive.appendLE(size)
            archive.appendLE(size)
            archive.appendLE(UInt16(entry.name.count))
            archive.appendLE(UInt16(0))
            archive.append(contentsOf: entry.name)
            archive.append(entry.data)

            // 中央目录记录
            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(0x0314))    // Unix 系统创建，版本 2.0
            central.appendLE(UInt16(20))
            central.appendLE(flags)
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(33))
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(entry.name.count))
            central.appendLE(UInt16(0))         // 扩展字段长度
            central.appendLE(UInt16(0))         // 注释长度
            central.appendLE(UInt16(0))         // 起始磁盘
            central.appendLE(UInt16(0))         // 内部属性
            central.appendLE(mode << 16)        // 外部属性：Unix 权限位
            central.appendLE(offset)
            central.append(contentsOf: entry.name)
        }

        let centralOffset = UInt32(archive.count)
        archive.append(central)

        // 中央目录结束记录
        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count))
        archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))
        return archive
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        try make(entries).write(to: url)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

/// 在测试中创建、清理临时目录
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalServerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, _ content: String) throws -> URL {
        try write(relativePath, Data(content.utf8))
    }

    @discardableResult
    func write(_ relativePath: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func read(_ relativePath: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }
}

/// 线程安全的小容器，用于在 @Sendable 回调中回传结果
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}

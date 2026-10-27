import Foundation

/// 存档列表里的一格
struct VNSaveSlot: Identifiable, Equatable {
    static let autoID = "auto"
    static let manualIDs = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    var id: String
    var label: String?
    var preview: String?
    var savedAt: Date?

    var isEmpty: Bool { savedAt == nil }

    var title: String {
        id == Self.autoID ? "自动存档" : "存档 \(id)"
    }
}

/// 一部游戏的存档目录：Application Support 下，不进文件标签页
final class VNSaveStore {
    private let directory: URL
    private let manager = FileManager.default

    init(gameID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VNSaves", isDirectory: true)
            .appendingPathComponent(Self.sanitized(gameID), isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
    }

    func slots() -> [VNSaveSlot] {
        [VNSaveSlot.autoID].map { id in
            metadata(for: id) ?? VNSaveSlot(id: id, label: nil, preview: nil, savedAt: nil)
        } + VNSaveSlot.manualIDs.map { id in
            metadata(for: id) ?? VNSaveSlot(id: id, label: nil, preview: nil, savedAt: nil)
        }
    }

    func hasSave(_ slot: String = VNSaveSlot.autoID) -> Bool {
        manager.fileExists(atPath: fileURL(for: slot).path)
    }

    /// 自动存档和手动存档里最新的那一份，用于“继续游戏”
    func newest() -> VNSaveState? {
        var best: VNSaveState?
        for slot in [VNSaveSlot.autoID] + VNSaveSlot.manualIDs {
            guard let state = read(slot) else { continue }
            if best == nil || state.savedAt > best!.savedAt { best = state }
        }
        return best
    }

    func write(_ state: VNSaveState, slot: String) throws {
        let data = try state.encoded()
        try data.write(to: fileURL(for: slot), options: .atomic)
    }

    func read(_ slot: String) -> VNSaveState? {
        guard let data = try? Data(contentsOf: fileURL(for: slot)) else { return nil }
        return try? VNSaveState.decode(data)
    }

    func delete(_ slot: String) {
        try? manager.removeItem(at: fileURL(for: slot))
    }

    private func metadata(for slot: String) -> VNSaveSlot? {
        guard let state = read(slot) else { return nil }
        return VNSaveSlot(id: slot, label: state.label, preview: state.preview, savedAt: state.savedAt)
    }

    private func fileURL(for slot: String) -> URL {
        directory.appendingPathComponent("\(Self.sanitized(slot)).json")
    }

    private static func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let text = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(text)
        return result.isEmpty ? "game" : result
    }
}

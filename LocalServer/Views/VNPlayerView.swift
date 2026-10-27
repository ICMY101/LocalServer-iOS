import SwiftUI
import UIKit

/// 舞台上的一个元素：背景整屏铺满，立绘按放置参数摆放
enum VNStageItem {
    case background(UIImage)
    case sprite(VNSprite)
}

struct VNSprite {
    var parts: [UIImage]
    var placement: VNPlacement
}

/// 播放器的全部状态。界面只读这些字段，所有推进逻辑都在这里。
final class VNSession: ObservableObject {
    let game: VNGame
    private let assets: GameAssets?
    private let saves: VNSaveStore
    private let audio = VNAudio()
    private(set) var runtime: VNRuntime?
    private var imageCache: [String: UIImage] = [:]
    private var didBegin = false

    @Published private(set) var line: VNLine?
    @Published private(set) var menuTitle: String?
    @Published private(set) var choices: [VNChoice] = []
    @Published private(set) var stage: [VNStageItem] = []
    @Published private(set) var speakerColor: Color?
    @Published private(set) var failure: String?
    @Published private(set) var isFinished = false
    @Published private(set) var slots: [VNSaveSlot] = []
    @Published var notice: String?

    init(game: VNGame) {
        self.game = game
        self.saves = VNSaveStore(gameID: game.id)
        let assets = VNGameLibrary.assets(for: game)
        self.assets = assets
        guard let assets else {
            failure = "找不到游戏文件，可能已经被移动或删除。"
            return
        }
        let result = VNGameLibrary.program(for: game, assets: assets)
        guard let program = result.program, program.startIndex != nil else {
            failure = result.issues.first ?? "脚本里没有可以开始的地方。"
            return
        }
        runtime = VNRuntime(program: program)
    }

    /// 有存档就接着上次，没有就从开头
    func begin() {
        guard !didBegin else { return }
        didBegin = true
        guard failure == nil, let runtime else { return }
        if let state = saves.newest() {
            if runtime.restore(state) {
                apply(runtime.outcome, autosave: false)
                loadSlots()
                return
            }
            notice = "上一次的存档对应的是旧版脚本，已经失效，将从开头开始。"
        }
        apply(runtime.startNewGame())
        loadSlots()
    }

    func restart() {
        guard let runtime else { return }
        failure = nil
        isFinished = false
        apply(runtime.startNewGame())
    }

    func advance() {
        guard let runtime, failure == nil, !isFinished, !runtime.awaitingChoice else { return }
        apply(runtime.advance())
    }

    func choose(_ index: Int) {
        guard let runtime, runtime.awaitingChoice else { return }
        apply(runtime.choose(at: index))
    }

    // MARK: - 存档

    func loadSlots() {
        slots = saves.slots()
    }

    func save(to slot: String) {
        guard let runtime, failure == nil else { return }
        do {
            try saves.write(runtime.saveState(), slot: slot)
            loadSlots()
            notice = slot == VNSaveSlot.autoID ? "已更新自动存档" : "已保存到存档 \(slot)"
        } catch {
            notice = "保存失败：\(error.localizedDescription)"
        }
    }

    func load(from slot: String) {
        guard let runtime else { return }
        guard let state = saves.read(slot) else {
            notice = "这个位置还没有存档。"
            return
        }
        guard runtime.restore(state) else {
            notice = "这份存档和当前脚本不匹配，无法读取。"
            return
        }
        failure = nil
        isFinished = false
        apply(runtime.outcome, autosave: false)
    }

    func delete(slot: String) {
        saves.delete(slot)
        loadSlots()
    }

    func stopAudio() {
        audio.stopAll()
    }

    // MARK: - 状态同步

    private func apply(_ outcome: VNOutcome, autosave: Bool = true) {
        switch outcome {
        case .line(let value):
            line = value
            menuTitle = nil
            choices = []
            isFinished = false
            speakerColor = color(for: value.speaker)
        case .choices(let title, let options):
            menuTitle = title
            choices = options
            isFinished = false
        case .finished:
            isFinished = true
            choices = []
            menuTitle = nil
        case .failed(let message):
            failure = message
            choices = []
        }

        refreshStage()
        if let runtime { audio.update(tracks: runtime.tracks, assets: assets) }
        if autosave, failure == nil, !isFinished, let runtime {
            try? saves.write(runtime.saveState(), slot: VNSaveSlot.autoID)
        }
    }

    private func refreshStage() {
        guard let runtime else {
            stage = []
            return
        }
        var items: [VNStageItem] = []
        for layer in layerOrder(Array(runtime.layers.keys)) {
            for shown in runtime.layers[layer] ?? [] {
                // 分层立绘：每个部件都是同一张画布，按声明顺序叠起来
                if let names = runtime.layeredParts(for: shown.name), !names.isEmpty {
                    let parts = names.compactMap { image(named: $0) }
                    if !parts.isEmpty {
                        items.append(.sprite(VNSprite(parts: parts,
                                                      placement: VNPlacement.from(at: shown.at))))
                        continue
                    }
                }
                if let image = image(for: shown) { items.append(.background(image)) }
            }
        }
        stage = items
    }

    /// master 在最底下，其余图层按名字排
    private func layerOrder(_ names: [String]) -> [String] {
        var order = names.sorted()
        if let index = order.firstIndex(of: "master") {
            order.remove(at: index)
            order.insert("master", at: 0)
        }
        return order
    }

    private func image(for shown: VNShownImage) -> UIImage? {
        if let resource = shown.resource, let image = image(named: resource) { return image }
        return image(named: shown.name)
    }

    private func image(named name: String) -> UIImage? {
        if let cached = imageCache[name] { return cached }
        guard let data = assets?.imageData(named: name), let image = UIImage(data: data) else {
            return nil
        }
        imageCache[name] = image
        return image
    }

    private func color(for speaker: String?) -> Color? {
        guard let speaker, let runtime else { return nil }
        for character in runtime.store.characterSnapshot().values where character.name == speaker {
            if let hex = character.colorHex, let color = Color(hex: hex) { return color }
        }
        return nil
    }
}

// MARK: - 播放器界面

struct VNPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: VNSession
    @State private var showSaves = false

    init(game: VNGame) {
        _session = StateObject(wrappedValue: VNSession(game: game))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            stageView
            VStack(spacing: 0) {
                Spacer()
                if let line = session.line, session.choices.isEmpty {
                    dialogue(line)
                }
            }
            if !session.choices.isEmpty { choiceOverlay }
            if let failure = session.failure { failureView(failure) }
            else if session.isFinished { finishedView }
            topBar
        }
        .contentShape(Rectangle())
        .onTapGesture { session.advance() }
        .statusBarHidden()
        .onAppear { session.begin() }
        .onDisappear { session.stopAudio() }
        .sheet(isPresented: $showSaves) { VNSaveSheet(session: session) }
        .alert("提示", isPresented: Binding(
            get: { session.notice != nil },
            set: { if !$0 { session.notice = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(session.notice ?? "")
        }
    }

    /// 游戏自己的画面尺寸：取正在显示的第一张背景图，立绘按它的比例摆放
    private var baseSize: CGSize {
        for item in session.stage {
            if case .background(let image) = item, image.size.width > 0, image.size.height > 0 {
                return image.size
            }
        }
        return CGSize(width: 800, height: 600)
    }

    private var stageView: some View {
        GeometryReader { geometry in
            let base = baseSize
            let cover = max(geometry.size.width / base.width, geometry.size.height / base.height)
            let screenWidth = base.width * cover
            let screenHeight = base.height * cover
            let originX = (geometry.size.width - screenWidth) / 2
            let originY = (geometry.size.height - screenHeight) / 2
            ZStack {
                ForEach(Array(session.stage.enumerated()), id: \.offset) { item in
                    switch item.element {
                    case .background(let image):
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    case .sprite(let sprite):
                        spriteView(sprite,
                                   originX: originX, originY: originY,
                                   screenWidth: screenWidth, screenHeight: screenHeight,
                                   cover: cover)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    /// 立绘部件都是同一张画布，叠在同一个框里就自然对齐
    private func spriteView(_ sprite: VNSprite, originX: CGFloat, originY: CGFloat,
                            screenWidth: CGFloat, screenHeight: CGFloat, cover: CGFloat) -> some View {
        let native = sprite.parts[0].size
        let width = native.width * CGFloat(sprite.placement.zoom) * cover
        let height = native.height * CGFloat(sprite.placement.zoom) * cover
        let x = originX + CGFloat(sprite.placement.xpos) * screenWidth
            - CGFloat(sprite.placement.xanchor) * width + width / 2
        let y = originY + CGFloat(sprite.placement.ypos) * screenHeight
            - CGFloat(sprite.placement.yanchor) * height + height / 2
        return ZStack {
            ForEach(Array(sprite.parts.enumerated()), id: \.offset) { part in
                Image(uiImage: part.element)
                    .resizable()
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .position(x: x, y: y)
    }

    private func dialogue(_ line: VNLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let speaker = line.speaker, !speaker.isEmpty {
                Text(speaker)
                    .font(.headline)
                    .foregroundColor(session.speakerColor ?? .white)
            }
            Text(line.text)
                .font(.title3)
                .foregroundColor(.white.opacity(0.95))
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    private var choiceOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    if let title = session.menuTitle {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 4)
                    }
                    ForEach(Array(session.choices.enumerated()), id: \.offset) { item in
                        Button {
                            session.choose(item.offset)
                        } label: {
                            Text(item.element.text)
                                .font(.body.weight(.medium))
                                .foregroundColor(item.element.enabled ? Color.black : Color(UIColor.secondaryLabel))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 12)
                                .background(
                                    Color.white.opacity(item.element.enabled ? 0.94 : 0.35),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                        }
                        .disabled(!item.element.enabled)
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
            }
        }
    }

    private var finishedView: some View {
        VStack(spacing: 16) {
            Text("本段剧情结束")
                .font(.title2.weight(.semibold))
                .foregroundColor(.white)
            Text("可以从存档里读档，或者从头再玩一次。")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.75))
            HStack(spacing: 12) {
                Button("从头开始") { session.restart() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                Button("返回游戏库") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(24)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.yellow)
            Text("这个游戏暂时跑不起来")
                .font(.headline)
                .foregroundColor(.white)
            Text(message)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button("返回游戏库") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .padding(24)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(24)
    }

    private var topBar: some View {
        VStack {
            HStack(spacing: 10) {
                circleButton("xmark") { dismiss() }
                Spacer()
                Text(session.game.title)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                circleButton("tray.and.arrow.down") { showSaves = true }
                Menu {
                    Button("存档 / 读档") { showSaves = true }
                    Button("从头开始") { session.restart() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.black.opacity(0.45), in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    private func circleButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.45), in: Circle())
        }
    }
}

// MARK: - 存档面板

struct VNSaveSheet: View {
    @ObservedObject var session: VNSession
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .load

    enum Mode: String, CaseIterable {
        case load = "读档"
        case save = "存档"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.slots) { slot in
                        Button {
                            select(slot)
                        } label: {
                            row(slot)
                        }
                        .buttonStyle(.plain)
                        .disabled(mode == .load && slot.isEmpty)
                        .swipeActions(edge: .trailing) {
                            if !slot.isEmpty {
                                Button("删除", role: .destructive) {
                                    session.delete(slot: slot.id)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(mode == .save ? "选择要覆盖的位置，游戏会同时保留自动存档。" : "自动存档在每次推进后更新。")
                }
            }
            .navigationTitle("存档")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("模式", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { session.loadSlots() }
        }
    }

    private func row(_ slot: VNSaveSlot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(slot.title)
                    .font(.subheadline.weight(.semibold))
                Text(slot.preview ?? "空存档")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                if let date = slot.savedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let label = slot.label {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func select(_ slot: VNSaveSlot) {
        if mode == .save {
            session.save(to: slot.id)
        } else {
            session.load(from: slot.id)
        }
        dismiss()
    }
}

private extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt64(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

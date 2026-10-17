import SwiftUI

/// 简单的文本编辑器，用于直接在手机上修改 HTML / CSS / JS 等文件
struct TextFileEditor: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var confirmDiscard = false

    private static let maxSize = 2 * 1024 * 1024

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(loadError)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, 4)
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        if text != original { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(loadError != nil || text == original)
                }
            }
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("保存并关闭") {
                    if save() { dismiss() }
                }
            }
            .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
        .interactiveDismissDisabled(text != original)
        .onAppear(perform: load)
    }

    private func load() {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= Self.maxSize else {
                loadError = "文件过大（超过 2 MB），无法在 App 内编辑"
                return
            }
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else {
                loadError = "该文件不是 UTF-8 编码的文本，无法编辑"
                return
            }
            text = content
            original = content
        } catch {
            loadError = error.localizedDescription
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            original = text
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

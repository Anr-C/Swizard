import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RCMPayloadPickerView: View {
    let selectedURL: URL?
    let selectionError: String?
    let onSelect: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dropArea
                .frame(height: 110)
                .contentShape(Rectangle())
                .onTapGesture(perform: openFilePicker)
                .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)

            if let selectedURL {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前 Payload")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(selectedURL.path)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if !FileManager.default.fileExists(atPath: selectedURL.path) {
                        Text("文件不存在，请重新选择。")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let selectionError {
                Text(selectionError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
    }

    private var dropArea: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("将 .bin payload 拖放到此处")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("或选择文件……", action: openFilePicker)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
            }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.message = "选择 RCM payload（.bin）"

        if panel.runModal() == .OK, let url = panel.url,
           RCMPayloadFileFilter.resolveSupportedURL(fromFileURLData: url.dataRepresentation) != nil {
            onSelect(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data,
                  let url = RCMPayloadFileFilter.resolveSupportedURL(fromFileURLData: data) else {
                return
            }
            DispatchQueue.main.async {
                onSelect(url)
            }
        }
        return true
    }
}

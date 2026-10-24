import SwiftUI
import UniformTypeIdentifiers

struct SourceToolbar: View {
    @ObservedObject var line: Line
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 10) {
            if line.loading { ProgressView().controlSize(.small) }
            if let message = line.sourceMessage {
                Button("重试", systemImage: "arrow.clockwise", action: line.refreshSource)
                    .labelStyle(.iconOnly)
                    .help(message)
            }
            Button("卡片大小", systemImage: "rectangle.expand.vertical", action: line.onSizeMenu)
                .labelStyle(.iconOnly)
            Button(action: line.onSourcesMenu) {
                Label(line.sourceTitle, systemImage: line.currentFolder == nil ? "clipboard" : "folder")
                    .lineLimit(1)
                    .frame(maxWidth: 130)
            }
            if let folder = line.currentFolder {
                Button(folder.sort.title, action: line.onSortMenu)
            }
            Button("添加来源", systemImage: "folder.badge.plus", action: line.onAddFolder)
                .labelStyle(.iconOnly)
                .padding(4)
                .background(dropTarget ? Color.orange.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .help("添加来源；也可将访达文件夹拖到这里")
                .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        guard let url else { return }
                        DispatchQueue.main.async { line.onDropFolder(url) }
                    }
                    return true
                }
            Button("设置", systemImage: "gearshape", action: line.onSettingsMenu).labelStyle(.iconOnly)
            Button("收起", systemImage: "chevron.up", action: line.onHide).labelStyle(.iconOnly)
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassFrame(capsule: true)
    }
}

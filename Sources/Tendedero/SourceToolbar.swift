import SwiftUI
import UniformTypeIdentifiers

struct SourceToolbar: View {
    @ObservedObject var line: Line
    @State private var dropTarget = false

    var body: some View {
        HStack(spacing: 8) {
            if line.loading && line.items.isEmpty { ProgressView().controlSize(.small) }
            if let message = line.sourceMessage {
                Button("重试", systemImage: "arrow.clockwise", action: line.refreshSource)
                    .labelStyle(.iconOnly)
                    .help(message)
            }
            Button("全部") { line.setFilter(nil) }
                .foregroundStyle(line.filter == nil ? Color.primary : .secondary)
                .accessibilityValue(line.filter == nil ? "已选中" : "未选中")
            ForEach(FileKind.allCases, id: \.self) { kind in
                Button { line.setFilter(kind) } label: {
                    Image(systemName: line.filter == kind ? "checkmark" : kind.symbol)
                        .frame(width: 23, height: 23)
                        .foregroundStyle(Color.black.opacity(0.75))
                        .background(kind.tint, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(line.filter == kind ? Color.orange : .clear, lineWidth: 1.5))
                }
                .accessibilityLabel("筛选\(kind.title)")
                .accessibilityValue(line.filter == kind ? "已选中" : "未选中")
                .help(kind.title)
            }
            Button("卡片大小", systemImage: "rectangle.expand.vertical", action: line.onSizeMenu)
                .labelStyle(.iconOnly)
            Button(action: line.onSourcesMenu) {
                Label(line.sourceTitle, systemImage: line.isRecent ? "clock" : line.isClipboard ? "clipboard" : "folder")
                    .lineLimit(1)
                    .frame(maxWidth: 130)
            }
            if line.currentFolder != nil {
                Text("添加日期 ↓")
                    .help("按访达添加日期由新到旧排列")
            } else if line.isClipboard {
                Button(line.clipboardRecording ? "暂停记录" : "开启记录", systemImage: line.clipboardRecording ? "pause.circle" : "record.circle", action: line.onToggleClipboard)
                    .help("第三方截图复制到剪贴板后可挂起；关闭时不读取剪贴板内容")
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

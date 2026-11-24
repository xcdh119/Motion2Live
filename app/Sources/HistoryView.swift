import SwiftUI
import AppKit

struct HistoryView: View {
    @ObservedObject var model: AppModel

    @State private var search = ""
    @State private var selection: HistoryEntry.ID?
    @State private var showClear = false

    private var filtered: [HistoryEntry] {
        guard !search.isEmpty else { return model.history }
        return model.history.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.device.localizedCaseInsensitiveContains(search)
                || $0.status.localizedCaseInsensitiveContains(search)
                || ($0.error ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    private var selectedEntry: HistoryEntry? {
        guard let selection else { return nil }
        return model.history.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("转换历史", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                TextField("搜索文件、设备或状态", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("清空历史") { showClear = true }
                    .disabled(model.history.isEmpty)
            }
            .padding(12)

            Divider()

            ZStack {
                Table(filtered, selection: $selection) {
                    TableColumn("时间") { entry in
                        Text(entry.date, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 11))
                    }
                    .width(min: 92, ideal: 108)

                    TableColumn("文件") { entry in
                        Text(entry.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("状态") { entry in
                        statusCell(entry)
                    }
                    .width(min: 64, ideal: 76)

                    TableColumn("设备") { entry in
                        Text(entry.device)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("备注") { entry in
                        Text(entry.error ?? entry.uuid ?? "")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 200)
                }
                .tableStyle(.inset)

                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text(search.isEmpty ? "还没有转换记录" : "没有匹配的记录")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }

            Divider()

            HStack {
                if let entry = selectedEntry {
                    Button("在 Finder 中显示") { model.revealHistory(entry) }
                        .disabled(entry.outputJPG == nil && entry.outputMOV == nil)
                }
                Text("共 \(model.history.count) 条")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 440)
        .alert("清空转换历史？", isPresented: $showClear) {
            Button("清空", role: .destructive) {
                model.clearHistory()
                selection = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清空记录，不会删除任何照片或输出文件。")
        }
    }

    @ViewBuilder
    private func statusCell(_ entry: HistoryEntry) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor(entry.status))
                .frame(width: 6, height: 6)
            Text(entry.status)
                .font(.system(size: 11))
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "成功": return .green
        case "失败": return .red
        default: return .secondary
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }
}

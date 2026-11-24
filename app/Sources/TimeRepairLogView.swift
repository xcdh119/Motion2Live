import SwiftUI
import AppKit

struct TimeRepairLogView: View {
    @ObservedObject var task: TimeRepairTask

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(task.running ? "正在修复时间…" : "时间修复已结束").font(.headline)
                Spacer()
                Text("\(task.completed)/\(task.total)").monospacedDigit().foregroundStyle(.secondary)
            }.padding()
            if task.running {
                ProgressView(value: Double(task.completed), total: Double(max(1, task.total)))
                    .padding(.horizontal).padding(.bottom, 10)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(task.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding()
                }
                .onChange(of: task.log.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            HStack {
                Button("拷贝日志") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(task.log.joined(separator: "\n"), forType: .string)
                }
                if !task.running, let result = task.result {
                    Button("查看输出") { NSWorkspace.shared.open(result) }
                }
                Spacer()
                Button("关闭") { task.closeWindows() }.keyboardShortcut(.cancelAction)
            }.padding()
        }.frame(minWidth: 520, minHeight: 300)
    }
}

struct TimeRepairFailuresView: View {
    @ObservedObject var task: TimeRepairTask
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(task.failures.count) 个项目未能修复", systemImage: "exclamationmark.triangle")
                .font(.title2)
            Text("以下原文件未被修改。没有可靠时间的项目可改为手动指定后重试。")
                .foregroundStyle(.secondary)
            List(task.failures) { failure in
                VStack(alignment: .leading, spacing: 5) {
                    Text(failure.url.lastPathComponent).font(.headline)
                    Text(failure.reason).font(.callout).textSelection(.enabled)
                    HStack {
                        Button("显示原文件") { NSWorkspace.shared.activateFileViewerSelecting([failure.url]) }
                        if let folder = failure.folder {
                            Button("查看失败副本") { NSWorkspace.shared.open(folder) }
                        }
                    }.controlSize(.small)
                }.padding(.vertical, 5)
            }
            HStack {
                Button("处理日志…") { task.showLog() }
                Spacer()
                Button("好") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560, height: 380)
    }
}

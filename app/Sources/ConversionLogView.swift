import SwiftUI
import AppKit

struct ConversionLogView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("转换日志")
                        .font(.system(size: 15, weight: .semibold))
                    Text(model.isConverting ? "转换中…" : "已结束")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.progressTotal > 0 {
                    Text("\(model.progressDone)/\(model.progressTotal)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(model.progressDone),
                                 total: Double(max(1, model.progressTotal)))
                        .frame(width: 120)
                }
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if model.conversionLog.isEmpty {
                            Text("还没有转换日志。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                        }
                        ForEach(Array(model.conversionLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                    .padding(12)
                }
                .background(Color.primary.opacity(0.03))
                .onChange(of: model.conversionLog.count) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("log-bottom", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                Button("查看不支持") { model.conversionResultSheet = .unsupported }
                    .disabled(model.lastUnsupportedItems.isEmpty)
                Button("查看无法修复时间") { model.conversionResultSheet = .missingDates }
                    .disabled(model.missingDateItems.isEmpty)
                    Spacer()
                }
                HStack(spacing: 10) {
                    if model.isConverting {
                        Button("停止") { model.cancelConversion() }
                    }
                    Button("拷贝日志") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.conversionLog.joined(separator: "\n"),
                                                       forType: .string)
                    }
                    Button("清空") { model.conversionLog.removeAll() }
                    Spacer()
                    Button("关闭") { closeWindow() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 560, minHeight: 360)
        .sheet(item: $model.conversionResultSheet) { sheet in
            switch sheet {
            case .unsupported:
                UnsupportedSheet(model: model, useLastResults: true)
            case .missingDates:
                MissingDatesResultView(model: model)
            }
        }
    }

    private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }
}

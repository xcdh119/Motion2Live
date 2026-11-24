import SwiftUI
import AppKit

func failureHint(_ error: String) -> String {
    let e = error.lowercased()
    if e.contains("moov atom not found") {
        return "视频缺少播放索引（moov）。文件可能已损坏，或录制、导出、复制时中断。请在手机相册中播放原实况；如果原件能播放，请重新导出或完整复制后再试。"
    }
    if e.contains("invalid data found when processing input") {
        return "无法读取视频内容。配对视频可能损坏、复制不完整，或扩展名与实际格式不符。请检查原视频能否播放，再从手机重新导出。"
    }
    if error.contains("没有 MakerNote 入口") || error.contains("没有 ExifIFD") {
        return "原图的 Exif 被换机工具改写过，MakerNote / ExifIFD 不完整。新版会自动补；仍失败说明这张图的 Exif 结构不标准，建议用原图或重新导出后再试。"
    }
    if error.contains("没有 Exif APP1") {
        return "静态 JPEG 缺少 EXIF 元数据，这不代表视频损坏。新版会自动新建配对所需的 EXIF 段；若仍失败，请检查静图是否完整。"
    }
    if error.contains("找不到视频") || error.contains("没有找到视频") || error.contains("不是实况") {
        return "没有在文件里找到可用的动态视频，可能不是 OPPO / vivo 的实况原片，或视频被截断。"
    }
    if e.contains("contentidentifier") || e.contains("exiftool") {
        return "视频容器不支持写入 Apple ContentIdentifier，或 exiftool 处理失败。检查视频是否完整，或改用「文件夹」输出后重试。"
    }
    if e.contains("ffmpeg") || e.contains("ffprobe") {
        return "视频编码 / 封装不标准，ffmpeg 无法处理；可以先在手机上重新导出这张实况。"
    }
    if error.contains("权限") || e.contains("permission") || e.contains("operation not permitted") {
        return "输出目录或照片图库没有写入权限；检查系统设置里的「照片」权限，或改用「文件夹」输出。"
    }
    if e.contains("no space") || error.contains("空间不足") {
        return "磁盘空间不足；清理输出盘后重试。"
    }
    if e.contains("no such file") || error.contains("找不到文件") {
        return "原文件在转换过程中被移动或删除了；重新拖入再试。"
    }
    if e.contains("python3") {
        return "系统缺少 python3；在终端运行 xcode-select --install。"
    }
    return "程序在处理这张图时抛错；具体原因看下面的程序输出（traceback）。如果反复出现，把原片和日志发给我。"
}

private func failureMessage(_ item: PhotoItem) -> String {
    if case .failed(let message) = item.status { return message }
    return "未知错误"
}

private func failureCopyText(_ item: PhotoItem) -> String {
    var parts = [item.name, failureMessage(item)]
    if let log = item.failureLog, !log.isEmpty {
        parts.append(log)
    }
    return parts.joined(separator: "\n\n")
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct FailuresSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PhotoItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.failedItems.count) 张转换失败")
                        .font(.system(size: 14, weight: .semibold))
                    Text("这些照片没有转换成功，原文件没有被修改。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.failedItems) { item in
                            Button {
                                selected = item
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                    Text(failureMessage(item))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selected?.id == item.id
                                              ? Color.accentColor.opacity(0.14)
                                              : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(width: 230)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    if let item = selected {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(failureMessage(item))
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                        Text(failureHint(failureMessage(item)))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            Text(item.failureLog ?? "没有更多日志。")
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        HStack(spacing: 10) {
                            Button("拷贝日志") { copyToPasteboard(failureCopyText(item)) }
                                .buttonStyle(.borderless)
                            Button("在 Finder 中显示") { model.reveal(item) }
                                .buttonStyle(.borderless)
                            Spacer()
                        }
                    } else {
                        Text("选择左侧的一条查看错误日志。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("在 Finder 中显示全部") { model.revealFailed() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("好") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 540)
        .onAppear { selected = model.failedItems.first }
    }
}

struct FailureDetailSheet: View {
    @ObservedObject var model: AppModel
    let item: PhotoItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(failureMessage(item))
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            Text(failureHint(failureMessage(item)))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                Text(item.failureLog ?? "没有更多日志。")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

            Divider()

            HStack(spacing: 10) {
                Button("拷贝日志") { copyToPasteboard(failureCopyText(item)) }
                Button("在 Finder 中显示") { model.reveal(item) }
                Spacer()
                Button("好") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 520)
    }
}

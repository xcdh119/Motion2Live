import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MissingDatesResultView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var showFailures = false
    @StateObject private var task = TimeRepairTask()
    @State private var confirmModified = false

    var body: some View {
        if showFailures {
            FailuresSheet(model: model)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("处理结果").font(.title2.bold())
                if let summary = model.summary { Text(summary).foregroundStyle(.secondary) }
                Text("以下项目未读到可用的拍摄时间。原文件可能没有记录，或日期元数据无法读取。")
                if model.destination != .folder, model.missingDateItems.contains(where: { $0.isConvertible }) {
                    Text("待补时间的实况已暂缓导入「照片」。").foregroundStyle(.secondary)
                }
                List(model.missingDateItems) { item in
                    Label(item.name, systemImage: item.isConvertible ? "livephoto" : item.kind == .video ? "video" : "photo")
                }
                if task.running { ProgressView(value: Double(task.completed), total: Double(max(task.total, 1))) }
                if !task.message.isEmpty { Text(task.message) }
                if let result = task.result {
                    Button("查看修复副本") { NSWorkspace.shared.open(result) }
                }
                HStack {
                    if !model.failedItems.isEmpty {
                        Button("查看转换失败…") { showFailures = true }
                    }
                    Spacer()
                    Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("使用修改日期…") { confirmModified = true }
                        .disabled(model.missingDateItems.isEmpty)
                    Button("手动写入拍摄时间…") {
                        model.pendingTimeRepair = model.missingDateItems
                        dismiss()
                    }
                        .disabled(model.missingDateItems.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 620, height: 390)
            .disabled(task.running)
            .interactiveDismissDisabled(task.running)
            .onDisappear { task.closeWindows() }
            .onChange(of: task.repairedURLs) { model.markDatesRepaired($0) }
            .sheet(isPresented: $task.showFailures) { TimeRepairFailuresView(task: task) }
            .alert("使用文件修改日期？", isPresented: $confirmModified) {
                Button("取消", role: .cancel) {}
                Button("写入副本") {
                    task.start(files: model.missingDateItems.map { $0.outputJPG ?? $0.url },
                               output: nil, capture: nil, useModifiedDate: true)
                }
            } message: {
                Text("按 Finder 显示的修改日期为每个项目写入拍摄时间，并另存副本。实况的静图和视频使用同一时间。")
            }
        }
    }
}

/// Time repair is deliberately separate from conversion and classification.
struct TimeRepairSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var task = TimeRepairTask()
    @State private var files: [URL]
    @State private var selected: Set<URL>
    @State private var manual = false
    @State private var stillOnly = false
    @State private var confirmStillOnly = false
    @State private var date = Date()
    @State private var zone = "Asia/Shanghai"
    @State private var output: URL?
    @State private var saveToSource = true
    @State private var isDropTargeted = false
    @State private var fileNotice: String?
    var onRepaired: (Set<URL>) -> Void
    let queuedURLs: Set<URL>

    init(items: [PhotoItem], manual: Bool = false, queuedItems: [PhotoItem]? = nil,
         onRepaired: @escaping (Set<URL>) -> Void = { _ in }) {
        let queued = Set((queuedItems ?? []).map { ($0.outputJPG ?? $0.url).standardizedFileURL })
        let urls = Set(items.map { ($0.outputJPG ?? $0.url).standardizedFileURL }).union(queued)
            .sorted { $0.path < $1.path }
        _files = State(initialValue: urls)
        _selected = State(initialValue: queuedItems == nil ? Set(urls) : queued)
        _manual = State(initialValue: manual)
        self.onRepaired = onRepaired
        queuedURLs = queued
    }

    private var timeZone: TimeZone { TimeZone(identifier: zone) ?? .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(manual ? "手动写入拍摄时间" : "仅修复时间").font(.title2.bold())
            Text("另存修复副本，不移动或覆盖原文件。同名静图与视频会一起修复，保留实况配对。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("选择要修复的项目（\(selected.count)）")
                Spacer()
                Button("添加文件…", action: chooseFiles)
            }
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if files.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                        Text(isDropTargeted ? "松开以添加文件" : "将照片或视频拖到这里")
                            .font(.headline)
                        Text("支持多选；实况静图与同名视频会一起修复")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("选择文件…", action: chooseFiles)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        List {
                            ForEach(files, id: \.self) { url in
                              HStack(spacing: 8) {
                                ThumbnailView(url: url)
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay { RepairPreviewButton(url: url) }
                                Toggle(isOn: Binding(get: { selected.contains(url) }, set: {
                                    if $0 { selected.insert(url) } else { selected.remove(url) }
                                })) {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading) {
                                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                            Text(url.deletingLastPathComponent().path)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        if !manual {
                                            VStack(alignment: .trailing, spacing: 2) {
                                                if let preview = task.previews[url] {
                                                    Text(preview.timeText).monospacedDigit()
                                                    Text(preview.sourceText).font(.caption).foregroundStyle(.secondary)
                                                } else {
                                                    Text(task.previewing ? "正在读取…" : "需手动指定")
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .font(.callout).frame(width: 172, alignment: .trailing)
                                        }
                                    }

                                }
                              }
                            }
                        }.listStyle(.inset)
                        Divider()
                        HStack {
                            Text(isDropTargeted ? "松开以追加文件" : "可继续拖入照片或视频")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("全选") { selected = Set(files) }
                            Button("取消全选") { selected.removeAll() }
                        }.padding(8)
                    }
                }
            }
            .frame(minHeight: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1)))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: receiveDrop)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("照片与视频拖放区")
            if let fileNotice { Text(fileNotice).font(.caption).foregroundStyle(.secondary) }
            Form {
                Picker("修复方式", selection: $manual) {
                    Text("自动读取拍摄时间").tag(false)
                    Text("手动指定时间").tag(true)
                }.pickerStyle(.radioGroup)
                if manual {
                    Toggle("只写入静态图片，不处理配对视频", isOn: $stillOnly)
                    Picker("时区", selection: $zone) {
                        Text("北京时间（UTC+8）").tag("Asia/Shanghai")
                        if TimeZone.current.identifier != "Asia/Shanghai" && TimeZone.current.identifier != "Etc/UTC" {
                            Text("系统时区（\(TimeZone.current.identifier)）").tag(TimeZone.current.identifier)
                        }
                        Text("协调世界时（UTC）").tag("Etc/UTC")
                    }
                    DatePicker("拍摄时间", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                        .environment(\.timeZone, timeZone)
                    Text("所选项目统一使用此时间，秒数为 00。请先取消勾选其他项目。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("读取媒体元数据或明确的日期文件名；没有可靠时间时提示失败，可改用手动指定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("保存到", selection: $saveToSource) {
                    Text("源文件夹").tag(true)
                    Text("自选路径").tag(false)
                }
                if !saveToSource {
                    HStack {
                        Text(output?.path ?? "请选择保存位置")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("选择…", action: chooseOutput)
                    }
                }
                Text("修复副本存入批次的「为图片写入时间」，失败副本存入「失败／写入时间」。")
                    .font(.caption).foregroundStyle(.secondary)

            }
            Text("已导入「照片」的项目不会自动改变；请将修复后的静图和视频一起重新导入。安卓实况需先转换为 Apple 实况。")
                .font(.caption).foregroundStyle(.secondary)
            if task.running {
                ProgressView("处理中 \(task.completed)/\(task.total)", value: Double(task.completed), total: Double(max(task.total, 1)))
            }
            if !task.message.isEmpty {
                ScrollView { Text(task.message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 90)
            }
            HStack {
                if let result = task.result { Button("查看修复副本") { NSWorkspace.shared.open(result) } }
                if !task.log.isEmpty { Button("处理日志…") { task.showLog() } }
                if !task.failures.isEmpty { Button("查看失败…") { task.showFailures = true } }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("修复时间") {
                    if manual && stillOnly {
                        confirmStillOnly = true
                    } else {
                        startRepair(stillOnly: false)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || (!saveToSource && output == nil) || task.previewing)
            }
        }
        .padding(20).frame(width: 680, height: 700)
        .disabled(task.running)
        .interactiveDismissDisabled(task.running)
        .onAppear { task.preview(files: files) }
        .onChange(of: files) { task.preview(files: $0) }
        .onChange(of: queuedURLs) { urls in
            guard !urls.isEmpty else { return }
            files = Set(files).union(urls).sorted { $0.path < $1.path }
            selected.formUnion(urls)
            manual = true
            stillOnly = false
        }
        .onChange(of: task.repairedURLs) { onRepaired($0) }
        .onDisappear { task.closeWindows() }
        .alert("只写入静态图片？", isPresented: $confirmStillOnly) {
            Button("取消", role: .cancel) {}
            Button("写入静态图片") { startRepair(stillOnly: true) }
        } message: {
            Text("应用将另存带拍摄时间的静态图片副本，跳过配对视频。单独导入副本时，相册会将它显示为普通照片。")
        }
        .sheet(isPresented: $task.showFailures) { TimeRepairFailuresView(task: task) }
    }

    private func startRepair(stillOnly: Bool) {
        guard saveToSource || output != nil else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:00XXXXX"
        task.start(files: files.filter { selected.contains($0) }, output: saveToSource ? nil : output,
                   capture: manual ? formatter.string(from: date) : nil, stillOnly: stillOnly)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    private func addFiles(_ urls: [URL]) {
        var rejected = 0
        for raw in urls {
            let url = raw.standardizedFileURL
            let type = UTType(filenameExtension: url.pathExtension)
            let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp", "avif",
                                           "mp4", "mov", "m4v", "avi", "mkv", "3gp", "mts", "m2ts"]
            guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()),
                  type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true else {
                rejected += 1
                continue
            }
            if !files.contains(url) { files.append(url) }
            selected.insert(url)
        }
        fileNotice = rejected > 0 ? "已忽略 \(rejected) 个项目，请拖入照片或视频文件。" : nil
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !task.running else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { addFiles(urls) }
        return true
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { output = panel.url }
    }
}

private struct RepairPreviewButton: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PreviewButton {
        let button = PreviewButton(frame: .zero)
        button.isTransparent = true
        button.toolTip = "打开预览"
        button.setAccessibilityLabel("打开预览")
        button.target = button
        button.action = #selector(PreviewButton.openPreview)
        return button
    }

    func updateNSView(_ button: PreviewButton, context: Context) { button.url = url }

    final class PreviewButton: NSButton {
        var url: URL?
        private var openedByPressure = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            title = ""
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func mouseDown(with event: NSEvent) {
            openedByPressure = false
            super.mouseDown(with: event)
        }

        override func pressureChange(with event: NSEvent) {
            guard event.stage == 2, !openedByPressure else { return }
            openPreview()
            openedByPressure = true
        }

        @objc func openPreview() {
            guard !openedByPressure, let url else { return }
            openedByPressure = true
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
                NSWorkspace.shared.open(url)
            } else if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
                NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: .init(), completionHandler: nil)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

// MARK: - Root view

struct ContentView: View {
    @ObservedObject var model: AppModel
    var forSnapshot: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showConversionLog") private var showConversionLog = true
    @State private var isTargeted = false
    @State private var showTimeRepair = false
    @State private var manualTimeRepair = false

    var body: some View {
        NavigationSplitView {
            sourceSidebar
                .navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 270)
        } detail: {
            ZStack {
                background
                VStack(spacing: 0) {
                    header
                    dropZone
                    if model.items.isEmpty {
                        emptyState
                    } else {
                        itemList
                    }
                    if model.isConverting || model.isImporting {
                        progressBar
                    }
                    footer
                }
            }
            .frame(minWidth: 780, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
            .background(MainWindowConfigurator().frame(width: 0, height: 0))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1020, minHeight: 680)
        .alert("提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            demoWindows()
            if !forSnapshot && !CommandLine.arguments.contains(where: { $0.hasPrefix("--demo") || $0.hasPrefix("--snapshot") || $0 == "--auto" }) {
                model.updateWorkspaceMonitoring()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConversionLogWindow)) { _ in
            openWindow(id: "conversion-log")
        }
        .alert("检测到新的实况，是否刷新？", isPresented: $model.workspaceRefreshRequested) {
            Button("稍后", role: .cancel) {}
            Button("刷新") { model.scanWorkspace() }
        } message: {
            Text("刷新会加入新项目，并保留之前的转换结果和失败记录。")
        }
        .onReceive(model.$pendingTimeRepair) { items in
            guard items != nil else { return }
            openWindow(id: "main")
            manualTimeRepair = true
            showTimeRepair = true
        }
        .sheet(isPresented: $showTimeRepair, onDismiss: { model.pendingTimeRepair = nil }) {
            TimeRepairSheet(items: model.items, manual: manualTimeRepair, queuedItems: model.pendingTimeRepair,
                            onRepaired: model.markDatesRepaired)
        }
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .openWith(let item):
                OpenWithSheet(model: model, item: item)
            case .unsupported:
                UnsupportedSheet(model: model)
            case .info(let item):
                InfoSheet(model: model, item: item)
            case .failures:
                FailuresSheet(model: model)
            case .failureDetail(let item):
                FailureDetailSheet(model: model, item: item)
            case .delete(let item):
                DeleteSheet(model: model, item: item)
            case .deleteAll:
                DeleteAllSheet(model: model)
            }
        }
    }

    private var sourceSidebar: some View {
        List(selection: $model.filter) {
            Section("图库") {
                Label("全部项目", systemImage: "square.grid.2x2")
                    .badge(model.items.count)
                    .tag(ItemFilter.all)
                Label("可转换实况", systemImage: "livephoto")
                    .badge(model.convertibleCount)
                    .tag(ItemFilter.convertible)
                Label("不是实况", systemImage: "photo")
                    .badge(model.unsupportedCount)
                    .tag(ItemFilter.unsupported)
                Label("视频", systemImage: "video")
                    .badge(model.videoItems.count)
                    .tag(ItemFilter.videos)
                Label("其他照片", systemImage: "photo.stack")
                    .badge(model.otherItems.count)
                    .tag(ItemFilter.other)
                if !model.failedItems.isEmpty {
                    Label("失败", systemImage: "exclamationmark.circle")
                        .badge(model.failedItems.count)
                        .tag(ItemFilter.failed)
                }
            }
            Section("实况来源") {
                if model.fixedWorkspaceEnabled, !model.fixedWorkspacePath.isEmpty {
                    Label(URL(fileURLWithPath: model.fixedWorkspacePath).lastPathComponent,
                          systemImage: "folder.badge.gearshape")
                        .lineLimit(1)
                        .help(model.fixedWorkspacePath)
                    Button {
                        model.scanWorkspace()
                    } label: {
                        Label(model.isScanning ? "正在扫描…" : "立即扫描工作区", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isScanning || model.isConverting || model.isImporting)
                    if let date = model.workspaceScanDate {
                        Text("上次扫描 \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("固定工作区已关闭")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.chooseSingleLivePhoto()
                } label: {
                    Label("添加单张实况…", systemImage: "plus")
                }
                .disabled(model.isScanning || model.isConverting || model.isImporting)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                openWindow(id: "settings")
            } label: {
                Label("设置…", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Image(nsImage: headerIcon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .help(L10n.appName)
            }
        }
    }

    private func demoWindows() {
        let args = CommandLine.arguments
        if args.contains("--demo") || args.contains("--demo-failmain")
            || args.contains("--demo-settings") || args.contains("--demo-delete")
            || args.contains("--demo-log") || args.contains("--demo-history") {
            if model.items.isEmpty { model.loadDemo() }
        }
        if args.contains("--demo-failmain"),
           let i = model.items.firstIndex(where: { $0.name == "IMG_6519.jpg" }) {
            model.items[i].status = .failed("Exif 里没有 MakerNote 入口，无法无损写入")
            model.items[i].failureLog = "RuntimeError: Exif 里没有 MakerNote 入口，无法无损写入"
        }
        if args.contains("--demo-delete"),
           let i = model.items.firstIndex(where: { $0.status == .done }) {
            model.items[i].outputJPG = URL(fileURLWithPath: "/tmp/4055_out/IMG_4055.jpg")
            model.items[i].outputMOV = URL(fileURLWithPath: "/tmp/4055_out/IMG_4055.mov")
            model.activeSheet = .delete(model.items[i])
        }
        if args.contains("--demo-log") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                openWindow(id: "conversion-log")
            }
        }
        if args.contains("--demo-history") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                openWindow(id: "history")
            }
        }
        if args.contains("--demo-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                openWindow(id: "settings")
            }
        }
    }

    // MARK: Background

    @ViewBuilder private var background: some View {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: headerIcon)
                .resizable()
                .renderingMode(.original)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.appName)
                    .font(.system(size: 19, weight: .semibold))
                Text(L10n.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

            Spacer()

            Button("仅修复时间…") {
                manualTimeRepair = false
                showTimeRepair = true
            }
                .disabled(model.isConverting || model.isImporting || model.isScanning)
            Button("手动写入拍摄时间…") {
                manualTimeRepair = true
                showTimeRepair = true
            }
            .disabled(model.isConverting || model.isImporting || model.isScanning)

            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                Text("本机处理").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))

            if !model.items.isEmpty {
                Menu {
                    Button { openWindow(id: "settings") } label: {
                        Label("\(L10n.settings)…", systemImage: "gearshape")
                    }
                    Divider()
                    Button { openWindow(id: "conversion-log") } label: {
                        Label("\(L10n.conversionLog)…", systemImage: "text.alignleft")
                    }
                    Button { openWindow(id: "history") } label: {
                        Label("\(L10n.history)…", systemImage: "clock.arrow.circlepath")
                    }
                    Divider()
                    Button { model.openOutput() } label: {
                        Label("打开输出文件夹", systemImage: "folder")
                    }
                    Divider()
                    Menu {
                        Button("全部") { model.filter = .all }
                        Button("可转换") { model.filter = .convertible }
                        Button("不是实况") { model.filter = .unsupported }
                        Button("视频") { model.filter = .videos }
                        Button("其他照片") { model.filter = .other }
                    } label: {
                        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Divider()
                    Button { model.clearCompleted() } label: {
                        Label("清空已完成", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) { model.clearAll() } label: {
                        Label("清空列表", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("更多")
                .disabled(model.isConverting)
            }
        }
        .padding(.top, 14)
        .padding(.leading, 22)
        .padding(.trailing, 22)
        .padding(.bottom, 12)
        .background(WindowDragArea())
    }

    private var headerIcon: NSImage {
        let name = colorScheme == .dark ? "AppIconDark" : "AppIconLight"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = false
            return image
        }
        if let image = NSApp.applicationIconImage {
            image.isTemplate = false
            return image
        }
        return NSImage(size: NSSize(width: 1, height: 1))
    }

    // MARK: Drop zone

    private var dropZone: some View {
        let compact = !model.items.isEmpty
        return Button { model.chooseFiles() } label: {
            HStack(spacing: 16) {
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "photo.badge.plus")
                    .font(.system(size: compact ? 20 : 26, weight: .regular))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isTargeted ? "松开即可添加" : (compact ? "继续拖入照片或文件夹" : "把照片或文件夹拖到这里"))
                        .font(.system(size: compact ? 12.5 : 14, weight: .semibold))
                    if !compact {
                        Text("支持实况转换，以及照片、视频分类与时间修复")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text("选择…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: compact ? 58 : 92)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.22),
                                  style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            )
        }
        .buttonStyle(.plain)
        .help("点击选择照片，或把照片、文件夹拖到这里")
        .padding(.horizontal, 26)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 10)
            Image(nsImage: headerIcon)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                .padding(.bottom, 4)

            Text("还没有添加照片")
                .font(.system(size: 15, weight: .semibold))
            Text("拖入 OPPO / vivo 的实况原片，或点右上角「选择…」")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Feature(icon: "lock.shield", title: "本机处理", detail: "照片不上传")
                    .frame(maxWidth: .infinity)
                Feature(icon: "sparkles", title: "无损转换", detail: "静态图不重编码")
                    .frame(maxWidth: .infinity)
                Feature(icon: "rectangle.on.rectangle", title: "成对输出", detail: "JPG + MOV")
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 450)
            .padding(.top, 14)

            Text("转换后把成对的 JPG + MOV 一起拖进「照片」即可")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Item list

    private var itemList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("项目").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(model.items.count) 项")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if model.actionableCount > 0 {
                    Text("· \(model.actionableCount) 个待处理")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if model.summary != nil && !model.isConverting && !model.isImporting {
                    Button("全部删除", role: .destructive) { model.activeSheet = .deleteAll }
                        .buttonStyle(.borderless)
                        .disabled(model.isScanning)
                }
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 14)

            HStack {
                Spacer()
                Picker("", selection: $model.filter) {
                    Text("全部 \(model.items.count)").tag(ItemFilter.all)
                    Text("可转换 \(model.convertibleCount)").tag(ItemFilter.convertible)
                    Text("不是实况 \(model.unsupportedCount)").tag(ItemFilter.unsupported)
                    Text("视频 \(model.videoItems.count)").tag(ItemFilter.videos)
                    Text("其他照片 \(model.otherItems.count)").tag(ItemFilter.other)
                    if !model.failedItems.isEmpty {
                        Text("失败 \(model.failedItems.count)").tag(ItemFilter.failed)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: model.failedItems.isEmpty ? 650 : 760)
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if let notice = model.scanNotice {
                noticeBanner(notice)
            }

            if model.filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("这个筛选下没有照片")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filteredItems) { item in
                            SwipeRow(
                                onDelete: {
                                    model.requestDelete(item)
                                },
                                onTap: { model.rowTapped(item) }
                            ) {
                                FileRow(item: item, model: model)
                            }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 8)
                    .animation(.easeInOut(duration: 0.2), value: model.items.count)
                }
            }
        }
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("查看") { model.filter = .all }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
            Button {
                model.scanNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.10)))
        .padding(.horizontal, 26)
        .padding(.bottom, 8)
    }

    private var progressBar: some View {
        ProgressBar(value: model.isImporting
                    ? Double(model.importProgress) / Double(max(model.importTotal, 1))
                    : Double(model.progressDone) / Double(max(model.progressTotal, 1)))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("输出位置")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                    HStack(spacing: 5) {
                    Menu {
                            Button { model.setDestination(.photos) } label: {
                                Label("相册", systemImage: "photo.on.rectangle")
                            }
                            Button { model.setDestination(.folder) } label: {
                                Label("文件夹", systemImage: "folder")
                            }
                            Button { model.setDestination(.both) } label: {
                                Label("相册和文件夹", systemImage: "square.stack.3d.up")
                            }
                            if model.destination != .photos {
                                Divider()
                                Button { model.setFolderOutputMode(.batch) } label: {
                                    Label("保存到本批次实况文件夹", systemImage: "folder.badge.plus")
                                }
                                Button { model.chooseOutput() } label: {
                                    Label("自选输出文件夹…", systemImage: "folder.badge.gearshape")
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: model.destination == .photos
                                      ? "photo.on.rectangle" : "folder")
                                Text(model.destination.title)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8))
                            }
                            .font(.system(size: 11))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(model.isConverting || model.isImporting)

                        if model.destination != .photos {
                            Menu {
                                Button("本批次文件夹") { model.setFolderOutputMode(.batch) }
                                Button("自选路径…") { model.chooseOutput() }
                            } label: {
                                Text(model.folderOutputMode.title)
                                    .font(.system(size: 10.5))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(model.isConverting || model.isImporting)
                            if model.folderOutputMode == .custom {
                            Text(model.outputURL.path)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 200, alignment: .leading)
                            Button("更改…") { model.chooseOutput() }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .disabled(model.isConverting || model.isImporting)
                            }
                        }
                    }
                }

                Spacer(minLength: 8)

                Button(model.isConverting || model.lastConversionSummary == nil ? "转换日志" : "转换结果") {
                    openWindow(id: "conversion-log")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5, weight: .medium))

                Button { model.openResult() } label: {
                    Label(model.destination == .photos ? "打开照片" : "打开文件夹",
                          systemImage: model.destination == .photos
                          ? "photo.on.rectangle" : "folder")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.borderless)
                .disabled(model.destination == .photos
                          ? model.summary == nil
                          : model.lastOutputFolder == nil
                            && (model.folderOutputMode == .batch || !FileManager.default.fileExists(atPath: model.outputURL.path)))

                if model.isConverting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("转换中 \(model.progressDone)/\(model.progressTotal)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button("停止") { model.cancelConversion() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                } else if model.isImporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("导入相册 \(model.importProgress)/\(model.importTotal)")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Button {
                        model.startConversion()
                    } label: {
                        Text(model.convertibleItems.contains(where: { $0.status != .done }) ? "开始转换并分类" : "开始分类与修复")
                            .font(.system(size: 12.5, weight: .semibold))
                            .frame(width: 122, height: 32)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.items.isEmpty || model.actionableCount == 0)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 13)
        }
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if urls.isEmpty {
                model.errorMessage = "没有读到文件。请直接拖入照片或文件夹。"
            } else {
                model.add(urls: urls)
            }
        }
        return true
    }
}

private struct MainWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        MainWindowConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class MainWindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        AppDelegate.mainWindow = window
        AppDelegate.configureMainWindow(window)
    }
}

// MARK: - Swipe to delete

struct SwipeRow<Content: View>: View {
    let onDelete: () -> Void
    let onTap: () -> Void
    let content: Content

    @State private var offset: CGFloat = 0
    @State private var open = false

    init(onDelete: @escaping () -> Void, onTap: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDelete = onDelete
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    offset = 0
                    open = false
                }
                onDelete()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                    Text("删除")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(width: 76)
                .frame(maxHeight: .infinity)
                .background(Color.red)
            }
            .buttonStyle(.plain)
            .opacity(offset < -4 ? 1 : 0)

            content
                .offset(x: offset)
                .onTapGesture {
                    if open {
                        withAnimation(.easeOut(duration: 0.18)) {
                            offset = 0
                            open = false
                        }
                    } else {
                        onTap()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            let base: CGFloat = open ? -76 : 0
                            offset = max(-220, min(0, base + value.translation.width))
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                if offset < -150 {
                                    offset = 0
                                    open = false
                                    onDelete()
                                } else if offset < -35 {
                                    offset = -76
                                    open = true
                                } else {
                                    offset = 0
                                    open = false
                                }
                            }
                        }
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Row

struct FileRow: View {
    let item: PhotoItem
    @ObservedObject var model: AppModel

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            ThumbnailView(url: item.url)
                .frame(width: 44, height: 44)
                .grayscale(item.isConvertible ? 0 : 1)
                .opacity(item.isConvertible ? 1 : 0.55)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(item.isConvertible ? Color.primary : Color.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if item.isConvertible {
                        Text(item.liveType)
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(brandColor.opacity(0.13)))
                            .foregroundStyle(brandColor)
                        Text(item.kind.label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        if let date = DateText.short(item.captureDate) {
                            Text("· \(date)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(item.kind.label)
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.13)))
                            .foregroundStyle(.orange)
                        Text(item.reason ?? "没有找到动态视频")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let date = DateText.short(item.captureDate) {
                            Text("· \(date)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if let hdr = item.hdr, hdr != "SDR" {
                        Text("HDR")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if !item.deviceModel.isEmpty {
                    Text(item.deviceModel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                if let location = item.locationName {
                    HStack(spacing: 3) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                        Text(location)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                } else if item.gpsLat != nil {
                    Text(item.locationFinished
                         ? String(format: "%.4f, %.4f", item.gpsLat ?? 0, item.gpsLon ?? 0)
                         : "定位中…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help(item.locationFinished ? "地址查询暂不可用，已保留原始经纬度。可在设置中重试。" : "正在查询地址")
                }
            }
            .frame(maxWidth: 240, alignment: .trailing)

            statusView
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
                .padding(.leading, 72)
        }
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
    }

    private var brandColor: Color {
        switch item.liveType {
        case "Apple 实况": return .blue
        case "vivo 实况": return .indigo
        case "OPPO 实况": return .green
        case "小米实况": return .orange
        case "华为实况", "荣耀实况": return .red
        case "三星实况": return .cyan
        default: return .secondary
        }
    }

    @ViewBuilder private var statusView: some View {
        switch item.status {
        case .pending:
            Text("待转换")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("转换中")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .done:
            Label("完成", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        case .failed:
            HStack(spacing: 6) {
                Label("失败", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                Button("详情") { model.activeSheet = .failureDetail(item) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .unsupported:
            Label("待分类", systemImage: "tray")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var contextMenu: some View {
        if item.isConvertible {
            if case .done = item.status, let out = item.outputJPG {
                Button { model.activeSheet = .openWith(item) } label: {
                    Label("打开方式…", systemImage: "arrow.up.right.square")
                }
                Button { model.reveal(item) } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                Divider()
                Button { model.copyUUID(item) } label: {
                    Label("拷贝 UUID", systemImage: "number")
                }
                ShareLink(item: out) {
                    Label("分享…", systemImage: "square.and.arrow.up")
                }
                Divider()
            } else {
                Button { model.reveal(item) } label: {
                    Label("在 Finder 中显示", systemImage: "folder")
                }
                if case .failed = item.status {
                    Button { model.activeSheet = .failureDetail(item) } label: {
                        Label("错误日志…", systemImage: "exclamationmark.triangle")
                    }
                }
                Divider()
            }

            Button { model.reconvert(item) } label: {
                Label("重新转换", systemImage: "arrow.clockwise")
            }
            Button { model.activeSheet = .info(item) } label: {
                Label("显示简介", systemImage: "info.circle")
            }
            Menu {
                Button("文件名") { model.copyName(item) }
                Button("路径") { model.copyPath(item) }
                if item.uuid != nil {
                    Button("UUID") { model.copyUUID(item) }
                }
            } label: {
                Label("拷贝", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) { model.requestDelete(item) } label: {
                Label("删除记录", systemImage: "trash")
            }
        } else {
            Button { model.activeSheet = .info(item) } label: {
                Label("为什么不是实况？", systemImage: "questionmark.circle")
            }
            Button { model.reveal(item) } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            Divider()
            Menu {
                Button("文件名") { model.copyName(item) }
                Button("路径") { model.copyPath(item) }
            } label: {
                Label("拷贝", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) { model.requestDelete(item) } label: {
                Label("删除记录", systemImage: "trash")
            }
        }
    }
}

// MARK: - Sheets

struct UnsupportedSheet: View {
    @ObservedObject var model: AppModel
    var useLastResults = false
    @Environment(\.dismiss) private var dismiss

    private var displayedItems: [PhotoItem] {
        useLastResults ? model.lastUnsupportedItems : model.unsupportedItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(displayedItems.count) 张不是实况")
                        .font(.system(size: 14, weight: .semibold))
                    Text("这些照片未发现动态视频。处理完成后会归档，并按可读取的拍摄时间修复文件日期。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedItems) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "photo")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text(item.reason ?? "没有找到动态视频")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("显示") { model.reveal(item) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        Divider().opacity(0.4)
                    }
                }
            }

            Divider()

            HStack {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting(displayedItems.map(\.url))
                }
                    .buttonStyle(.borderless)
                Spacer()
                Button("好") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
    }
}

struct OpenWithSheet: View {
    @ObservedObject var model: AppModel
    let item: PhotoItem
    @Environment(\.dismiss) private var dismiss

    enum Target: String, CaseIterable {
        case jpg
        case mov
    }

    @State private var target: Target = .jpg
    @State private var apps: [URL] = []

    private var url: URL {
        switch target {
        case .jpg: return item.outputJPG ?? item.url
        case .mov: return item.outputMOV ?? item.outputJPG ?? item.url
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ThumbnailView(url: item.url)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("打开方式")
                        .font(.system(size: 13, weight: .semibold))
                    Text(item.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(16)

            if item.outputMOV != nil {
                Picker("", selection: $target) {
                    Text("封面 JPG").tag(Target.jpg)
                    Text("动态 MOV").tag(Target.mov)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .onChange(of: target) { _ in
                    apps = model.applications(for: url)
                }
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    appRow(name: "默认应用",
                           icon: defaultIcon,
                           app: nil)
                    ForEach(apps, id: \.self) { app in
                        appRow(name: app.deletingPathExtension().lastPathComponent,
                               icon: NSWorkspace.shared.icon(forFile: app.path),
                               app: app)
                    }
                }
            }

            Divider()

            HStack {
                Button("在 Finder 中显示") {
                    model.reveal(item)
                    dismiss()
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 460, height: 500)
        .onAppear {
            if item.outputJPG == nil && item.outputMOV != nil {
                target = .mov
            }
            apps = model.applications(for: url)
        }
    }

    private var defaultIcon: NSImage {
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            return NSWorkspace.shared.icon(forFile: app.path)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func appRow(name: String, icon: NSImage, app: URL?) -> some View {
        Button {
            model.open(url: url, with: app)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Components

struct Feature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(width: 140)
    }
}

struct ThumbnailView: View {
    let url: URL
    var size: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .onAppear {
            image = ThumbnailCache.shared.image(for: url, size: size)
        }
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func cgImage(for url: URL, size: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(size * 2)
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    func image(for url: URL, size: CGFloat) -> NSImage? {
        let key = "\(url.path)#\(Int(size))" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let cg = cgImage(for: url, size: size) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: size, height: size))
        cache.setObject(img, forKey: key)
        return img
    }
}

final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 5)
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.25), value: value)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isEnabled
                          ? Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1.0)
                          : Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.95 : 1.0)
    }
}

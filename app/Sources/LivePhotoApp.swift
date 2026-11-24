import SwiftUI
import AppKit
import Combine

@main
struct LivePhotoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    private let auto = AutoRunner()

    var body: some Scene {
        Window(L10n.appName, id: "main") {
            ContentView(model: model)
                .onAppear {
                    let args = CommandLine.arguments
                    if args.contains("--auto") {
                        auto.start(model: model)
                        return
                    }
                    if args.contains("--demo") {
                        model.loadDemo()
                    } else if args.contains("--demo-sheet") {
                        model.loadDemo()
                        model.isConverting = false
                        model.summary = "成功 1 张 · 2 张不是实况"
                        model.activeSheet = .unsupported
                    } else if args.contains("--demo-fail") {
                        model.loadDemo()
                        model.isConverting = false
                        if let i = model.items.firstIndex(where: { $0.name == "IMG_6519.jpg" }) {
                            model.items[i].status = .failed("Exif 里没有 MakerNote 入口，无法无损写入")
                            model.items[i].failureLog = """
                            Traceback (most recent call last):
                              File "android2apple.py", line 220, in patch_still
                                return add_makernote(still, value)
                              File "android2apple.py", line 178, in add_makernote
                                raise RuntimeError("Exif 里没有 ExifIFD")
                            RuntimeError: Exif 里没有 MakerNote 入口，无法无损写入
                            """
                        }
                        model.activeSheet = .failures
                    } else if args.contains("--demo-failmain") {
                        model.loadDemo()
                        model.isConverting = false
                        if let i = model.items.firstIndex(where: { $0.name == "IMG_6519.jpg" }) {
                            model.items[i].status = .failed("Exif 里没有 MakerNote 入口，无法无损写入")
                            model.items[i].failureLog = "RuntimeError: Exif 里没有 MakerNote 入口，无法无损写入"
                        }
                    } else if args.contains("--demo-settings") {
                        model.loadDemo()
                    } else if args.contains("--demo-delete") {
                        model.loadDemo()
                        if let i = model.items.firstIndex(where: { $0.status == .done }) {
                            model.items[i].outputJPG = URL(fileURLWithPath: "/tmp/4055_out/IMG_4055.jpg")
                            model.items[i].outputMOV = URL(fileURLWithPath: "/tmp/4055_out/IMG_4055.mov")
                            model.activeSheet = .delete(model.items[i])
                        }
                    } else if args.contains("--demo-history") {
                        if model.history.isEmpty {
                            model.history = [
                                HistoryEntry(date: Date().addingTimeInterval(-240), name: "IMG_6519.jpg",
                                             status: "成功", device: "Apple iPhone 13 Pro",
                                             uuid: "30301D07-5483-4E91-9D25-D187B461400C",
                                             outputJPG: "/tmp/a.jpg", outputMOV: "/tmp/a.mov", error: nil),
                                HistoryEntry(date: Date().addingTimeInterval(-900), name: "IMG_20261024_192249.jpg",
                                             status: "成功", device: "vivo X200 Pro",
                                             uuid: "8D14C3E2-7A12-4E18-9B7F-2A55E4E4B1C8",
                                             outputJPG: "/tmp/b.jpg", outputMOV: "/tmp/b.mov", error: nil),
                                HistoryEntry(date: Date().addingTimeInterval(-3600), name: "IMG_5970.jpg",
                                             status: "失败", device: "Apple iPhone 13 Pro",
                                             uuid: nil, outputJPG: nil, outputMOV: nil,
                                             error: "Exif 里没有 MakerNote 入口，无法无损写入"),
                                HistoryEntry(date: Date().addingTimeInterval(-7200), name: "IMG_9001.jpg",
                                             status: "跳过", device: "",
                                             uuid: nil, outputJPG: nil, outputMOV: nil,
                                             error: "没有找到动态视频")
                            ]
                        }
                    } else if args.contains("--demo-log") {
                        model.loadDemo()
                        model.conversionLog = [
                            "[23:40:01] 开始转换 3 张",
                            "[23:40:01] 共 3 张",
                            "[23:40:01] → IMG_6519.jpg",
                            "[23:40:02] ✓ IMG_6519.jpg",
                            "[23:40:02] → IMG_6530.jpg",
                            "[23:40:03] ✓ IMG_6530.jpg",
                            "[23:40:03] → IMG_20261024_192249.jpg",
                            "[23:40:04] ✗ IMG_20261024_192249.jpg：Exif 里没有 MakerNote 入口，无法无损写入",
                            "[23:40:04] 可能原因：原图的 Exif 被换机工具改写过，MakerNote / ExifIFD 不完整。新版会自动补；仍失败说明这张图的 Exif 结构不标准，建议用原图或重新导出后再试。",
                            "[23:40:04] 程序输出：",
                            "    Traceback (most recent call last):",
                            "      File \"android2apple.py\", line 220, in patch_still",
                            "        return add_makernote(still, value)",
                            "      File \"android2apple.py\", line 178, in add_makernote",
                            "        raise RuntimeError(\"Exif 里没有 ExifIFD\")",
                            "    RuntimeError: Exif 里没有 MakerNote 入口，无法无损写入",
                            "[23:40:04] 完成：成功 2 / 失败 1 / 跳过 0"
                        ]
                    } else if args.contains("--demo-info") {
                        model.loadDemo()
                        model.isConverting = false
                        let url = URL(fileURLWithPath: "/tmp/demo/IMG_0001.jpg")
                        if FileManager.default.fileExists(atPath: url.path) {
                            var item = PhotoItem(url: url, name: "IMG_0001.jpg", kind: .embedded,
                                                 make: "OPPO", videoName: nil)
                            item.captureDate = "2026:01:01 12:00:00+08:00"
                            item.model = "OPPO Find X8"
                            item.gpsLat = 39.9042
                            item.gpsLon = 116.4074
                            item.locationName = "北京市东城区"
                            item.status = .done
                            item.uuid = "30301D07-5483-4E91-9D25-D187B461400C"
                            item.outputJPG = URL(fileURLWithPath: "/tmp/demo_out/IMG_0001.jpg")
                            item.outputMOV = URL(fileURLWithPath: "/tmp/demo_out/IMG_0001.mov")
                            model.items.insert(item, at: 0)
                            model.activeSheet = .info(item)
                        }
                    } else if args.contains("--demo-open") {
                        model.loadDemo()
                        model.isConverting = false
                        model.summary = "成功 1 张 · 2 张不是实况"
                        if let i = model.items.firstIndex(where: { $0.name == "IMG_0001.jpg" }) {
                            model.items[i].outputJPG = URL(fileURLWithPath: "/tmp/demo_out/IMG_0001.jpg")
                            model.items[i].outputMOV = URL(fileURLWithPath: "/tmp/demo_out/IMG_0001.mov")
                        }
                        if let item = model.items.first(where: { $0.status == .done }) {
                            model.activeSheet = .openWith(item)
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1060, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            ResultsCommands(model: model)
        }

        Window(L10n.conversionLog, id: "conversion-log") {
            ConversionLogView(model: model)
        }
        .defaultSize(width: 620, height: 420)

        Window(L10n.history, id: "history") {
            HistoryView(model: model)
        }
        .defaultSize(width: 840, height: 480)

        Window(L10n.settings, id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 560, height: 470)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Offscreen AppKit snapshot of the SwiftUI view (renders SF Symbols and controls
/// correctly, unlike ImageRenderer).
enum SnapshotRenderer {
    static var window: NSWindow?

    static func render(model: AppModel, to path: String) {
        let view = NSHostingView(rootView: ContentView(model: model, forSnapshot: true))
        view.frame = NSRect(x: 0, y: 0, width: 1060, height: 720)

        let win = NSWindow(contentRect: view.frame,
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        win.contentView = view
        win.appearance = NSApp.appearance
        win.orderFront(nil)
        window = win

        view.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}


/// Headless-ish end-to-end test: scan a folder, convert, write a result JSON, quit.
final class AutoRunner {
    private var started = false
    private var finished = false
    private var cancellables = Set<AnyCancellable>()
    private var outputPath = "/tmp/livephoto_app_out"

    func start(model: AppModel) {
        guard !started else { return }
        started = true

        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--auto"), i + 1 < args.count else {
            finish(model: model, extra: ["error": "missing input"])
            return
        }
        let input = args[i + 1]
        if let j = args.firstIndex(of: "--out"), j + 1 < args.count {
            outputPath = args[j + 1]
        }
        model.outputURL = URL(fileURLWithPath: outputPath)
        model.folderOutputMode = .custom

        model.$isScanning
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] scanning in
                guard let self = self, !scanning, !self.finished else { return }
                if model.items.isEmpty {
                    self.finish(model: model, extra: ["error": "no convertible photos"])
                } else {
                    model.startConversion()
                }
            }
            .store(in: &cancellables)

        model.$isConverting
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] converting in
                guard let self = self, !converting, !self.finished else { return }
                if model.summary != nil {
                    self.finish(model: model, extra: [:])
                }
            }
            .store(in: &cancellables)

        model.add(urls: [URL(fileURLWithPath: input)])
    }

    private func finish(model: AppModel, extra: [String: Any]) {
        guard !finished else { return }
        finished = true
        var dict: [String: Any] = [
            "summary": model.summary ?? "",
            "output": outputPath,
            "items": model.items.map { item -> [String: Any] in
                var status = "pending"
                switch item.status {
                case .pending: status = "pending"
                case .running: status = "running"
                case .done: status = "done"
                case .failed(let e): status = "failed: \(e)"
                case .unsupported(let e): status = "unsupported: \(e)"
                }
                return ["name": item.name, "status": status, "uuid": item.uuid ?? ""]
            }
        ]
        for (k, v) in extra { dict[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/livephoto_app_result.json"))
        }
        exit(0)
    }
}


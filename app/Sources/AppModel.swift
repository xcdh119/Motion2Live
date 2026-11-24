import Foundation
import SwiftUI
import AppKit
import Combine
import ImageIO
import Darwin

extension Notification.Name {
    static let openConversionLogWindow = Notification.Name("openConversionLogWindow")
}

private final class ProcessErrorCapture {
    let pipe = Pipe()
    private let lock = NSLock()
    private var data = Data()

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self = self else {
                handle.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.data.append(chunk)
            self.lock.unlock()
        }
    }

    func finish() -> String {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        let remaining = handle.readDataToEndOfFile()
        lock.lock()
        data.append(remaining)
        let result = String(data: data, encoding: .utf8) ?? ""
        lock.unlock()
        return result
    }
}

// MARK: - Paths

enum AppPaths {
    static var resourceDir: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: Bundle.main.bundlePath)
    }

    static var script: URL { resourceDir.appendingPathComponent("android2apple.py") }
    static var exiftool: URL { resourceDir.appendingPathComponent("exiftool/exiftool") }

    static var python3: String? {
        let candidates = [
            "/Library/Developer/CommandLineTools/usr/bin/python3",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/opt/local/bin/python3",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") ? "/usr/bin/python3" : nil
    }

    static var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ffprobe: String? {
        guard let f = ffmpeg else { return nil }
        let p = URL(fileURLWithPath: f).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        if FileManager.default.isExecutableFile(atPath: exiftool.path) {
            env["EXIFTOOL"] = exiftool.path
        }
        if let f = ffmpeg { env["FFMPEG"] = f }
        if let p = ffprobe { env["FFPROBE"] = p }
        return env
    }
}

// MARK: - Model

enum ItemKind: String {
    case embedded
    case paired
    case none
    case video
    case other

    var label: String {
        switch self {
        case .embedded: return "单文件内嵌视频"
        case .paired: return "JPEG + 视频"
        case .none: return "不是实况"
        case .video: return "视频"
        case .other: return "其他照片"
        }
    }

    var isConvertible: Bool { self == .embedded || self == .paired }
}

enum ItemStatus: Equatable {
    case pending
    case running
    case done
    case failed(String)
    case unsupported(String)
}

enum ItemFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case convertible
    case unsupported
    case videos
    case other
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .convertible: return "可转换"
        case .unsupported: return "不是实况"
        case .videos: return "视频"
        case .other: return "其他照片"
        case .failed: return "失败"
        }
    }
}

enum ConversionResultSheet: String, Identifiable {
    case unsupported, missingDates
    var id: String { rawValue }
}

enum AppSheet: Identifiable {
    case openWith(PhotoItem)
    case unsupported
    case info(PhotoItem)
    case failures
    case failureDetail(PhotoItem)
    case delete(PhotoItem)
    case deleteAll

    var id: String {
        switch self {
        case .openWith(let item): return "open-\(item.id.uuidString)"
        case .unsupported: return "unsupported"
        case .info(let item): return "info-\(item.id.uuidString)"
        case .failures: return "failures"
        case .failureDetail(let item): return "failure-\(item.id.uuidString)"
        case .delete(let item): return "delete-\(item.id.uuidString)"
        case .deleteAll: return "delete-all"
        }
    }
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var name: String
    var status: String
    var device: String
    var uuid: String?
    var outputJPG: String?
    var outputMOV: String?
    var error: String?
}

enum OutputDestination: String, CaseIterable, Identifiable {
    case photos
    case folder
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: return "相册"
        case .folder: return "文件夹"
        case .both: return "相册和文件夹"
        }
    }
}

enum FolderOutputMode: String, CaseIterable, Identifiable {
    case batch
    case custom
    var id: String { rawValue }
    var title: String { self == .batch ? "本批次文件夹" : "自选路径" }
}

struct PhotoItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    let name: String
    var kind: ItemKind
    let make: String
    var videoName: String?
    var companionVideoNames: [String] = []
    var status: ItemStatus = .pending
    var uuid: String?
    var outputJPG: URL?
    var outputMOV: URL?
    var reason: String?
    var captureDate: String?
    var failureLog: String?
    var hdr: String?
    var model: String?
    var gpsLat: Double?
    var gpsLon: Double?
    var locationName: String?
    var locationRequested = false
    var locationFinished = false

    var isConvertible: Bool { kind.isConvertible }

    var deviceModel: String {
        let name = (model ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return make.isEmpty ? "" : brand }
        if !make.isEmpty && !name.lowercased().contains(make.lowercased()) {
            return "\(make) \(name)"
        }
        return name
    }

    var liveType: String {
        let m = make.uppercased()
        if m.contains("APPLE") { return "Apple 实况" }
        if m.contains("VIVO") { return "vivo 实况" }
        if m.contains("OPPO") { return "OPPO 实况" }
        if m.contains("ONEPLUS") { return "OnePlus 实况" }
        if m.contains("XIAOMI") || m.contains("REDMI") { return "小米实况" }
        if m.contains("HONOR") { return "荣耀实况" }
        if m.contains("HUAWEI") { return "华为实况" }
        if m.contains("SAMSUNG") { return "三星实况" }
        return "实况"
    }

    var brand: String {
        let m = make.uppercased()
        if m.contains("APPLE") { return "iPhone" }
        if m.contains("VIVO") { return "vivo" }
        if m.contains("OPPO") { return "OPPO" }
        if m.contains("ONEPLUS") { return "OnePlus" }
        if m.contains("XIAOMI") || m.contains("REDMI") { return "小米" }
        if m.contains("HONOR") { return "荣耀" }
        if m.contains("HUAWEI") { return "华为" }
        if m.contains("SAMSUNG") { return "三星" }
        return "实况"
    }
}

// MARK: - App model

final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var items: [PhotoItem] = []
    @Published var filter: ItemFilter = .all
    @Published var isScanning = false
    @Published var isConverting = false
    @Published var progressDone = 0
    @Published var progressTotal = 0
    @Published var summary: String?
    @Published var scanNotice: String?
    @Published var errorMessage: String?
    @Published var outputURL: URL
    @Published var lastOutputFolder: URL?
    @Published var folderOutputMode: FolderOutputMode
    @Published var destination: OutputDestination
    @Published var isImporting = false
    @Published var importProgress = 0
    @Published var importTotal = 0
    @Published var activeSheet: AppSheet?
    @Published var conversionLog: [String] = []
    @Published var history: [HistoryEntry] = []
    @Published var fixedWorkspaceEnabled = UserDefaults.standard.bool(forKey: "fixedWorkspaceEnabled")
    @Published var fixedWorkspacePath = UserDefaults.standard.string(forKey: "fixedWorkspacePath") ?? ""
    @Published var workspaceScanDate: Date?
    @Published var workspaceRefreshRequested = false
    @Published private(set) var missingDateItems: [PhotoItem] = []
    @Published var conversionResultSheet: ConversionResultSheet?
    @Published private(set) var lastUnsupportedItems: [PhotoItem] = []
    @Published var pendingTimeRepair: [PhotoItem]?

    func markDatesRepaired(_ urls: Set<URL>) {
        missingDateItems.removeAll { urls.contains(($0.outputJPG ?? $0.url).standardizedFileURL) }
    }
    @Published private(set) var lastConversionSummary: String?

    private let workQueue = DispatchQueue(label: "com.xcdh.livephoto.convert")
    private var currentProcess: Process?
    private var sawDone = false
    private var conversionOutputURL: URL?
    private var conversionDestination: OutputDestination = .folder
    private var conversionUsesBatchOutput = false
    private var activeConversionID: UUID?
    private var cancelledConversionID: UUID?
    private var conversionItemPaths = Set<String>()
    private var workspaceWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var workspaceScanWorkItem: DispatchWorkItem?
    private var confirmWorkspaceRefresh = false
    private var noticedWorkspacePaths = Set<String>()

    init() {
        Self.migrateDefaultsIfNeeded()
        let def = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/光影间")
        if let s = UserDefaults.standard.string(forKey: "outputPath"), !s.isEmpty {
            outputURL = URL(fileURLWithPath: s)
        } else {
            outputURL = def
        }
        if let raw = UserDefaults.standard.string(forKey: "destination"),
           let saved = OutputDestination(rawValue: raw) {
            destination = saved
        } else {
            destination = .folder
        }
        folderOutputMode = FolderOutputMode(rawValue: UserDefaults.standard.string(forKey: "folderOutputMode") ?? "") ?? .batch
        loadHistory()
    }

    private static func migrateDefaultsIfNeeded() {
        let new = UserDefaults.standard
        guard !new.bool(forKey: "didMigrateBundleIDToLumina") else { return }
        let keys = ["outputPath", "destination", "deleteFilesOnRemove",
                    "confirmBeforeDelete", "deleteConfirmationDone",
                    "showConversionLog", "openOutputAfterConversion",
                    "conversionHistory"]
        if let old = UserDefaults(suiteName: "com.xcdh.livephotoconverter") {
            for key in keys where new.object(forKey: key) == nil {
                if let value = old.object(forKey: key) {
                    new.set(value, forKey: key)
                }
            }
        }
        new.set(true, forKey: "didMigrateBundleIDToLumina")
    }

    // MARK: Computed

    var convertibleItems: [PhotoItem] {
        items.filter { $0.kind.isConvertible }
    }

    var unsupportedItems: [PhotoItem] {
        items.filter { $0.kind == .none }
    }
    var videoItems: [PhotoItem] { items.filter { $0.kind == .video } }
    var otherItems: [PhotoItem] { items.filter { $0.kind == .other } }

    var convertibleCount: Int { convertibleItems.count }
    var unsupportedCount: Int { unsupportedItems.count }

    var failedItems: [PhotoItem] {
        items.filter {
            if case .failed = $0.status { return true }
            return false
        }
    }

    var actionableCount: Int {
        items.filter { item in
            item.status != .done
        }.count
    }

    var filteredItems: [PhotoItem] {
        switch filter {
        case .all: return items
        case .convertible: return convertibleItems
        case .unsupported: return unsupportedItems
        case .videos: return videoItems
        case .other: return otherItems
        case .failed: return failedItems
        }
    }

    // MARK: Preflight

    private func scanPreflight() -> String? {
        if AppPaths.python3 == nil {
            return "系统里没有找到 python3。请先在终端运行：xcode-select --install"
        }
        if !FileManager.default.fileExists(atPath: AppPaths.script.path) {
            return "App 内置的转换脚本缺失，请重新构建 App。"
        }
        return nil
    }

    private func convertPreflight() -> String? {
        if let message = scanPreflight() { return message }
        if AppPaths.ffmpeg == nil {
            return "没有找到 ffmpeg。请先在终端运行：brew install ffmpeg，然后重新打开 App。"
        }
        return nil
    }

    // MARK: Scan

    func add(urls: [URL]) {
        scan(urls: urls, workspacePath: nil)
    }

    private func scan(urls: [URL], workspacePath: String?, previewOnly: Bool = false) {
        guard !urls.isEmpty, !isScanning, !isConverting, !isImporting else { return }
        if let message = scanPreflight() {
            errorMessage = message
            return
        }
        isScanning = true
        if !previewOnly { errorMessage = nil }
        let pendingURLs = previewOnly ? [] : items.filter { $0.status != .done }.map { $0.url }
        let paths = Array(Set((urls + pendingURLs).map { $0.path })).sorted()

        workQueue.async { [weak self] in
            guard let self = self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: AppPaths.python3 ?? "/usr/bin/python3")
            p.arguments = [AppPaths.script.path, "--scan"] + paths
            p.environment = AppPaths.environment()

            let out = Pipe()
            let errorCapture = ProcessErrorCapture()
            p.standardOutput = out
            p.standardError = errorCapture.pipe
            errorCapture.start()

            var newItems: [PhotoItem] = []
            var failure: String?

            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let errText = errorCapture.finish()
                let text = String(data: data, encoding: .utf8) ?? ""

                for line in text.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let type = obj["type"] as? String, type == "scan",
                          let path = obj["path"] as? String,
                          let name = obj["name"] as? String,
                          let kindRaw = obj["kind"] as? String,
                          let kind = ItemKind(rawValue: kindRaw) else { continue }

                    var item = PhotoItem(url: URL(fileURLWithPath: path),
                                         name: name,
                                         kind: kind,
                                         make: (obj["make"] as? String) ?? "",
                                         videoName: obj["video"] as? String)
                    item.companionVideoNames = obj["companion_videos"] as? [String] ?? []
                    let reason = (obj["reason"] as? String) ?? ""
                    item.reason = reason.isEmpty ? nil : reason
                    if obj["date_source"] as? String == "filename" {
                        item.reason = reason + "（时间来自文件名，非拍摄元数据）"
                    }
                    item.captureDate = obj["date"] as? String
                    item.hdr = obj["hdr"] as? String
                    item.model = obj["model"] as? String
                    item.gpsLat = (obj["gps_lat"] as? NSNumber)?.doubleValue
                    item.gpsLon = (obj["gps_lon"] as? NSNumber)?.doubleValue
                    if !kind.isConvertible {
                        item.status = .unsupported(reason.isEmpty ? "没有找到动态视频" : reason)
                    }
                    newItems.append(item)
                }

                if p.terminationStatus != 0 && newItems.isEmpty {
                    failure = errText.isEmpty ? "扫描失败（退出码 \(p.terminationStatus)）" : errText
                }
            } catch {
                failure = "无法启动转换脚本：\(error.localizedDescription)"
            }

            DispatchQueue.main.async {
                self.isScanning = false
                if let workspacePath,
                   !self.fixedWorkspaceEnabled || self.fixedWorkspacePath != workspacePath { return }
                if previewOnly {
                    guard failure == nil else { return }
                    let known = Set(self.items.flatMap { [$0.url, $0.outputJPG, $0.outputMOV].compactMap { $0?.path } })
                    let fresh = Set(newItems.filter { $0.isConvertible }.map { $0.url.path })
                        .subtracting(known).subtracting(self.noticedWorkspacePaths)
                    if !fresh.isEmpty {
                        self.noticedWorkspacePaths.formUnion(fresh)
                        self.workspaceRefreshRequested = true
                    }
                    return
                }
                if let failure = failure {
                    self.errorMessage = failure
                    return
                }
                guard !newItems.isEmpty else {
                    if workspacePath != nil {
                        self.workspaceScanDate = Date()
                        return
                    }
                    self.errorMessage = "没有找到支持的照片或视频。\n可添加 JPEG、HEIC、PNG 等图片、视频或文件夹。"
                    return
                }

                let refreshedPaths = Set(newItems.map { $0.url.path })
                let pairingItems = self.items.filter { !refreshedPaths.contains($0.url.path) } + newItems
                let linkedPaths = Set(pairingItems.filter { $0.isConvertible }.flatMap {
                    SourceFiles.originals(photo: $0.url, videoName: $0.videoName,
                                          companionVideoNames: $0.companionVideoNames).dropFirst().map { $0.standardizedFileURL.path }
                })
                self.items.removeAll { $0.kind == .video && linkedPaths.contains($0.url.standardizedFileURL.path) }
                var added = 0
                var updated = false
                for item in newItems {
                    if item.kind == .video && linkedPaths.contains(item.url.standardizedFileURL.path) { continue }
                    if let index = self.items.firstIndex(where: { $0.url.path == item.url.path }) {
                        guard self.items[index].status != .done else { continue }
                        let changed = self.items[index].kind != item.kind || self.items[index].videoName != item.videoName || self.items[index].companionVideoNames != item.companionVideoNames
                        if changed {
                            self.items[index].kind = item.kind
                            self.items[index].videoName = item.videoName
                            self.items[index].companionVideoNames = item.companionVideoNames
                            if case .failed = self.items[index].status {
                                // A refresh does not retry failed conversions.
                            } else {
                                self.items[index].status = item.status
                                self.items[index].reason = item.reason
                            }
                            updated = true
                        }
                    } else {
                        self.items.append(item)
                        added += 1
                    }
                }
                self.sortItems()

                if workspacePath != nil {
                    self.workspaceScanDate = Date()
                    guard added > 0 || updated else { return }
                } else if added == 0 && !updated {
                    self.errorMessage = "这些照片已经在列表里了。"
                }

                self.scanNotice = "共 \(self.items.count) 项：实况 \(self.convertibleCount)、视频 \(self.videoItems.count)、非实况照片 \(self.unsupportedCount)、其他照片 \(self.otherItems.count)。开始处理后统一归类，有拍摄日期的文件会修复文件时间。"
                if workspacePath == nil { self.filter = .all }
                self.summary = nil
                self.resolveLocations()
            }
        }
    }

    func setFixedWorkspaceEnabled(_ enabled: Bool) {
        fixedWorkspaceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "fixedWorkspaceEnabled")
        updateWorkspaceMonitoring()
    }

    func chooseFixedWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择来源文件夹"
        panel.message = "自动扫描并分类此文件夹中的照片和视频"
        if panel.runModal() == .OK, let url = panel.url {
            fixedWorkspacePath = url.path
            fixedWorkspaceEnabled = true
            UserDefaults.standard.set(url.path, forKey: "fixedWorkspacePath")
            UserDefaults.standard.set(true, forKey: "fixedWorkspaceEnabled")
            updateWorkspaceMonitoring()
        }
    }

    func updateWorkspaceMonitoring() {
        stopWorkspaceMonitoring()
        workspaceRefreshRequested = false
        noticedWorkspacePaths.removeAll()
        guard fixedWorkspaceEnabled, !fixedWorkspacePath.isEmpty else { return }
        let url = URL(fileURLWithPath: fixedWorkspacePath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            errorMessage = "无法访问固定工作区：\(error.localizedDescription)"
            return
        }
        refreshWorkspaceWatchers()
        guard !workspaceWatchers.isEmpty else {
            errorMessage = "无法监视固定工作区，请重新选择文件夹。"
            return
        }
        scanWorkspace()
    }

    private func stopWorkspaceMonitoring() {
        workspaceScanWorkItem?.cancel()
        workspaceScanWorkItem = nil
        workspaceWatchers.values.forEach { $0.cancel() }
        workspaceWatchers.removeAll()
    }

    private func refreshWorkspaceWatchers() {
        guard fixedWorkspaceEnabled, !fixedWorkspacePath.isEmpty else { return }
        let root = URL(fileURLWithPath: fixedWorkspacePath, isDirectory: true)
        var directories = Set([root.path])
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let child as URL in enumerator {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    directories.insert(child.path)
                }
            }
        }

        for path in Array(workspaceWatchers.keys) where !directories.contains(path) {
            workspaceWatchers.removeValue(forKey: path)?.cancel()
        }
        for path in directories where workspaceWatchers[path] == nil {
            let descriptor = path.withCString { Darwin.open($0, O_EVTONLY) }
            guard descriptor >= 0 else { continue }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .link],
                queue: .main
            )
            watcher.setEventHandler { [weak self] in
                self?.refreshWorkspaceWatchers()
                self?.scheduleWorkspaceScan()
            }
            watcher.setCancelHandler { close(descriptor) }
            workspaceWatchers[path] = watcher
            watcher.resume()
        }
    }

    private func scheduleWorkspaceScan() {
        workspaceScanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanWorkspace(automatic: true) }
        workspaceScanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func scanWorkspace(automatic: Bool = false) {
        guard fixedWorkspaceEnabled, !fixedWorkspacePath.isEmpty else { return }
        if isScanning || isConverting || isImporting {
            scheduleWorkspaceScan()
            return
        }
        if !automatic { workspaceRefreshRequested = false }
        scan(urls: [URL(fileURLWithPath: fixedWorkspacePath, isDirectory: true)],
             workspacePath: fixedWorkspacePath, previewOnly: automatic && confirmWorkspaceRefresh)
    }

    func chooseSingleLivePhoto() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加实况"
        panel.message = "选择一张实况照片，应用会自动查找同名配对视频"
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    private func resolveLocations() {
        for index in items.indices {
            let item = items[index]
            guard !item.locationRequested, item.locationName == nil,
                  let lat = item.gpsLat, let lon = item.gpsLon else { continue }
            items[index].locationRequested = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self = self,
                      let index = self.items.firstIndex(where: { $0.id == item.id }),
                      self.items[index].locationName == nil else { return }
                self.items[index].locationFinished = true
            }
            LocationGeocoder.shared.resolve(lat: lat, lon: lon) { [weak self] name in
                guard let self = self else { return }
                if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[index].locationName = name
                    self.items[index].locationFinished = true
                }
            }
        }
    }

    func retryLocations() {
        for i in items.indices where items[i].locationName == nil && items[i].locationFinished {
            items[i].locationRequested = false
            items[i].locationFinished = false
        }
        resolveLocations()
    }

    private func sortItems() {
        items.sort { a, b in
            if a.kind.isConvertible != b.kind.isConvertible {
                return a.kind.isConvertible
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Convert

    func startConversion() {
        let workItems = convertibleItems.filter { $0.status != .done }
        startConversion(items: workItems)
    }

    func startConversion(items workItems: [PhotoItem]) {
        guard !isConverting, !isImporting, !isScanning else { return }
        if workItems.isEmpty {
            guard items.contains(where: { !$0.isConvertible && $0.status != .done }) else { return }
            errorMessage = nil
            conversionLog.removeAll()
            conversionUsesBatchOutput = false
            lastOutputFolder = nil
            missingDateItems = []
            lastUnsupportedItems = items.filter { $0.kind == .none && $0.status != .done }
            let result = archiveSources(doneItems: [])
            summary = errorMessage == nil ? "分类与时间修复完成" : "部分文件归类失败，请查看提示"
            lastConversionSummary = "实况转换 0 张，时间修复成功 \(result.timeRepaired) 项，无法修复时间 \(result.timeMissing) 项。"
            logLine("本次结果：\(lastConversionSummary!)")
            openConversionLogWhenConfigured()
            return
        }
        if let message = convertPreflight() {
            errorMessage = message
            logLine("无法开始：\(message)")
            return
        }

        for item in workItems {
            guard let i = index(of: item.url.path) else { continue }
            items[i].status = .pending
            items[i].uuid = nil
            items[i].failureLog = nil
            items[i].outputJPG = nil
            items[i].outputMOV = nil
        }

        isConverting = true
        missingDateItems = []
        lastConversionSummary = nil
        conversionLog.removeAll()
        logLine("开始转换 \(workItems.count) 张，完成后分类其他文件")
        summary = nil
        errorMessage = nil
        progressDone = 0
        progressTotal = workItems.count
        sawDone = false
        if filter == .unsupported || filter == .failed { filter = .convertible }

        conversionUsesBatchOutput = destination != .photos && folderOutputMode == .batch
        let out: URL
        if destination == .photos || conversionUsesBatchOutput {
            out = FileManager.default.temporaryDirectory
                .appendingPathComponent("光影间-\(UUID().uuidString)")
        } else {
            out = outputURL
        }
        conversionOutputURL = out
        conversionDestination = destination

        // The backend writes stem.jpg + stem.mov. Never let it overwrite an input
        // or another selected image with the same stem from a different directory.
        let sources = Set(items.flatMap { SourceFiles.originals(photo: $0.url, videoName: $0.videoName, companionVideoNames: $0.companionVideoNames) }
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() })
        var targets = Set<String>()
        for item in workItems {
            for ext in ["jpg", "mov"] {
                let target = out.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + "." + ext)
                    .resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
                if sources.contains(target) || !targets.insert(target).inserted {
                    isConverting = false
                    errorMessage = "输出路径与原文件重叠，或所选照片存在同名输出。请更换输出文件夹，或将同名照片分批转换。"
                    return
                }
            }
        }

        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            isConverting = false
            errorMessage = "无法创建输出文件夹：\(error.localizedDescription)"
            return
        }
        lastOutputFolder = destination == .photos ? nil : out
        let conversionID = UUID()
        activeConversionID = conversionID
        conversionItemPaths = Set(workItems.map { $0.url.path })

        if destination != .folder {
            PhotosExporter.requestAccess { [weak self] granted in
                guard let self = self, self.activeConversionID == conversionID else { return }
                if granted {
                    self.beginProcess(workItems: workItems, out: out, conversionID: conversionID)
                } else {
                    self.activeConversionID = nil
                    self.conversionItemPaths.removeAll()
                    self.isConverting = false
                    self.errorMessage = "没有照片图库写入权限。请到 系统设置 → 隐私与安全性 → 照片 中允许「光影间」添加照片，或把输出位置改成「文件夹」。"
                }
            }
        } else {
            beginProcess(workItems: workItems, out: out, conversionID: conversionID)
        }
    }

    private func beginProcess(workItems: [PhotoItem], out: URL, conversionID: UUID) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: AppPaths.python3 ?? "/usr/bin/python3")
        p.arguments = [AppPaths.script.path, "--json"] + workItems.map { $0.url.path } + ["-o", out.path]
        p.environment = AppPaths.environment()

        let pipe = Pipe()
        let errorCapture = ProcessErrorCapture()
        p.standardOutput = pipe
        p.standardError = errorCapture.pipe
        errorCapture.start()

        currentProcess = p
        do {
            try p.run()
        } catch {
            currentProcess = nil
            activeConversionID = nil
            conversionItemPaths.removeAll()
            isConverting = false
            errorMessage = "无法启动转换进程：\(error.localizedDescription)"
            return
        }

        // Drain stdout before reporting process termination. A termination
        // callback could otherwise discard the final done event and its archive.
        workQueue.async {
            var buffer = Data()
            func deliver(_ line: Data) {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                DispatchQueue.main.async {
                    guard self.activeConversionID == conversionID else { return }
                    self.handle(obj)
                }
            }
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let range = buffer.range(of: Data([0x0A])) {
                    deliver(buffer.subdata(in: 0..<range.lowerBound))
                    buffer.removeSubrange(0...range.lowerBound)
                }
            }
            if !buffer.isEmpty { deliver(buffer) }
            p.waitUntilExit()
            let errText = errorCapture.finish()
            DispatchQueue.main.async {
                guard self.activeConversionID == conversionID else { return }
                let wasCancelled = self.cancelledConversionID == conversionID
                self.activeConversionID = nil
                self.cancelledConversionID = nil
                if wasCancelled { self.conversionItemPaths.removeAll() }
                self.currentProcess = nil
                self.isConverting = false
                if wasCancelled {
                    self.summary = "已停止"
                    return
                }
                if !self.sawDone {
                    if !errText.isEmpty {
                        self.errorMessage = errText
                    } else {
                        self.errorMessage = "转换进程异常结束（退出码 \(p.terminationStatus)）。"
                    }
                }
            }
        }

    }

    func cancelConversion() {
        guard let conversionID = activeConversionID, !sawDone else { return }
        if let process = currentProcess {
            guard process.isRunning else { return }
            cancelledConversionID = conversionID
            process.terminate()
            summary = "正在停止…"
        } else {
            activeConversionID = nil
            cancelledConversionID = nil
            conversionItemPaths.removeAll()
            isConverting = false
            summary = "已停止"
        }
        for i in items.indices {
            if case .running = items[i].status {
                items[i].status = .pending
            }
        }
    }

    private func handle(_ obj: [String: Any]) {
        guard cancelledConversionID == nil else { return }
        guard let type = obj["type"] as? String else { return }
        switch type {
        case "begin":
            if let total = obj["total"] as? Int {
                progressTotal = total
                logLine("共 \(total) 张")
            }
        case "start":
            if let path = obj["path"] as? String {
                setStatus(.running, for: path)
                if let i = index(of: path) { logLine("→ \(items[i].name)") }
            }
        case "ok":
            if let path = obj["path"] as? String, let i = index(of: path) {
                items[i].status = .done
                items[i].uuid = obj["uuid"] as? String
                if let jpg = obj["out_jpg"] as? String {
                    items[i].outputJPG = URL(fileURLWithPath: jpg)
                }
                if let mov = obj["out_mov"] as? String {
                    items[i].outputMOV = URL(fileURLWithPath: mov)
                }
                let item = items[i]
                logLine("✓ \(item.name)")
                recordHistory(name: item.name, status: "成功", device: item.deviceModel,
                              uuid: item.uuid, outputJPG: item.outputJPG?.path,
                              outputMOV: item.outputMOV?.path, error: nil)
            }
            progressDone += 1
        case "fail":
            if let path = obj["path"] as? String, let i = index(of: path) {
                let error = (obj["error"] as? String) ?? "未知错误"
                items[i].status = .failed(error)
                items[i].failureLog = obj["log"] as? String
                logLine("✗ \(items[i].name)：\(error)")
                logLine("可能原因：\(failureHint(error))")
                if let log = obj["log"] as? String, !log.isEmpty {
                    logLine("程序输出：")
                    for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
                        conversionLog.append("    \(line)")
                    }
                }
                recordHistory(name: items[i].name, status: "失败", device: items[i].deviceModel,
                              uuid: nil, outputJPG: nil, outputMOV: nil, error: error)
            }
            progressDone += 1
        case "skip":
            if let path = obj["path"] as? String {
                let reason = (obj["reason"] as? String) ?? "已跳过"
                setStatus(.unsupported(reason), for: path)
                if let i = index(of: path) {
                    items[i].kind = .none
                    logLine("－ \(items[i].name)：\(reason)")
                    recordHistory(name: items[i].name, status: "跳过", device: items[i].deviceModel,
                                  uuid: nil, outputJPG: nil, outputMOV: nil, error: reason)
                }
            }
            progressDone += 1
        case "done":
            sawDone = true
            confirmWorkspaceRefresh = true
            let ok = (obj["ok"] as? Int) ?? 0
            let fail = (obj["fail"] as? Int) ?? 0
            let skip = (obj["skip"] as? Int) ?? 0
            progressDone = ok + fail + skip
            progressTotal = max(progressTotal, progressDone)

            var parts = ["成功 \(ok) 张"]
            if fail > 0 { parts.append("失败 \(fail)") }
            if unsupportedCount > 0 { parts.append("\(unsupportedCount) 张不是实况") }
            summary = parts.joined(separator: " · ")
            _ = skip

            let doneItems = items.filter {
                conversionItemPaths.contains($0.url.path) &&
                $0.status == .done && $0.outputJPG != nil && $0.outputMOV != nil
            }
            lastUnsupportedItems = items.filter { $0.kind == .none && $0.status != .done }
            let failedIDs = Set(failedItems.filter { conversionItemPaths.contains($0.url.path) }.map(\.id))
            conversionItemPaths.removeAll()
            let archiveResult = archiveSources(doneItems: doneItems, failedIDs: failedIDs)
            lastConversionSummary = "实况转换 \(ok) 张，时间修复成功 \(archiveResult.timeRepaired) 项，无法修复时间 \(archiveResult.timeMissing) 项。"
            summary = lastConversionSummary
            openConversionLogWhenConfigured()
            let finalizedItems = items.filter { item in doneItems.contains(where: { $0.id == item.id }) }
            if UserDefaults.standard.bool(forKey: "openOutputAfterConversion"),
               conversionDestination != .photos, lastOutputFolder != nil {
                openOutput()
            }
            if conversionDestination != .folder && !doneItems.isEmpty {
                importToPhotos(items: finalizedItems.filter { !missingDateItems.map(\.id).contains($0.id) },
                               from: conversionOutputURL,
                               cleanup: conversionDestination == .photos,
                               batchSummary: lastConversionSummary ?? "")
            } else {
                logLine("本次结果：\(lastConversionSummary!)")
            }
        default:
            break
        }
    }

    private func archiveSources(doneItems: [PhotoItem], failedIDs: Set<UUID> = []) -> (timeRepaired: Int, timeMissing: Int) {
        let doneIDs = Set(doneItems.map { $0.id })
        var failures: [String] = []
        var timeRepaired = 0
        var timeMissing = 0
        let outputs = items.flatMap { [$0.outputJPG, $0.outputMOV].compactMap { $0 } }
        let batchName = SourceFiles.batchFolderName(for: Date())
        for i in items.indices {
            let item = items[i]
            let converted = doneIDs.contains(item.id)
            let conversionFailed = failedIDs.contains(item.id)
            guard converted || conversionFailed || (!item.isConvertible && item.status != .done) else { continue }
            let needsDate = !conversionFailed && (item.captureDate ?? "").isEmpty
            let mediaCategory = item.isConvertible ? "实况" : item.kind == .video ? "视频" : "静图"
            let dateCategory = converted ? "需补写时间/实况" : "需补写时间"
            var archivedSuccessfully = false
            let category: String
            if conversionFailed { category = "失败/" + mediaCategory }
            else if needsDate { category = converted ? dateCategory + "/原片" : dateCategory }
            else { category = "原件/" + mediaCategory }
            do {
                if converted, conversionUsesBatchOutput || needsDate,
                   let jpg = item.outputJPG, let mov = item.outputMOV {
                    let result = try SourceFiles.storeConverted(photo: item.url, jpg: jpg, mov: mov,
                        batchName: batchName, category: needsDate ? dateCategory : "实况",
                        root: conversionDestination != .photos && !conversionUsesBatchOutput ? conversionOutputURL : nil)
                    items[i].outputJPG = result.jpg
                    items[i].outputMOV = result.mov
                    lastOutputFolder = result.folder
                    logLine("转换结果已保存：\(result.folder.path)")
                }
                items[i].url = try SourceFiles.archive(photo: item.url, videoName: item.videoName,
                    folder: category, outputs: outputs,
                    batchName: batchName, captureDate: conversionFailed ? nil : item.captureDate,
                    companionVideoNames: item.companionVideoNames)
                archivedSuccessfully = true
                if conversionFailed {
                    let folder = items[i].url.deletingLastPathComponent()
                    if doneItems.isEmpty { lastOutputFolder = folder }
                    logLine("失败原片已归档：\(folder.path)")
                } else if !item.isConvertible {
                    items[i].status = .done
                    if lastOutputFolder == nil {
                        let folder = items[i].url.deletingLastPathComponent()
                        lastOutputFolder = needsDate ? folder.deletingLastPathComponent() : folder.deletingLastPathComponent().deletingLastPathComponent()
                    }
                }
                if !conversionFailed {
                    logLine("已归类：\(item.name)" + (needsDate || (item.captureDate ?? "").isEmpty ? "（无可靠拍摄时间，保留文件日期）" : "（已恢复文件日期）"))
                }
            } catch {
                if conversionUsesBatchOutput, let jpg = items[i].outputJPG,
                   jpg.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    lastOutputFolder = jpg.deletingLastPathComponent()
                    logLine("转换结果仍保留在：\(jpg.deletingLastPathComponent().path)")
                }
                if !item.isConvertible { items[i].status = .failed(error.localizedDescription) }
                failures.append("\(item.name)：\(error.localizedDescription)")
            }
            if (item.captureDate ?? "").isEmpty {
                missingDateItems.append(items[i])
                timeMissing += 1
            } else if archivedSuccessfully && !conversionFailed {
                timeRepaired += 1
            }
        }
        if !failures.isEmpty {
            errorMessage = "部分文件未能归类，已保留原位；转换输出不受影响：\n" + failures.joined(separator: "\n")
            failures.forEach { logLine($0) }
        }
        return (timeRepaired, timeMissing)
    }

    private func openConversionLogWhenConfigured() {
        guard (UserDefaults.standard.object(forKey: "showConversionLog") as? Bool) != false else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openConversionLogWindow, object: nil)
        }
    }

    private func importToPhotos(items doneItems: [PhotoItem], from folder: URL?, cleanup: Bool, batchSummary: String) {
        guard let folder = folder, !doneItems.isEmpty else { return }
        logLine("导入相册 \(doneItems.count) 张…")
        isImporting = true
        importProgress = 0
        importTotal = doneItems.count
        var success = 0
        var failure = 0
        var importedIDs = Set<UUID>()

        func finish() {
            isImporting = false
            var parts = ["已导入相册 \(success) 张"]
            if failure > 0 { parts.append("失败 \(failure)") }
            if let current = summary {
                summary = current + " · " + parts.joined(separator: " · ")
            } else {
                summary = parts.joined(separator: " · ")
            }
            logLine("已导入相册 \(success) 张" + (failure > 0 ? "，失败 \(failure) 张" : ""))
            if cleanup {
                for item in doneItems where importedIDs.contains(item.id) {
                    if let i = items.firstIndex(where: { $0.id == item.id }) {
                        items[i].outputJPG = nil
                        items[i].outputMOV = nil
                    }
                    for url in [item.outputJPG, item.outputMOV].compactMap({ $0 }) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                if failure == 0 {
                    if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                        try? FileManager.default.removeItem(at: folder)
                    }
                    if missingDateItems.isEmpty { lastOutputFolder = nil }
                } else {
                    lastOutputFolder = folder
                    errorMessage = "有 \(failure) 张未能导入照片图库，转换文件已保留在：\(folder.path)"
                }
            }
            logLine("本次结果：\(batchSummary)")
        }

        func step(_ index: Int) {
            if index >= doneItems.count {
                finish()
                return
            }
            let item = doneItems[index]
            guard let jpg = item.outputJPG, let mov = item.outputMOV else {
                step(index + 1)
                return
            }
            PhotosExporter.importPair(jpg: jpg, mov: mov) { error in
                if error == nil {
                    success += 1
                    importedIDs.insert(item.id)
                } else {
                    failure += 1
                }
                self.importProgress = index + 1
                step(index + 1)
            }
        }

        step(0)
    }

    private func index(of path: String) -> Int? {
        items.firstIndex { $0.url.path == path }
    }

    private func setStatus(_ status: ItemStatus, for path: String) {
        guard let i = index(of: path) else { return }
        items[i].status = status
    }

    // MARK: Item actions

    func rowTapped(_ item: PhotoItem) {
        switch item.status {
        case .done:
            activeSheet = item.isConvertible ? .openWith(item) : .info(item)
        default:
            activeSheet = .info(item)
        }
    }

    func reconvert(_ item: PhotoItem) {
        guard item.kind.isConvertible, !isConverting, !isImporting else { return }
        guard let i = index(of: item.url.path) else { return }
        items[i].status = .pending
        items[i].uuid = nil
        items[i].failureLog = nil
        items[i].outputJPG = nil
        items[i].outputMOV = nil
        let updated = items[i]
        startConversion(items: [updated])
    }

    func requestDelete(_ item: PhotoItem) {
        guard !isConverting, !isImporting, !isScanning else { return }
        let remembered = UserDefaults.standard.bool(forKey: "deleteConfirmationDone")
        let always = UserDefaults.standard.bool(forKey: "confirmBeforeDelete")
        if remembered && !always {
            performDelete(item, alsoFiles: UserDefaults.standard.bool(forKey: "deleteFilesOnRemove"))
        } else {
            activeSheet = .delete(item)
        }
    }

    func confirmDelete(_ item: PhotoItem, alsoFiles: Bool) {
        if item.outputJPG != nil || item.outputMOV != nil {
            UserDefaults.standard.set(alsoFiles, forKey: "deleteFilesOnRemove")
        }
        UserDefaults.standard.set(true, forKey: "deleteConfirmationDone")
        performDelete(item, alsoFiles: alsoFiles)
    }

    private func performDelete(_ item: PhotoItem, alsoFiles: Bool, originals: Bool? = nil) {
        let deleteOriginals = originals ?? UserDefaults.standard.bool(forKey: "deleteOriginalFilesOnRemove")
        let sourceURLs = SourceFiles.originals(photo: item.url, videoName: item.videoName, companionVideoNames: item.companionVideoNames)
        var urls = deleteOriginals ? sourceURLs : []
        if alsoFiles { urls += [item.outputJPG, item.outputMOV].compactMap { $0 } }
        if !deleteOriginals {
            let sourcePaths = Set(sourceURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            urls.removeAll { sourcePaths.contains($0.resolvingSymlinksInPath().standardizedFileURL.path) }
        }
        do { try SourceFiles.trash(urls) }
        catch {
            errorMessage = "未能删除 \(item.name)，记录已保留：\(error.localizedDescription)"
            return
        }
        items.removeAll { $0.id == item.id }
        if unsupportedCount == 0 { scanNotice = nil }
        if filter == .failed && failedItems.isEmpty { filter = .all }
        if items.isEmpty {
            summary = nil
            progressDone = 0
            progressTotal = 0
        }
        logLine("删除记录 \(item.name)" + (alsoFiles ? "（含输出文件）" : ""))
    }

    func deleteAllRecords(originals: Bool, outputs: Bool) {
        guard !isConverting, !isImporting, !isScanning else { return }
        UserDefaults.standard.set(originals, forKey: "deleteOriginalFilesOnRemove")
        UserDefaults.standard.set(outputs, forKey: "deleteFilesOnRemove")
        for item in items { performDelete(item, alsoFiles: outputs, originals: originals) }
        if items.isEmpty { filter = .all }
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    func revealHistory(_ entry: HistoryEntry) {
        if let p = entry.outputJPG, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        } else if let p = entry.outputMOV, FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "conversionHistory"),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        history = entries
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: "conversionHistory")
    }

    private func recordHistory(name: String, status: String, device: String,
                               uuid: String?, outputJPG: String?, outputMOV: String?,
                               error: String?) {
        let entry = HistoryEntry(date: Date(), name: name, status: status,
                                 device: device, uuid: uuid,
                                 outputJPG: outputJPG, outputMOV: outputMOV, error: error)
        history.insert(entry, at: 0)
        if history.count > 1000 { history = Array(history.prefix(1000)) }
        saveHistory()
    }

    private func logLine(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        conversionLog.append("[\(f.string(from: Date()))] \(text)")
        if conversionLog.count > 800 {
            conversionLog.removeFirst(conversionLog.count - 800)
        }
    }

    func clearCompleted() {
        items.removeAll { $0.status == .done }
        if items.isEmpty { summary = nil }
    }

    func clearAll() {
        guard !isConverting, !isImporting else { return }
        items.removeAll()
        summary = nil
        scanNotice = nil
        progressDone = 0
        progressTotal = 0
        filter = .all
    }

    func reveal(_ item: PhotoItem) {
        let url = item.outputJPG ?? item.url
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealUnsupported() {
        let urls = unsupportedItems.map { $0.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func revealFailed() {
        let urls = failedItems.map { $0.url }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyName(_ item: PhotoItem) { copy(item.name) }
    func copyPath(_ item: PhotoItem) { copy(item.url.path) }
    func copyUUID(_ item: PhotoItem) { if let uuid = item.uuid { copy(uuid) } }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func open(url: URL, with app: URL?) {
        if let app = app {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func applications(for url: URL) -> [URL] {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        var seen = Set<String>()
        return apps
            .filter { app in
                let key = Bundle(url: app)?.bundleIdentifier ?? app.path
                return seen.insert(key).inserted && app.path != Bundle.main.bundlePath
            }
            .sorted {
                $0.deletingPathExtension().lastPathComponent
                    .localizedStandardCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending
            }
    }

    // MARK: Panels

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择照片、视频或文件夹，实况转换后统一分类并修复文件时间"
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择转换结果的保存位置"
        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url
            setFolderOutputMode(.custom)
            UserDefaults.standard.set(url.path, forKey: "outputPath")
            if destination == .photos {
                setDestination(.folder)
            }
        }
    }

    func setDestination(_ value: OutputDestination) {
        guard !isConverting, !isImporting else { return }
        destination = value
        UserDefaults.standard.set(value.rawValue, forKey: "destination")
    }

    func setFolderOutputMode(_ value: FolderOutputMode) {
        guard !isConverting, !isImporting else { return }
        folderOutputMode = value
        UserDefaults.standard.set(value.rawValue, forKey: "folderOutputMode")
    }

    func openOutput() {
        guard let url = lastOutputFolder ?? (folderOutputMode == .custom ? outputURL : nil) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func openResult() {
        if destination == .photos {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photos.app"))
        } else {
            openOutput()
        }
    }

    // MARK: Demo (only for snapshots)

    func loadDemo() {
        let base = "/tmp/demo"
        let specs: [(String, ItemKind, String, ItemStatus)] = [
            ("IMG_0001.jpg", .embedded, "OPPO", .done),
            ("IMG_0002.jpg", .embedded, "OPPO", .pending),
            ("IMG_20260101_120000.jpg", .paired, "vivo", .pending)
        ]
        var demo: [PhotoItem] = []
        for (name, kind, make, status) in specs {
            var item = PhotoItem(url: URL(fileURLWithPath: base).appendingPathComponent(name),
                                 name: name, kind: kind, make: make,
                                 videoName: kind == .paired ? name.replacingOccurrences(of: ".jpg", with: ".mp4") : nil)
            item.status = status
            item.captureDate = "2026:01:01 12:00:00+08:00"
            item.hdr = name == "IMG_0001.jpg" ? "Ultra HDR" : "HDR 增益图"
            item.model = kind == .paired ? "vivo X200 Pro" : "OPPO Find X8"
            item.gpsLat = kind == .paired ? 39.9042 : 31.2304
            item.gpsLon = kind == .paired ? 116.4074 : 121.4737
            item.locationName = kind == .paired
                ? "北京市东城区"
                : "上海市黄浦区"
            if status == .done { item.uuid = "1E1ED7C6-30F4-4921-92FD-1417273C15D3" }
            demo.append(item)
        }
        for name in ["IMG_9001.jpg", "IMG_9002.jpg"] {
            let url = URL(fileURLWithPath: "/tmp/mixed").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                var item = PhotoItem(url: url, name: name, kind: .none, make: "", videoName: nil)
                item.reason = "没有找到动态视频"
                item.captureDate = "2025:05:04 15:08:15+08:00"
                item.hdr = "SDR"
                item.model = ""
                item.locationName = nil
                item.status = .unsupported("没有找到动态视频")
                demo.append(item)
            }
        }
        items = demo
        sortItems()
        isConverting = true
        progressDone = 1
        progressTotal = 3
        summary = nil
        filter = .all
        if unsupportedCount > 0 {
            scanNotice = "共 \(items.count) 张，其中 \(unsupportedCount) 张不是实况照片（没有动态视频），已跳过。"
        }
        outputURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/光影间")
    }
}

import SwiftUI
import AppKit

struct TimeRepairPreview {
    let raw: String
    let fromFilename: Bool
    var timeText: String {
        guard raw.count >= 19 else { return "需手动指定" }
        return raw.prefix(10).replacingOccurrences(of: ":", with: "/") + " " + raw.dropFirst(11).prefix(8)
    }
    var sourceText: String {
        guard raw.count >= 19 else { return "无可靠拍摄时间" }
        return (fromFilename ? "文件名推测" : "拍摄元数据") + " · UTC" + raw.dropFirst(19)
    }
}

struct TimeRepairFailure: Identifiable {
    let id = UUID()
    let url: URL
    let reason: String
    let folder: URL?
}

final class TimeRepairTask: ObservableObject {
    @Published var running = false
    @Published private(set) var repairedURLs = Set<URL>()
    @Published var previewing = false
    @Published var previews: [URL: TimeRepairPreview] = [:]
    @Published var message = ""
    @Published var result: URL?
    @Published var log: [String] = []
    @Published var failures: [TimeRepairFailure] = []
    @Published var showFailures = false
    @Published var completed = 0
    @Published var total = 0
    private var succeeded = 0
    private var sawDone = false
    private var previewID = UUID()
    private var logWindow: NSWindow?

    func preview(files: [URL]) {
        let id = UUID()
        previewID = id
        previewing = !files.isEmpty
        previews = [:]
        guard !files.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var values: [URL: TimeRepairPreview] = [:]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: AppPaths.python3 ?? "/usr/bin/python3")
            process.arguments = [AppPaths.script.path, "--preview-time"] + files.map(\.path)
            process.environment = AppPaths.environment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                for line in data.split(separator: 10) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          object["type"] as? String == "time_preview" else { continue }
                    let value = TimeRepairPreview(raw: object["date"] as? String ?? "",
                                                  fromFilename: object["date_source"] as? String == "filename")
                    for path in object["members"] as? [String] ?? [] {
                        values[URL(fileURLWithPath: path).standardizedFileURL] = value
                    }
                }
            } catch { /* Missing previews are displayed as requiring manual input. */ }
            DispatchQueue.main.async {
                guard self.previewID == id else { return }
                self.previews = values
                self.previewing = false
            }
        }
    }

    func start(files: [URL], output: URL?, capture: String?, stillOnly: Bool = false,
               useModifiedDate: Bool = false) {
        guard !running, !files.isEmpty else { return }
        running = true
        repairedURLs = []
        message = ""
        result = nil
        failures = []
        log = []
        completed = 0
        total = files.count
        succeeded = 0
        sawDone = false
        appendLog("正在读取拍摄信息并合并实况配对…")
        showLog()
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: AppPaths.python3 ?? "/usr/bin/python3")
            var arguments = [AppPaths.script.path, "--repair-time"]
            if let output {
                arguments += ["-o", output.path]
            } else {
                arguments.append("--time-source")
            }
            if stillOnly { arguments.append("--time-still-only") }
            if useModifiedDate { arguments.append("--time-use-modified-date") }
            if let capture { arguments += ["--capture-time", capture] }
            arguments += files.map(\.path)
            process.arguments = arguments
            process.environment = AppPaths.environment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var exitCode: Int32 = -1
            do {
                try process.run()
                var buffer = Data()
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline])
                        buffer.removeSubrange(...newline)
                        DispatchQueue.main.async { self.consume(line) }
                    }
                }
                if !buffer.isEmpty {
                    let line = buffer
                    DispatchQueue.main.async { self.consume(line) }
                }
                process.waitUntilExit()
                exitCode = process.terminationStatus
            } catch {
                let text = error.localizedDescription
                DispatchQueue.main.async { self.appendLog(text) }
            }
            let status = exitCode
            DispatchQueue.main.async { self.finish(status: status, files: files) }
        }
    }

    private func consume(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            let text = String(decoding: line, as: UTF8.self)
            if !text.isEmpty { appendLog(text) }
            return
        }
        let path = object["path"] as? String ?? ""
        let name = URL(fileURLWithPath: path).lastPathComponent
        switch object["type"] as? String {
        case "time_note":
            if let note = object["message"] as? String { appendLog(note) }
        case "time_begin":
            total = object["total"] as? Int ?? total
            for folder in object["folders"] as? [String] ?? [] { appendLog("保存位置：" + folder) }
            appendLog("共 \(total) 项，实况静图与视频按一项处理。")
        case "time_start": appendLog("开始：" + name)
        case "time_ok":
            if !path.isEmpty, object["partial"] as? Bool != true {
                repairedURLs.insert(URL(fileURLWithPath: path).standardizedFileURL)
            }
            succeeded += 1
            completed += 1
            if let folder = object["folder"] as? String { result = URL(fileURLWithPath: folder) }
            appendLog("成功：" + name + " → " + (object["date"] as? String ?? ""))
        case "time_fail":
            completed += 1
            var reason = object["error"] as? String ?? "写入失败"
            let details = reason.lowercased()
            if details.contains("not a valid") || details.contains("file format error") || details.contains("corrupt") {
                reason = "文件格式与扩展名可能不一致，或文件内容不完整。请在「预览」中检查，必要时从原应用重新导出。\n\n" + reason
            } else if details.contains("moov atom not found") {
                reason = "视频缺少播放索引，文件可能损坏或复制不完整。\n\n" + reason
            }
            if let backup = object["backup_error"] as? String { reason += "\n" + backup }
            let folder = (object["folder"] as? String).map { URL(fileURLWithPath: $0) }
            failures.append(TimeRepairFailure(url: URL(fileURLWithPath: path), reason: reason, folder: folder))
            appendLog("失败：" + name + "：" + reason)
            if let folder { appendLog("失败原片副本：" + folder.path) }
        case "time_done":
            sawDone = true
            if let first = (object["folders"] as? [String])?.first { result = URL(fileURLWithPath: first) }
        default: break
        }
    }

    private func finish(status: Int32, files: [URL]) {
        running = false
        if !sawDone || (status != 0 && failures.isEmpty) || total == 0 {
            let reason = total == 0 ? "没有可处理的照片或视频。" : "处理进程未正常完成，请查看处理日志；原文件保留在原位。"
            failures.append(TimeRepairFailure(url: files[0], reason: reason, folder: nil))
            appendLog(reason)
        }
        message = total == 1 && failures.isEmpty ? "时间修复成功。" : "已修复 \(succeeded) 项，失败 \(failures.count) 项。"
        appendLog(message)
        // Persist the log in an existing batch directory, never create a folder for a single failure.
        if total > 1, let result {
            try? log.joined(separator: "\n").write(to: result.appendingPathComponent("处理日志.txt"), atomically: true, encoding: .utf8)
        }
        if !failures.isEmpty { showFailures = true }
    }

    private func appendLog(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.append("[" + formatter.string(from: Date()) + "] " + text)
    }

    func showLog() {
        if let logWindow {
            logWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "时间修复日志"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TimeRepairLogView(task: self))
        window.center()
        logWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func closeWindows() {
        logWindow?.close()
        logWindow?.contentView = nil
        logWindow = nil
    }
}

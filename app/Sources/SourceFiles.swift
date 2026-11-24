import Foundation

/// Never overwrite existing files; paired media moves together.
enum SourceFiles {
    static let convertedFolder = "已转换原片"
    static let unsupportedFolder = "非实况照片"

    static func batchFolderName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy.MM.dd-hh.mm.ss.a"
        return "已批量处理_" + f.string(from: date).lowercased()
    }

    static func originals(photo: URL, videoName: String?, companionVideoNames: [String] = []) -> [URL] {
        var result = [photo]
        var seen: Set<String> = [photo.standardizedFileURL.path]
        let names = (videoName.map { [$0] } ?? []) + companionVideoNames
        for name in names {
            let video = photo.deletingLastPathComponent().appendingPathComponent(name)
            guard seen.insert(video.standardizedFileURL.path).inserted,
                  FileManager.default.fileExists(atPath: video.path) else { continue }
            result.append(video)
        }
        return result
    }

    static func archive(photo: URL, videoName: String?, folder: String, outputs: [URL], batchName: String? = nil, captureDate: String? = nil, companionVideoNames: [String] = []) throws -> URL {
        if batchName == nil {
            let parent = photo.deletingLastPathComponent()
            if parent.path.hasSuffix("/" + folder) ||
                (UUID(uuidString: parent.lastPathComponent) != nil &&
                 parent.deletingLastPathComponent().path.hasSuffix("/" + folder)) { return photo }
        }
        if batchName != nil && photo.pathComponents.contains(where: { $0.hasPrefix("已批量处理_") }) { return photo }
        let fm = FileManager.default
        let sources = originals(photo: photo, videoName: videoName, companionVideoNames: companionVideoNames)
        let outputPaths = Set(outputs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        guard !sources.contains(where: { outputPaths.contains($0.resolvingSymlinksInPath().standardizedFileURL.path) }) else {
            throw NSError(domain: "SourceFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "原片和输出文件路径相同，已保留原位"])
        }
        var target = photo.deletingLastPathComponent()
        if let batchName {
            target.appendPathComponent(batchName, isDirectory: true)
        }
        target.appendPathComponent(folder, isDirectory: true)
        if sources.contains(where: { fm.fileExists(atPath: target.appendingPathComponent($0.lastPathComponent).path) }) {
            target.appendPathComponent(UUID().uuidString, isDirectory: true)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        do {
            for source in sources {
                let dest = target.appendingPathComponent(source.lastPathComponent)
                try fm.moveItem(at: source, to: dest)
                moved.append((source, dest))
                if let captureDate, let date = parseCaptureDate(captureDate) {
                    try fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: dest.path)
                }
            }
        } catch {
            var rollbackErrors: [String] = []
            for (source, dest) in moved.reversed() {
                do { try fm.moveItem(at: dest, to: source) }
                catch { rollbackErrors.append(dest.path) }
            }
            if !rollbackErrors.isEmpty {
                throw NSError(domain: "SourceFiles", code: 2, userInfo: [NSLocalizedDescriptionKey: "归档未完成，部分文件保留在：" + rollbackErrors.joined(separator: "、")])
            }
            throw error
        }
        return target.appendingPathComponent(photo.lastPathComponent)
    }

    /// Publish a finished pair together, without overwriting an earlier batch or source.
    static func storeConverted(photo: URL, jpg: URL, mov: URL, batchName: String?, category: String = "实况", root: URL? = nil) throws -> (jpg: URL, mov: URL, folder: URL) {
        let fm = FileManager.default
        var folder = root ?? photo.deletingLastPathComponent()
        if let batchName { folder.appendPathComponent(batchName, isDirectory: true) }
        folder.appendPathComponent(category, isDirectory: true)
        if [jpg, mov].contains(where: { fm.fileExists(atPath: folder.appendingPathComponent($0.lastPathComponent).path) }) {
            folder.appendPathComponent(UUID().uuidString, isDirectory: true)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let newJPG = folder.appendingPathComponent(jpg.lastPathComponent)
        let newMOV = folder.appendingPathComponent(mov.lastPathComponent)
        try fm.moveItem(at: jpg, to: newJPG)
        do { try fm.moveItem(at: mov, to: newMOV) }
        catch {
            do { try fm.moveItem(at: newJPG, to: jpg) }
            catch {
                throw NSError(domain: "SourceFiles", code: 3, userInfo: [NSLocalizedDescriptionKey: "结果移动未完成，静图保留在：" + newJPG.path + "；视频保留在：" + mov.path])
            }
            throw error
        }
        if let sourceAttributes = try? fm.attributesOfItem(atPath: photo.path),
           let modified = sourceAttributes[.modificationDate] as? Date {
            var outputAttributes: [FileAttributeKey: Any] = [.modificationDate: modified]
            if let created = sourceAttributes[.creationDate] as? Date {
                outputAttributes[.creationDate] = created
            }
            for output in [newJPG, newMOV] {
                try? fm.setAttributes(outputAttributes, ofItemAtPath: output.path)
            }
        }
        return (newJPG, newMOV, folder)
    }

    private static func parseCaptureDate(_ value: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy:MM:dd HH:mm:ssXXXXX", "yyyy:MM:dd HH:mm:ss"] {
            f.dateFormat = format
            if let date = f.date(from: value) { return date }
        }
        return nil
    }

    static func trash(_ urls: [URL]) throws {
        let fm = FileManager.default
        var seen = Set<String>()
        for url in urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard seen.insert(path).inserted, fm.fileExists(atPath: path) else { continue }
            try fm.trashItem(at: url, resultingItemURL: nil)
        }
    }
}

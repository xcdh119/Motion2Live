import Foundation

struct PhotoInfo {
    var date: String?
    var dateOffset: String?
    var make: String?
    var model: String?
    var lens: String?
    var focal: String?
    var focal35: String?
    var aperture: String?
    var shutter: String?
    var iso: String?
    var exposureComp: String?
    var width: Int?
    var height: Int?
    var size: Int64?
    var format: String?
    var hdr: String?
    var gpsLat: Double?
    var gpsLon: Double?
    var videoCodec: String?
    var videoWidth: Int?
    var videoHeight: Int?
    var duration: Double?
    var uuid: String?
    var kind: String?

    init?(json: [String: Any]) {
        func str(_ key: String) -> String? {
            guard let value = json[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func int(_ key: String) -> Int? {
            (json[key] as? NSNumber)?.intValue
        }
        func double(_ key: String) -> Double? {
            (json[key] as? NSNumber)?.doubleValue
        }

        date = str("date")
        dateOffset = str("date_offset")
        make = str("make")
        model = str("model")
        lens = str("lens")
        focal = str("focal")
        focal35 = str("focal_35")
        aperture = str("aperture")
        shutter = str("shutter")
        iso = str("iso")
        exposureComp = str("exposure_comp")
        width = int("width")
        height = int("height")
        size = (json["size"] as? NSNumber)?.int64Value
        format = str("format")
        hdr = str("hdr")
        gpsLat = double("gps_lat")
        gpsLon = double("gps_lon")
        uuid = str("uuid")
        kind = str("kind")

        if let video = json["video"] as? [String: Any] {
            videoCodec = video["codec"] as? String
            videoWidth = (video["width"] as? NSNumber)?.intValue
            videoHeight = (video["height"] as? NSNumber)?.intValue
            duration = (video["duration"] as? NSNumber)?.doubleValue
        }
    }
}

enum PhotoInfoLoader {
    static func load(path: String, completion: @escaping (PhotoInfo?) -> Void) {
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: AppPaths.python3 ?? "/usr/bin/python3")
            process.arguments = [AppPaths.script.path, "--info", path]
            process.environment = AppPaths.environment()

            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()

            do {
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let info = PhotoInfo(json: obj) {
                    DispatchQueue.main.async { completion(info) }
                    return
                }
            } catch {}
            DispatchQueue.main.async { completion(nil) }
        }
    }
}

enum DateText {
    static func parse(_ raw: String?) -> Date? {
        guard let raw = raw, raw.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(raw.prefix(19)))
    }

    static func short(_ raw: String?) -> String? {
        guard let date = parse(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d HH:mm"
        return formatter.string(from: date)
    }

    static func long(_ raw: String?) -> String {
        guard let date = parse(raw) else { return raw ?? "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

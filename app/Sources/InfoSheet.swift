import SwiftUI
import AppKit

struct InfoSheet: View {
    @ObservedObject var model: AppModel
    let item: PhotoItem
    @Environment(\.dismiss) private var dismiss

    @State private var info: PhotoInfo?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview

                    if !item.isConvertible {
                        unsupportedNote
                    }

                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("读取照片信息…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 90)
                    } else if let info = info {
                        metadata(info)
                        if info.gpsLat != nil && info.gpsLon != nil {
                            location(info)
                        }
                        histogram
                        paths
                    } else {
                        Text("无法读取照片信息")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 90)
                    }
                }
                .padding(18)
            }

            Divider()

            HStack {
                if case .done = item.status {
                    Button("打开方式…") {
                        model.activeSheet = .openWith(item)
                        dismiss()
                    }
                }
                Button("在 Finder 中显示") { model.reveal(item) }
                Spacer()
                Button("好") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 760)
        .onAppear {
            PhotoInfoLoader.load(path: item.url.path) { loaded in
                info = loaded
                loading = false
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            ThumbnailView(url: item.url, size: 420)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .center,
                           endPoint: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(dateText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(14)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var dateText: String {
        let value = info?.date ?? item.captureDate
        let text = DateText.long(value)
        return text.isEmpty ? "拍摄时间未知" : text
    }

    private var unsupportedNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(item.kind == .video ? "独立视频会归入视频文件夹，并依据内嵌创建时间修复文件日期。" : "这张照片没有可转换的动态视频。处理时会归类并尝试修复文件日期；缺少可靠拍摄信息时保留原时间。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.08)))
    }

    // MARK: Metadata

    private func metadata(_ info: PhotoInfo) -> some View {
        let camera = [info.make, info.model].compactMap { $0 }.joined(separator: " ")
        let focalText: String = {
            if let f = info.focal, let f35 = info.focal35 { return "\(f)（等效 \(f35)）" }
            if let f = info.focal { return f }
            if let f35 = info.focal35 { return "等效 \(f35)" }
            return ""
        }()
        let lensText: String = {
            guard let lens = info.lens, !lens.isEmpty else { return "" }
            let lower = lens.lowercased()
            let f = info.focal ?? ""
            let a = info.aperture.map { "f/\($0)" } ?? ""
            if lower.contains("back triple camera") {
                return ["后置三摄", f, a].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if lower.contains("back dual camera") {
                return ["后置双摄", f, a].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            if lower.contains("front") {
                return ["前置", f, a].filter { !$0.isEmpty }.joined(separator: " · ")
            }
            return lens
        }()
        let apertureText = info.aperture.map { "f/\($0)" } ?? ""
        let shutterText = info.shutter.map { "\($0) 秒" } ?? ""
        let evText = info.exposureComp.map { "\($0) EV" } ?? ""
        let dimText: String = {
            guard let w = info.width, let h = info.height, w > 0, h > 0 else { return "" }
            return "\(w) × \(h)"
        }()
        let sizeText = info.size.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? ""
        let videoText: String = {
            guard let codec = info.videoCodec,
                  let w = info.videoWidth, let h = info.videoHeight else { return "" }
            let duration = info.duration.map { String(format: "%.1f 秒", $0) } ?? ""
            return "\(codec.uppercased()) · \(w) × \(h) · \(duration)"
        }()

        return LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16)
        ], alignment: .leading, spacing: 14) {
            if !camera.isEmpty {
                InfoCell(icon: "camera", title: "相机", value: camera)
            }
            if !lensText.isEmpty {
                InfoCell(icon: "camera.aperture", title: "镜头", value: lensText)
            }
            if !focalText.isEmpty {
                InfoCell(icon: "scope", title: "焦距", value: focalText)
            }
            if !apertureText.isEmpty {
                InfoCell(icon: "camera.aperture", title: "光圈", value: apertureText)
            }
            if !shutterText.isEmpty {
                InfoCell(icon: "timer", title: "快门", value: shutterText)
            }
            if let iso = info.iso, !iso.isEmpty {
                InfoCell(icon: "sun.max", title: "ISO", value: iso)
            }
            if !evText.isEmpty {
                InfoCell(icon: "plusminus", title: "曝光补偿", value: evText)
            }
            if !dimText.isEmpty {
                InfoCell(icon: "arrow.up.left.and.arrow.down.right", title: "尺寸", value: dimText)
            }
            if !sizeText.isEmpty {
                InfoCell(icon: "externaldrive", title: "大小", value: sizeText)
            }
            if let format = info.format, !format.isEmpty {
                InfoCell(icon: "doc", title: "格式", value: format)
            }
            if let hdr = info.hdr, !hdr.isEmpty {
                InfoCell(icon: "sun.max", title: "HDR",
                         value: hdr == "SDR" ? "SDR（无增益图）" : "\(hdr)（已保留）")
            }
            if case .done = item.status {
                InfoCell(icon: "checkmark.seal", title: "转换",
                         value: "无损 · 静态图未重编码")
            }
            if !videoText.isEmpty {
                InfoCell(icon: "film", title: "实况视频", value: videoText)
            }
            if let uuid = item.uuid ?? info.uuid, !uuid.isEmpty {
                InfoCell(icon: "number", title: "UUID", value: uuid)
            }
        }
    }

    // MARK: Location

    private func location(_ info: PhotoInfo) -> some View {
        let lat = info.gpsLat ?? 0
        let lon = info.gpsLon ?? 0
        let text = String(format: "%.4f° %@, %.4f° %@",
                          abs(lat), lat >= 0 ? "N" : "S",
                          abs(lon), lon >= 0 ? "E" : "W")
        return HStack(spacing: 8) {
            Image(systemName: "location.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("位置").font(.system(size: 10)).foregroundStyle(.secondary)
                if let address = item.locationName {
                    Text(address).font(.system(size: 11.5))
                    Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text(text).font(.system(size: 11.5))
                }
            }
            Spacer()
            Button("在地图中打开") {
                if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
        }
    }

    // MARK: Histogram

    private var histogram: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("直方图")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HistogramView(url: item.url)
                .frame(height: 72)
        }
    }

    // MARK: Paths

    private var paths: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathRow("源文件", item.url.path)
            if let out = item.outputJPG {
                pathRow("输出照片", out.path)
            }
            if let out = item.outputMOV {
                pathRow("输出视频", out.path)
            }
        }
    }

    private func pathRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Info cell

struct InfoCell: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Histogram

struct HistogramView: View {
    let url: URL
    @State private var bins: [[CGFloat]] = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
            if bins.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Canvas { context, size in
                    let maxValue = max(bins.flatMap { $0 }.max() ?? 1, 1)
                    let colors: [Color] = [.red, .green, .blue]
                    for channel in 0..<3 {
                        let values = bins[channel]
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for i in 0..<values.count {
                            let x = CGFloat(i) / CGFloat(max(values.count - 1, 1)) * size.width
                            let y = size.height - (values[i] / maxValue) * (size.height - 4)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                        context.fill(path, with: .color(colors[channel].opacity(0.32)))
                    }
                }
                .padding(4)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let cg = ThumbnailCache.shared.cgImage(for: url, size: 180) else { return }
        let width = 128
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var result = [[CGFloat]](repeating: [CGFloat](repeating: 0, count: 48), count: 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i])
            let g = Int(pixels[i + 1])
            let b = Int(pixels[i + 2])
            result[0][min(47, r * 48 / 256)] += 1
            result[1][min(47, g * 48 / 256)] += 1
            result[2][min(47, b * 48 / 256)] += 1
        }
        DispatchQueue.main.async { bins = result }
    }
}

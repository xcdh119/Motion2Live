import SwiftUI

struct DeleteSheet: View {
    @ObservedObject var model: AppModel
    let item: PhotoItem
    @Environment(\.dismiss) private var dismiss
    @State private var alsoFiles: Bool
    @State private var alsoOriginals: Bool

    init(model: AppModel, item: PhotoItem) {
        self.model = model
        self.item = item
        _alsoFiles = State(initialValue: UserDefaults.standard.bool(forKey: "deleteFilesOnRemove"))
        _alsoOriginals = State(initialValue: UserDefaults.standard.bool(forKey: "deleteOriginalFilesOnRemove"))
    }

    private var hasOutput: Bool {
        item.outputJPG != nil || item.outputMOV != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("删除这条记录？")
                        .font(.system(size: 14, weight: .semibold))
                    Text(item.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("同时删除原文件（包括配对视频）", isOn: $alsoOriginals)
                    .toggleStyle(.checkbox)
                if hasOutput {
                    Toggle("同时删除输出文件（JPG + MOV）", isOn: $alsoFiles)
                        .toggleStyle(.checkbox)
                    Text("两个选项都不勾选时，仅删除列表记录，原文件和输出文件都会保留。勾选的文件移到废纸篓。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text("这条记录没有输出文件。不勾选原文件时只移除记录。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text("第一次删除会询问并记住你的选择，之后可以在「设置」里修改。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)

            Spacer(minLength: 0)

            Divider()

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("删除", role: .destructive) {
                    UserDefaults.standard.set(alsoOriginals, forKey: "deleteOriginalFilesOnRemove")
                    model.confirmDelete(item, alsoFiles: hasOutput && alsoFiles)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
            }
            .padding(16)
        }
        .frame(width: 440, height: 290)
    }
}

struct DeleteAllSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var originals = UserDefaults.standard.bool(forKey: "deleteOriginalFilesOnRemove")
    @State private var outputs = UserDefaults.standard.bool(forKey: "deleteFilesOnRemove")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("全部删除？").font(.headline)
            Text("移除当前列表全部 \(model.items.count) 条记录，包括未转换和失败项；不受当前筛选影响。")
                .foregroundStyle(.secondary)
            Toggle("同时删除原文件（包括配对视频）", isOn: $originals)
                .toggleStyle(.checkbox)
            Toggle("同时删除输出文件（JPG + MOV）", isOn: $outputs)
                .toggleStyle(.checkbox)
            Text("两个选项都不勾选时，仅删除列表记录，原文件和输出文件都会保留。")
                .font(.caption).foregroundStyle(.secondary)
            Text("勾选的文件移到废纸篓，归档后的原文件也包括在内。不会删除照片图库中的内容。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("全部删除", role: .destructive) {
                    model.deleteAllRecords(originals: originals, outputs: outputs)
                    dismiss()
                }
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @AppStorage("showConversionLog") private var showConversionLog = true
    @AppStorage("openOutputAfterConversion") private var openOutputAfterConversion = false
    @AppStorage("deleteFilesOnRemove") private var deleteFilesOnRemove = false
    @AppStorage("deleteOriginalFilesOnRemove") private var deleteOriginalFilesOnRemove = false
    @AppStorage("confirmBeforeDelete") private var confirmBeforeDelete = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        TabView {
            general
                .tabItem { Label("通用", systemImage: "gearshape") }
            output
                .tabItem { Label("输出", systemImage: "folder") }
            deletion
                .tabItem { Label("删除", systemImage: "trash") }
            about
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 470)
    }

    private var general: some View {
        Form {
            Section("实况来源") {
                Toggle("使用固定存储工作区", isOn: Binding(
                    get: { model.fixedWorkspaceEnabled },
                    set: { model.setFixedWorkspaceEnabled($0) }
                ))
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(model.fixedWorkspacePath.isEmpty ? "尚未选择文件夹" : model.fixedWorkspacePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(model.fixedWorkspacePath.isEmpty ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Button("选择…") { model.chooseFixedWorkspace() }
                }
                Text(model.fixedWorkspaceEnabled
                     ? "启动时和文件变化后自动扫描并分类工作区内的照片和视频。"
                     : "关闭时可在主窗口中逐张添加实况照片。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section("转换") {
                Toggle("转换完成后自动打开日志窗口", isOn: $showConversionLog)
                Toggle("完成后自动打开输出文件夹", isOn: $openOutputAfterConversion)
                Button("重新查询未获取到地址的照片") { model.retryLocations() }
                Text("批量处理按源目录归档。缺少可用拍摄时间的项目归入「需补写时间」，转换失败的原片和配对视频按类型归入「失败」。")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Section {
                Text("所有处理都在本机完成，照片不会上传。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var output: some View {
        Form {
            Section("默认输出位置") {
                Picker("输出到", selection: Binding(
                    get: { model.destination },
                    set: { model.setDestination($0) }
                )) {
                    ForEach(OutputDestination.allCases) { dest in
                        Text(dest.title).tag(dest)
                    }
                }
                .pickerStyle(.radioGroup)

                if model.destination != .photos {
                    Picker("文件夹位置", selection: Binding(
                        get: { model.folderOutputMode },
                        set: { model.setFolderOutputMode($0) }
                    )) {
                        ForEach(FolderOutputMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if model.folderOutputMode == .batch {
                        Text("批次结果归档到「已批量处理_时间戳」。原片按实况、视频、静图存入「原件」；缺少拍摄时间的项目存入「需补写时间」。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                    HStack {
                        Text(model.outputURL.path)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("选择…") { model.chooseOutput() }
                    }
                    }
                }
            }
            Section {
                Text("第一次选择「相册」时，系统会请求照片写入权限。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var deletion: some View {
        Form {
            Section("删除记录") {
                Toggle("同时删除输出文件", isOn: $deleteFilesOnRemove)
                Toggle("同时删除原文件（包括配对视频）", isOn: $deleteOriginalFilesOnRemove)
                Text("勾选的文件移到废纸篓；不勾选时只移除列表记录。不会删除照片图库中的内容。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Toggle("每次删除前都确认", isOn: $confirmBeforeDelete)
                    .onChange(of: confirmBeforeDelete) { value in
                        if value {
                            UserDefaults.standard.set(true, forKey: "deleteConfirmationDone")
                        }
                    }
            }
            Section("第一次确认") {
                Button("下次删除重新询问") {
                    UserDefaults.standard.set(false, forKey: "deleteConfirmationDone")
                }
                Text("第一次删除会询问并记住选择；之后按这里的设置执行。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 10) {
            if let image = NSApp.applicationIconImage {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 72, height: 72)
            }
            Text(L10n.appName)
                .font(.system(size: 16, weight: .semibold))
            Text("版本 \(version)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("本机处理 · 不上传照片")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("转换历史…") { openWindow(id: "history") }
                Button("转换日志…") { openWindow(id: "conversion-log") }
            }
            .padding(.top, 6)

            Text("转换历史保存在本机，不会上传。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

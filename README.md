# Motion2Live（光影间 · Lumina）

无损将 **vivo（照片 + 视频双文件实况）**、**OPPO（单文件动态照片）** 及换机重打包实况转换为 **Apple Live Photo（苹果实况照片）**。提供 **macOS 原生桌面应用（光影间 · Lumina）** 与 **跨平台 Python 命令行工具（`android2apple.py`）**。

所有媒体解析与转换均在本机离线完成，不上传任何照片。

---

## 核心特性

- **100% 无损转换，保留 HDR**
  - **静态图不重编码**：原样保留原始 JPEG 图像扫描数据与 **Ultra HDR / MPF 增益图**，仅在 EXIF `APP1` 段无损写入或补建 Apple `MakerNote` 配对标识（`0x0011 ContentIdentifier`）。
  - **视频无损重封装**：仅对 MP4/MOV 容器做无损转封装（自动将第三方 `hev1` 标签无损修正为 Apple「照片」要求的 `hvc1`），不重编码视频流；对原本即包含 Apple 实况轨道的视频完整保留 `still-image-time` 封面帧时间轨。
- **多品牌实况容器兼容**
  - **单文件内嵌视频**：OPPO 动态照片、Google Motion Photo，以及旧 iPhone 实况经 OPPO/vivo 换机工具二次打包后的单文件格式。
  - **同名双文件配对**：vivo 导出的同名 `JPEG + MP4/MOV` 双文件格式（自动去重关联内容哈希一致的 `(1)` 等重复导出视频）。
- **拍摄时间保留与独立校时工具**
  - 转换时自动读取 EXIF `DateTimeOriginal`，同步写入输出 `JPG` / `MOV` 的文件创建与修改时间及 `com.apple.quicktime.creationdate`，解决换机导出后实况变成迁移当天日期的问题。
  - 内置独立 **「仅修复时间」** 窗口与 CLI 模式，支持自动读取元数据/相机文件名时间，或手动指定日期时间与时区。
- **macOS 原生体验（光影间 · Lumina）**
  - 原生 SwiftUI 界面，自适应浅色/深色模式，提供 `Apple Silicon (arm64)` 与 `Intel (x86_64)` 独立安装包。
  - 支持直接写入 macOS「照片」图库（PhotoKit）或输出至文件夹并自动分类归档。
  - 支持固定工作区自动扫描、HDR 状态角标、GPS 逆地理编码显示地点、类苹果相册的「显示简介」（含直方图、EXIF 参数、地图跳转）以及详细错误回溯日志。

---

## 安装与使用（macOS 桌面端）

### 1. 环境准备

- **macOS 13.0+**
- **Python 3**：macOS Command Line Tools 自带（如未安装可在终端执行 `xcode-select --install`），亦支持 Homebrew Python
- **FFmpeg**：用于无损转封装视频流，通过 Homebrew 安装：
  ```bash
  brew install ffmpeg
  ```
- **ExifTool**：已内置于 `.app` 包中，无需单独安装

### 2. 下载与安装

前往 [Releases](../../releases) 下载对应芯片架构的压缩包：

- **Apple Silicon（M1 / M2 / M3 / M4）**：`光影间-1.0.15-arm64.zip`
- **Intel 芯片（x86_64）**：`光影间-1.0.15-x86_64.zip`

解压后将 `光影间.app` 拖入「应用程序」文件夹。由于应用采用本地签名未做 Apple 公证，首次打开若提示拦截，可右键点击应用选择「打开」，或在终端移除隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/光影间.app
```

### 3. 导入苹果「照片」并同步至 iPhone

- **方式一（自动入库）**：在应用底部「输出位置」选择 **「相册」** 或 **「相册和文件夹」**，授权照片图库写入权限后，转换结果会直接作为实况照片存入系统「照片」。
- **方式二（手动拖入）**：输出到文件夹后，将同一张实况对应的 **`.jpg` 和 `.mov` 成对同时选中**，一起拖入 macOS「照片」窗口（只拖 `.jpg` 会变成普通静态照片）。
- 在 macOS「照片 → 设置 → iCloud」中开启 **iCloud 照片**，即可无损同步至同一 Apple ID 下的 iPhone / iPad。

---

## 命令行使用（Python CLI）

核心转换引擎 `android2apple.py` 仅依赖 Python 3.9+ 标准库与外部 `ffmpeg`、`exiftool`，可独立在终端批量运行：

```bash
# macOS 安装依赖
brew install ffmpeg exiftool
```

### 常用命令

```bash
# 批量转换文件夹或指定文件，输出成对的 <原名>.jpg + <原名>.mov（不修改原文件）
python3 android2apple.py "/path/to/photos" -o ./output

# 扫描目录中的实况可转换状态（输出 JSON Lines）
python3 android2apple.py --scan "/path/to/photos"

# 查看单张照片/实况的详细元数据信息（JSON）
python3 android2apple.py --info "/path/to/IMG_0001.jpg"

# 预览将用于修复的拍摄时间与来源
python3 android2apple.py --preview-time "/path/to/photos"

# 仅修复拍摄时间（自动提取元数据时间，或通过 --capture-time 手动指定含时区时间）
python3 android2apple.py --repair-time "/path/to/photos" -o ./repaired
python3 android2apple.py --repair-time --capture-time "2026:07:23 10:05:00+08:00" "/path/to/IMG_0001.jpg" -o ./repaired
```

---

## 工作原理

Apple 生态判定一组图片与视频是否为 Live Photo，核心在于两端是否携带相同的 UUID 标识：

1. **静态图（JPEG）**：EXIF 中 Apple `MakerNote` 的 `0x0011` 标签（`ContentIdentifier`）。
2. **动态视频（QuickTime MOV）**：容器 Keys 元数据中的 `com.apple.quicktime.content.identifier`。

本项目针对不同来源采取最小改动策略：

- **单文件动态照片（OPPO 等）**：根据 XMP 中的 `OpCamera:VideoLength` 等偏移标记无损切分出原始 JPEG 与尾部附加的视频流，静态图不经过任何解码/重编码。
- **双文件实况（vivo 等）**：自动配对同名静态图与 `MP4`/`MOV` 视频，将视频流无损转封装进 MOV 容器并写入配对 UUID。
- **换机重打包实况修复**：部分旧 iPhone 实况经安卓换机工具迁移后，原始 MOV 被追加在 JPEG 末尾，而 Apple `MakerNote` 被清空为仅剩 `Apple iOS\0` 空壳并混入 `OpCamera:` / `VCamera:` XMP 标签（导致常规转换工具报 `Unsupported MakerNote layout`）。本工具可无损切回原始 Apple MOV（保留全部原始轨道与封面帧时间）并重建 `MakerNote` 配对标识。

---

## 从源码构建

环境要求：macOS 13+、Xcode Command Line Tools（Swift 编译器）。

```bash
bash app/build_app.sh
```

构建完成后会在 `dist/` 下生成两个架构的独立应用与发布包：

- `dist/arm64/光影间.app` & `dist/光影间-1.0.15-arm64.zip`
- `dist/x86_64/光影间.app` & `dist/光影间-1.0.15-x86_64.zip`

---

## 项目结构

```text
.
├── android2apple.py        # 无损实况转换与时间修复核心引擎（供 App 调用 & 独立 CLI）
└── app/
    ├── Sources/            # macOS SwiftUI 原生客户端源码
    ├── Resources/          # 应用图标、Info.plist 与中英文本地化资源
    ├── vendor/exiftool/    # 内置打包的 ExifTool
    └── build_app.sh        # arm64 / x86_64 双版本构建打包脚本
```

---

## 已知限制与注意事项

- 静态图目前仅支持无损改写 **JPEG** 格式（OPPO / vivo 导出的实况静态图均为 JPEG）；HEIC 静态图会安全跳过。
- vivo 双文件格式导出的原始 MP4 不含 Apple 专有的 `still-image-time` 封面时间轨，转换后可正常作为实况导入并长按播放，播放起点默认从第 0 秒开始，静态封面仍为原图。
- 所有操作默认保留原文件不覆盖，但批量处理前仍建议对珍贵原片做好备份。

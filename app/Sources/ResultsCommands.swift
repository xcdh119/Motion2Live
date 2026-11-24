import SwiftUI

struct ResultsCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("转换结果") {
            Button("查看不支持的项目") {
                openWindow(id: "conversion-log")
                model.conversionResultSheet = .unsupported
            }
            .disabled(model.lastUnsupportedItems.isEmpty)

            Button("查看无法修复时间") {
                openWindow(id: "conversion-log")
                model.conversionResultSheet = .missingDates
            }
            .disabled(model.missingDateItems.isEmpty)
        }
    }
}
